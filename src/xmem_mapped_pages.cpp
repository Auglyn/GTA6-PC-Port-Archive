#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include "era_physical.h"

#include <iterator>
#include <limits>
#include <map>
#include <mutex>
#include <new>

namespace {
struct Backing {
    HANDLE section;
    ULONG_PTR views = 0;
};

// Keep grant transitions and section views serialized. A grant can outlive all its
// views so its bytes survive unmapping. Its backing is released before reuse.
struct PhysicalMemory {
    std::mutex mutex;
    std::map<ULONG_PTR, Backing> backings;
    std::map<ULONG_PTR, ULONG_PTR> views;
    std::map<ULONG_PTR, SIZE_T> reservations;

    ~PhysicalMemory()
    {
        for (const auto& view : views)
            UnmapViewOfFile(reinterpret_cast<void*>(view.first));
        for (const auto& backing : backings)
            CloseHandle(backing.second.section);
    }
};

PhysicalMemory memory;
constexpr SIZE_T page_bytes = era_physical::page_bytes;

BOOL physical_result(era_physical::Status status) noexcept
{
    switch (status) {
    case era_physical::Status::ok:
        SetLastError(ERROR_SUCCESS);
        return TRUE;
    case era_physical::Status::exhausted:
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return FALSE;
    default:
        SetLastError(ERROR_INVALID_PARAMETER);
        return FALSE;
    }
}

HANDLE section_for(ULONG_PTR page)
{
    const auto existing = memory.backings.find(page);
    if (existing != memory.backings.end())
        return existing->second.section;
    const HANDLE section = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
                                              0, page_bytes, nullptr);
    if (section) {
        try {
            memory.backings.emplace(page, Backing{section});
        } catch (const std::bad_alloc&) {
            CloseHandle(section);
            throw;
        }
    }
    return section;
}

auto owned_reservation(ULONG_PTR address)
{
    auto it = memory.reservations.upper_bound(address);
    if (it == memory.reservations.begin()) return memory.reservations.end();
    --it;
    return address - it->first < it->second ? it : memory.reservations.end();
}

bool map_view(ULONG_PTR address, HANDLE section)
{
    auto* target = reinterpret_cast<void*>(address);
    auto map = [&] {
        return MapViewOfFile3(section, GetCurrentProcess(), target, 0,
                              page_bytes, MEM_REPLACE_PLACEHOLDER, PAGE_READWRITE, nullptr, 0) != nullptr;
    };
    if (map()) return true;
    if (owned_reservation(address) == memory.reservations.end()) return false;
    return VirtualFree(target, page_bytes, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER) && map();
}

bool unmap_view(ULONG_PTR address)
{
    return UnmapViewOfFile2(GetCurrentProcess(), reinterpret_cast<void*>(address),
                           MEM_PRESERVE_PLACEHOLDER) != FALSE;
}

void coalesce_unused(const std::map<ULONG_PTR, ULONG_PTR>& batch)
{
    auto previous = memory.reservations.end();
    for (const auto& entry : batch) {
        const auto reservation = owned_reservation(entry.first);
        if (reservation == memory.reservations.end() || reservation == previous) continue;
        previous = reservation;
        const auto [base, size] = *reservation;
        const auto view = memory.views.lower_bound(base);
        if (view == memory.views.end() || view->first - base >= size)
            VirtualFree(reinterpret_cast<void*>(base), size, MEM_RELEASE | MEM_COALESCE_PLACEHOLDERS);
    }
}

// Destinations must be caller-owned, page-sized Windows placeholders. Live views
// are owned by this shim until it unmaps them. The caller must not replace them.
template <typename AddressAt>
BOOL map_pages(ULONG_PTR count, const ULONG_PTR* tokens, const AddressAt& address_at) noexcept
{
    if (!count || count > era_physical::capacity_pages)
        return physical_result(era_physical::Status::invalid);
    try {
        const std::lock_guard guard(memory.mutex);
        std::map<ULONG_PTR, ULONG_PTR> batch;
        for (ULONG_PTR i = 0; i < count; ++i) {
            const auto address = address_at(i);
            const auto live = memory.views.find(address);
            if (!address || address % page_bytes ||
                (tokens ? live != memory.views.end() || !era_physical::owns(tokens[i])
                        : live == memory.views.end()))
                return physical_result(era_physical::Status::invalid);
            if (!batch.emplace(address, tokens ? tokens[i] : live->second).second)
                return physical_result(era_physical::Status::invalid);
        }
        if (tokens) {
            for (const auto& [address, page] : batch) {
                if (!section_for(page)) return FALSE;
            }
            auto next = batch.begin();
            for (; next != batch.end(); ++next) {
                if (!map_view(next->first, memory.backings.at(next->second).section)) {
                    const DWORD error = GetLastError();
                    while (next != batch.begin()) {
                        const auto previous = --next;
                        if (!unmap_view(previous->first)) {
                            ++memory.backings.at(previous->second).views;
                            const auto position = std::next(previous);
                            memory.views.insert(batch.extract(previous));
                            next = position;
                        }
                    }
                    coalesce_unused(batch);
                    SetLastError(error);
                    return FALSE;
                }
            }
            for (const auto& [address, page] : batch)
                ++memory.backings.at(page).views;
            memory.views.merge(batch);
        } else {
            auto next = batch.begin();
            for (; next != batch.end(); ++next) {
                if (!unmap_view(next->first)) {
                    const DWORD error = GetLastError();
                    while (next != batch.begin()) {
                        const auto& [address, page] = *--next;
                        if (!map_view(address, memory.backings.at(page).section)) {
                            --memory.backings.at(page).views;
                            memory.views.erase(address);
                        }
                    }
                    SetLastError(error);
                    return FALSE;
                }
            }
            for (const auto& [address, page] : batch) {
                --memory.backings.at(page).views;
                memory.views.erase(address);
            }
            coalesce_unused(batch);
        }
    } catch (const std::bad_alloc&) {
        return physical_result(era_physical::Status::exhausted);
    }
    return physical_result(era_physical::Status::ok);
}
}

