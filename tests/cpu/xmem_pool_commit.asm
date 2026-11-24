; A source-built EXE that imports XMemVirtualAlloc by name from xmem.dll and starts through
; exe_startup.asm, so the same body runs in a normal Windows process and from pe_map_run. It uses the
; three reserve+commit configurations observed in startup on #870, each with a null base:
;   A  type 20003000h, attribute 183h, protection 22004h   (pool loop)
;   B  type 20003000h, attribute 283h, protection 2404h    (pool loop)
;   C  type 20403000h, attribute 181h, protection 4        (later startup block)
; Synthetic sizes and patterns only. The body returns 870h when every step passes, otherwise
; 0F00h + the number of the first failing step. For each block (A: steps 1-4, B: 5-8, C: 9-12):
;   +0  XMemVirtualAlloc returns a block (A 4 MiB, B 2 MiB + 64 KiB, C 1 MiB + 192 KiB)
;   +1  64 KiB aligned; VirtualQuery: base and allocation base, exact size, MEM_COMMIT,
;       PAGE_READWRITE, MEM_PRIVATE
;   +2  every byte reads zero
;   +3  a block-specific pattern written to the first and last QWORD of each 64 KiB page (so also
;       the first and last QWORD of the block) reads back
; Steps 13 to 22 each change one variable of an accepted call and expect NULL with
; ERROR_INVALID_PARAMETER (proposed desktop policy):
;   13  type 20002000h with A's pair (no MEM_COMMIT)
;   14  type 20402000h with C's pair (no MEM_COMMIT)
;   15  attribute 283h with protection 22004h (A and B crossed)
;   16  type 20003000h with C's pair
;   17  type 20403000h with A's pair
;   18  protection 2004h with attribute 183h
;   19  protection PAGE_READONLY with attribute 181h
;   20  base address A while A is live
;   21  size 0
;   22  size 4 MiB + 4 KiB (not a multiple of 64 KiB)
;   23  host failure: A's configuration with a 7FFF00000000h-byte size returns NULL with an error
;       other than ERROR_SUCCESS and ERROR_INVALID_PARAMETER
;   24  A, B and C still hold their patterns
;   25  VirtualFree releases A, B and C, and each then reads as MEM_FREE
; Negative controls: RESERVE_ONLY takes A from the accepted reserve-only call (16 GiB, 20402000h,
; 21h, PAGE_READWRITE) and must fail at step 2 (expected 0F02h); DIRTY writes one nonzero QWORD at
; the end of A before step 3 (0F03h); ACCEPTED_REFUSAL passes A's pair at step 15 (0F0Fh); HOST_FIT
; uses a 4 MiB size at step 23 (0F17h); SKIP_RELEASE does not free A at step 25 (0F19h).
EXTERN __imp_XMemVirtualAlloc:QWORD
EXTERN __imp_VirtualQuery:QWORD
EXTERN __imp_VirtualFree:QWORD
EXTERN __imp_SetLastError:QWORD
EXTERN __imp_GetLastError:QWORD

POOL_TYPE       EQU 20003000h
PAGES_64K_TYPE  EQU 20403000h
SIZE_A          EQU 400000h
SIZE_B          EQU 210000h
SIZE_C          EQU 130000h
PAGE_64K        EQU 10000h
PATTERN         EQU 5A3C96E187F00F78h
MEM_COMMIT      EQU 1000h
MEM_FREE        EQU 10000h
MEM_PRIVATE     EQU 20000h
MEM_RELEASE     EQU 8000h
PAGE_READONLY   EQU 2
PAGE_READWRITE  EQU 4
INVALID_PARAM   EQU 87

; Stack frame inside native_entry: [rsp+20h] fifth argument, [rsp+30h] MEMORY_BASIC_INFORMATION.
MBI_BASE        EQU 30h
MBI_ALLOC_BASE  EQU 38h
MBI_SIZE        EQU 48h
MBI_STATE       EQU 50h
MBI_PROTECT     EQU 54h
MBI_TYPE        EQU 58h

