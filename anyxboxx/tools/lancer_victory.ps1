<#
.SYNOPSIS
  Builds (cargo skips the work when current) and launches VIctory (third_party/victory) on the user's own game folder.

.PARAMETER GameDir
  Folder of the game package (kept outside this repository). It must contain game_scarlett_master.exe.

.PARAMETER SkipPipelines
  Optional. Passed unchanged to VICTORY_SKIP_PIPELINES when given.

.PARAMETER NoTunedSettings
  Optional. Does not set the tuned variables below (only VICTORY_GAME_DIR is set).

.PARAMETER Dred
  Optional. Turns on device-removed data (VICTORY_D3D12_DRED) to diagnose a device loss.
  Off by default: it notes every command list operation and slows each frame.

.PARAMETER XgDll
  Optional. Path to your own copy of xg_xs.dll, the offline PC build of the GDK's texture layout library (never in this
  repository). VIctory then lays out the title's textures with it (VICTORY_XG_DLL).

.PARAMETER XgMode
  Optional, with -XgDll. 'real' (default) serves the title from xg_xs.dll; 'compare' keeps VIctory's layouts and logs
  every difference with the library (VICTORY_XG_MODE).

.PARAMETER Precompile
  Optional. Before the game, runs 'victory.exe translate --cache --pipelines --used-pipelines' on shaders.rpf, the game
  executable and its two DLLs (XboxBvhBuilder.dll, amd_fidelityfx_upscaler_xbox.dll), with the same environment
  variables as the game (the cache key depends on them). Measured on 2026-11-25 (RTX 4070 Super): 25,689 shaders in
  about 4.5 min, 296 refused, 13 GB in %LOCALAPPDATA%\victory\cache. Later launches reuse that cache.

.PARAMETER BatchCardRehash
  Optional. Sets VICTORY_CARD_REHASH_RUNS=1 so VIctory hashes adjacent or overlapping GPU memory ranges in batches
  after uploading them. Without this switch the launcher leaves the environment variable as inherited.

.NOTES
  The first cold launch may crash while the pipelines compile; launch again once the cache is filled.
  Settings measured on 2026-11-24 with the VIctory commit then pinned (fxceless/victory-gta6).

.EXAMPLE
  .\tools\lancer_victory.ps1 -GameDir D:\Games\MyPackage

.EXAMPLE
  .\tools\lancer_victory.ps1 -GameDir D:\Games\MyPackage -XgDll D:\MyGdk\xg_xs.dll
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GameDir,
    [string]$SkipPipelines,
    [switch]$NoTunedSettings,
    [switch]$Dred,
    [switch]$Precompile,
    [string]$XgDll,
    [ValidateSet('real', 'compare')][string]$XgMode = 'real',
    [switch]$BatchCardRehash
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$victory = Join-Path $repo 'third_party\victory'
$manifest = Join-Path $victory 'Cargo.toml'

if (-not (Test-Path -LiteralPath $manifest)) {
    throw "third_party/victory/Cargo.toml is missing: this copy of AnyXboxX is incomplete."
}

$gameExe = Join-Path $GameDir 'game_scarlett_master.exe'
if (-not (Test-Path -LiteralPath $gameExe)) {
    throw "game_scarlett_master.exe not found in '$GameDir'."
}

# VIctory is its own Cargo workspace: its target folder is third_party\victory\target
# unless CARGO_TARGET_DIR is set.
$target = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $victory 'target' }
$exe = Join-Path $target 'diag\victory.exe'

# Always ask cargo: it does nothing when victory.exe is current, and rebuilds it after a pull that changes third_party/victory (an old
# victory.exe would ignore the settings the pinned commit reads).
Write-Host 'Building VIctory (diag profile, diagnostics feature)...'
& cargo build --profile diag -p victory --features diagnostics --manifest-path $manifest
if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit code $LASTEXITCODE)." }

# No victory.toml is needed: VIctory reads the game folder from VICTORY_GAME_DIR.
$env:VICTORY_GAME_DIR = $GameDir
if (-not $NoTunedSettings) {
    $tuned = [ordered]@{
        # Translated shader loops stop after 256 iterations (32 cuts the hair strand loops short).
        VICTORY_SHADER_LOOP_LIMIT       = '256'
        # Host pipeline wait setting from the fork's pull request #1.
        VICTORY_LATE_WAIT               = '3'
        # Wide back-end option of the fork, on in the measured run.
        VICTORY_WIDE_BACK               = '1'
        # No relay mode on purpose: the run judged best had it off, and the fork's issue #89 reports that it makes
        # the characters' skin disappear and overlaps the subtitles. Set the relay variable by hand to try it.
        # Card buffer sizing: minimum and total, in MB.
        VICTORY_CARD_BUFFERS_MIN_MB     = '1'
        VICTORY_CARD_BUFFERS_MB         = '1024'
        # DirectStorage writes into physical pages are reported to the GPU side (fork commits e49864a and
        # bf870de by Yorivel): the first room's walls no longer read stale copies.
        VICTORY_DSTORAGE_NOTIFY         = '1'
        # Staging buffers of the textures picked by index are kept for reuse, up to this many MB, instead of a
        # new upload buffer made and mapped at every upload. Measured on an RTX 5080 (two runs each way): the
        # stretch below 2.5 fps at world entry lasts about 40 s instead of about 80 s. 0 keeps none.
        VICTORY_STAGING_POOL_MB         = '1024'
    }
    foreach ($name in $tuned.Keys) {
        Set-Item -Path "Env:$name" -Value $tuned[$name]
    }
}
# VIctory turns DRED on when the variable exists, whatever its value: only set it when asked.
if ($Dred) {
    $env:VICTORY_D3D12_DRED = '1'
}
if ($BatchCardRehash) {
    $env:VICTORY_CARD_REHASH_RUNS = '1'
}
if ($PSBoundParameters.ContainsKey('SkipPipelines') -and $SkipPipelines) {
    $env:VICTORY_SKIP_PIPELINES = $SkipPipelines
}
# Your own copy of the GDK's offline PC xg_xs.dll (never in this repository): Microsoft's library lays out the textures.
if ($PSBoundParameters.ContainsKey('XgDll') -and $XgDll) {
    if (-not (Test-Path -LiteralPath $XgDll -PathType Leaf)) {
        throw "xg_xs.dll not found: '$XgDll'."
    }
    $env:VICTORY_XG_DLL = (Resolve-Path -LiteralPath $XgDll).Path
    $env:VICTORY_XG_MODE = $XgMode
}

if ($Precompile) {
    # Same environment as the game below: the cache key depends on it.
    $shaders = Join-Path $GameDir 'shaders.rpf'
    $dlls = @('XboxBvhBuilder.dll', 'amd_fidelityfx_upscaler_xbox.dll') | ForEach-Object { Join-Path $GameDir $_ }
    foreach ($needed in @($shaders) + $dlls) {
        if (-not (Test-Path -LiteralPath $needed -PathType Leaf)) {
            throw "-Precompile needs '$needed'."
        }
    }
    Write-Host 'Precompiling shaders and pipelines into the cache (several minutes the first time)...'
    & $exe translate --cache --pipelines --used-pipelines $shaders $gameExe @dlls
    if ($LASTEXITCODE -ne 0) { throw "victory translate failed (exit code $LASTEXITCODE)." }
}

& $exe run $gameExe --execute
exit $LASTEXITCODE