extern "C" BOOL WINAPI XMemAllocatePhysicalPages(ULONG_PTR flags, PULONG_PTR count, PULONG_PTR pages)
{
    static_assert(sizeof(ULONG_PTR) == sizeof(std::uint64_t));
    const std::lock_guard guard(memory.mutex);
    return physical_result(era_physical::allocate(flags, reinterpret_cast<std::uint64_t*>(count),
                                                  reinterpret_cast<std::uint64_t*>(pages)));
}

extern "C" BOOL WINAPI XMemFreePhysicalPages(ULONG_PTR count, PULONG_PTR pages)
{
    if (!pages || !count || count > era_physical::capacity_pages)
        return physical_result(era_physical::Status::invalid);
    const std::lock_guard guard(memory.mutex);
    for (ULONG_PTR i = 0; i < count; ++i) {
        const auto backing = memory.backings.find(pages[i]);
        if (backing != memory.backings.end() && backing->second.views)
            return physical_result(era_physical::Status::invalid);
    }
    const auto status = era_physical::release(count, reinterpret_cast<const std::uint64_t*>(pages));
    if (status == era_physical::Status::ok) {
        for (ULONG_PTR i = 0; i < count; ++i) {
            const auto backing = memory.backings.find(pages[i]);
            if (backing != memory.backings.end()) {
                CloseHandle(backing->second.section);
                memory.backings.erase(backing);
            }
        }
    }
    return physical_result(status);
}

extern "C" void* WINAPI XMemMapPhysicalPages(void* base, ULONG_PTR count, const ULONG_PTR* tokens)
{
    const auto address = reinterpret_cast<ULONG_PTR>(base);
    if (!address || count > (std::numeric_limits<ULONG_PTR>::max() - address) / page_bytes) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return nullptr;
    }
    return map_pages(count, tokens, [=](ULONG_PTR i) { return address + i * page_bytes; }) ? base : nullptr;
}

extern "C" BOOL WINAPI XMemMapPhysicalPagesScatter(void* const* addresses, ULONG_PTR count,
                                                   const ULONG_PTR* tokens)
{
    if (!addresses) return physical_result(era_physical::Status::invalid);
    return map_pages(count, tokens, [=](ULONG_PTR i) { return reinterpret_cast<ULONG_PTR>(addresses[i]); });
}

// Reserve+commit desktop profile for the startup blocks observed on #870: the pool loop asks
// for type 0x20003000 with 0x183/0x22004 or 0x283/0x2404, and later startup code for type
// 0x20403000 (64 KiB pages) with 0x181/PAGE_READWRITE, each with a null base. Proposed
// desktop policy: commit a fresh block of ordinary zero-filled read/write pages, whose size
// must be a nonzero multiple of 64 KiB. The page-size request and the console protection bits
// above PAGE_READWRITE are not reproduced. A host failure returns NULL with the host error.
static void* commit_startup_block(SIZE_T bytes, DWORD allocation_type, ULONGLONG attributes,
                                  DWORD protection) noexcept
{
    constexpr SIZE_T granularity = SIZE_T{64} << 10;
    const bool supported = allocation_type == 0x20003000
                               ? (attributes == 0x183 && protection == 0x22004)
                                     || (attributes == 0x283 && protection == 0x2404)
                               : attributes == 0x181 && protection == PAGE_READWRITE;
    if (!bytes || bytes % granularity || !supported) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return nullptr;
    }
    return VirtualAlloc(nullptr, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
}

// The startup commit profile above, and the reserve-only desktop profile from the source-built
// #888 comparison.
extern "C" void* WINAPI XMemVirtualAlloc(void* address, SIZE_T bytes, DWORD allocation_type,
                                        ULONGLONG attributes, DWORD protection)
{
    constexpr DWORD startup_reserve = 0x20402000;
    constexpr SIZE_T gib = SIZE_T{1} << 30;
    if (!address && (allocation_type == 0x20003000 || allocation_type == (startup_reserve | MEM_COMMIT)))
        return commit_startup_block(bytes, allocation_type, attributes, protection);
    const bool supported = (attributes == 0x21 && protection == PAGE_READWRITE)
                           || (attributes == 3 && protection == (0x800 | PAGE_NOACCESS));
    if (address || (bytes != 16 * gib && bytes != 24 * gib) || allocation_type != startup_reserve || !supported) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return nullptr;
    }
    const std::lock_guard guard(memory.mutex);
    // Callers release unused reservations with Win32. Drop entries for released
    // ranges before another allocation can reuse those virtual addresses.
    for (auto it = memory.reservations.begin(); it != memory.reservations.end();) {
        MEMORY_BASIC_INFORMATION info{};
        if (VirtualQuery(reinterpret_cast<void*>(it->first), &info, sizeof(info)) && info.State == MEM_FREE)
            it = memory.reservations.erase(it);
        else
            ++it;
    }
    auto* reservation = VirtualAlloc2(GetCurrentProcess(), nullptr, bytes, MEM_RESERVE | MEM_RESERVE_PLACEHOLDER,
                                      PAGE_NOACCESS, nullptr, 0);
    if (!reservation) return nullptr;
    try {
        memory.reservations.insert_or_assign(reinterpret_cast<ULONG_PTR>(reservation), bytes);
    } catch (const std::bad_alloc&) {
        VirtualFree(reservation, 0, MEM_RELEASE);
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return nullptr;
    }
    return reservation;
}