XVA MACRO address, bytes, kind, attributes, protection
    mov rcx, address
    mov rdx, bytes
    mov r8d, kind
    mov r9, attributes
    mov QWORD PTR [rsp+20h], protection
    call QWORD PTR __imp_XMemVirtualAlloc
ENDM

; One refusal step: the call must return NULL and leave ERROR_INVALID_PARAMETER.
REFUSE MACRO address, bytes, kind, attributes, protection
    inc ebx
    xor ecx, ecx
    call QWORD PTR __imp_SetLastError
    XVA address, bytes, kind, attributes, protection
    test rax, rax
    jnz failed
    call QWORD PTR __imp_GetLastError
    cmp eax, INVALID_PARAM
    jne failed
ENDM

QUERY MACRO address
    mov rcx, address
    lea rdx, [rsp+MBI_BASE]
    mov r8d, 48
    call QWORD PTR __imp_VirtualQuery
    cmp rax, 48
    jne failed
ENDM

; Steps +1 to +3 for a block held in `block` with size `bytes`.
VERIFY MACRO block, bytes
    inc ebx
    test block, PAGE_64K - 1
    jnz failed
    QUERY block
    cmp [rsp+MBI_BASE], block
    jne failed
    cmp [rsp+MBI_ALLOC_BASE], block
    jne failed
    mov rax, bytes
    cmp [rsp+MBI_SIZE], rax
    jne failed
    cmp DWORD PTR [rsp+MBI_STATE], MEM_COMMIT
    jne failed
    cmp DWORD PTR [rsp+MBI_PROTECT], PAGE_READWRITE
    jne failed
    cmp DWORD PTR [rsp+MBI_TYPE], MEM_PRIVATE
    jne failed
    inc ebx
IFDEF DIRTY
  IFIDNI <block>, <r12>
    mov QWORD PTR [r12+SIZE_A-8], 1
  ENDIF
ENDIF
    mov rcx, block
    mov rdx, bytes
    call all_zero
    test eax, eax
    jz failed
    inc ebx
    mov rcx, block
    mov rdx, bytes
    call fill_pattern
    mov rcx, block
    mov rdx, bytes
    call check_pattern
    test eax, eax
    jz failed
ENDM

INTACT MACRO block, bytes
    mov rcx, block
    mov rdx, bytes
    call check_pattern
    test eax, eax
    jz failed
ENDM

RELEASE MACRO block
    mov rcx, block
    xor edx, edx
    mov r8d, MEM_RELEASE
    call QWORD PTR __imp_VirtualFree
    test eax, eax
    jz failed
ENDM

FREED MACRO block
    QUERY block
    cmp DWORD PTR [rsp+MBI_STATE], MEM_FREE
    jne failed
ENDM

.code
; rcx = base, rdx = size (a multiple of 64 KiB). Returns eax = 1 when every QWORD is zero, else 0.
all_zero PROC
    xor eax, eax
zero_next:
    sub rdx, 8
    cmp QWORD PTR [rcx+rdx], 0
    jne zero_bad
    test rdx, rdx
    jnz zero_next
    mov eax, 1
zero_bad:
    ret
all_zero ENDP

; rcx = base, rdx = size. The pattern word of the QWORD at offset o is o ^ size ^ PATTERN, and the
; last QWORD of each page holds its complement, so blocks of different sizes get different words.
fill_pattern PROC
    mov r9, PATTERN
    xor r9, rdx
    xor r10d, r10d
fill_next:
    mov r8, r10
    xor r8, r9
    mov [rcx+r10], r8
    not r8
    mov [rcx+r10+PAGE_64K-8], r8
    add r10, PAGE_64K
    cmp r10, rdx
    jb fill_next
    ret
fill_pattern ENDP

; rcx = base, rdx = size. Returns eax = 1 when every pattern word reads back, else 0.
check_pattern PROC
    mov r9, PATTERN
    xor r9, rdx
    xor r10d, r10d
check_next:
    mov r8, r10
    xor r8, r9
    cmp [rcx+r10], r8
    jne check_bad
    not r8
    cmp [rcx+r10+PAGE_64K-8], r8
    jne check_bad
    add r10, PAGE_64K
    cmp r10, rdx
    jb check_next
    mov eax, 1
    ret
check_bad:
    xor eax, eax
    ret
check_pattern ENDP

native_entry PROC FRAME
    push rbx
    .pushreg rbx
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    push r13
    .pushreg r13
    push r14
    .pushreg r14
    sub rsp, 60h
    .allocstack 60h
    .endprolog

    mov ebx, 1                      ; step 1
IFDEF RESERVE_ONLY
    XVA 0, 400000000h, 20402000h, 21h, PAGE_READWRITE
ELSE
    XVA 0, SIZE_A, POOL_TYPE, 183h, 22004h
ENDIF
    test rax, rax
    jz failed
    mov r12, rax
    VERIFY r12, SIZE_A              ; steps 2-4

    inc ebx                         ; step 5
    XVA 0, SIZE_B, POOL_TYPE, 283h, 2404h
    test rax, rax
    jz failed
    mov r13, rax
    VERIFY r13, SIZE_B              ; steps 6-8

    inc ebx                         ; step 9
    XVA 0, SIZE_C, PAGES_64K_TYPE, 181h, PAGE_READWRITE
    test rax, rax
    jz failed
    mov r14, rax
    VERIFY r14, SIZE_C              ; steps 10-12

    REFUSE 0, SIZE_A, 20002000h, 183h, 22004h               ; step 13
    REFUSE 0, SIZE_C, 20402000h, 181h, PAGE_READWRITE       ; step 14
IFDEF ACCEPTED_REFUSAL
    REFUSE 0, SIZE_A, POOL_TYPE, 183h, 22004h               ; step 15
ELSE
    REFUSE 0, SIZE_A, POOL_TYPE, 283h, 22004h               ; step 15
ENDIF
    REFUSE 0, SIZE_C, POOL_TYPE, 181h, PAGE_READWRITE       ; step 16
    REFUSE 0, SIZE_A, PAGES_64K_TYPE, 183h, 22004h          ; step 17
    REFUSE 0, SIZE_A, POOL_TYPE, 183h, 2004h                ; step 18
    REFUSE 0, SIZE_C, PAGES_64K_TYPE, 181h, PAGE_READONLY   ; step 19
    REFUSE r12, SIZE_A, POOL_TYPE, 183h, 22004h             ; step 20
    REFUSE 0, 0, POOL_TYPE, 183h, 22004h                    ; step 21
    REFUSE 0, SIZE_A + 1000h, POOL_TYPE, 183h, 22004h       ; step 22

    inc ebx                         ; step 23
    xor ecx, ecx
    call QWORD PTR __imp_SetLastError
IFDEF HOST_FIT
    XVA 0, SIZE_A, POOL_TYPE, 183h, 22004h
ELSE
    XVA 0, 7FFF00000000h, POOL_TYPE, 183h, 22004h
ENDIF
    test rax, rax
    jnz failed
    call QWORD PTR __imp_GetLastError
    test eax, eax
    jz failed
    cmp eax, INVALID_PARAM
    je failed

    inc ebx                         ; step 24
    INTACT r12, SIZE_A
    INTACT r13, SIZE_B
    INTACT r14, SIZE_C

    inc ebx                         ; step 25
IFNDEF SKIP_RELEASE
    RELEASE r12
ENDIF
    RELEASE r13
    RELEASE r14
    FREED r12
    FREED r13
    FREED r14

    mov eax, 870h
    jmp finished
failed:
    lea eax, [rbx+0F00h]
finished:
    add rsp, 60h
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rbx
    ret
native_entry ENDP
END
