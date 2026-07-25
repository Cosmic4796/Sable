# Sable :: bootstrap.ps1
#
# Fetches the verification toolchain into tools\luau\ and tools\globalTypes.d.luau.
# Both are gitignored -- they are third-party binaries and a generated API dump,
# not part of the library. Run once after cloning:
#
#   powershell -ExecutionPolicy Bypass -File tools\bootstrap.ps1
#
# Nothing here is needed to USE Sable; it is only for building and verifying.

param(
    [string]$LuauVersion = '0.731',
    [string]$LspVersion = '1.69.0'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$tools = $PSScriptRoot
$luauDir = Join-Path $tools 'luau'
$lspDir = Join-Path $luauDir 'lsp'
$defs = Join-Path $tools 'globalTypes.d.luau'

New-Item -ItemType Directory -Force $luauDir | Out-Null
New-Item -ItemType Directory -Force $lspDir | Out-Null

function Get-File($url, $dest) {
    Write-Host "  $url"
    & curl.exe -sSL --retry 3 --max-time 300 -o $dest $url
    if ($LASTEXITCODE -ne 0) { throw "download failed: $url" }
}

Write-Host "Luau CLI $LuauVersion" -ForegroundColor Cyan
if (Test-Path (Join-Path $luauDir 'luau.exe')) {
    Write-Host '  already present, skipping'
} else {
    $zip = Join-Path $env:TEMP 'sable-luau.zip'
    Get-File "https://github.com/luau-lang/luau/releases/download/$LuauVersion/luau-windows.zip" $zip
    Expand-Archive $zip -DestinationPath $luauDir -Force
    Remove-Item $zip -Force
}

Write-Host "luau-lsp $LspVersion" -ForegroundColor Cyan
if (Test-Path (Join-Path $lspDir 'luau-lsp.exe')) {
    Write-Host '  already present, skipping'
} else {
    $zip = Join-Path $env:TEMP 'sable-lsp.zip'
    Get-File "https://github.com/JohnnyMorganz/luau-lsp/releases/download/$LspVersion/luau-lsp-win64.zip" $zip
    Expand-Archive $zip -DestinationPath $lspDir -Force
    Remove-Item $zip -Force
}

# NOTE: globalTypes.d.luau is NOT a luau-lsp release asset (that URL 404s).
# It lives in the repo's scripts/ directory.
Write-Host 'Roblox API definitions' -ForegroundColor Cyan
Get-File 'https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau' $defs

Write-Host ''
$missing = @()
foreach ($p in @(
    (Join-Path $luauDir 'luau.exe'),
    (Join-Path $luauDir 'luau-compile.exe'),
    (Join-Path $lspDir 'luau-lsp.exe'),
    $defs
)) {
    if (Test-Path $p) {
        Write-Host ("  ok   " + $p.Replace("$tools\", 'tools\')) -ForegroundColor Green
    } else {
        $missing += $p
        Write-Host ("  MISS " + $p) -ForegroundColor Red
    }
}

if ($missing.Count -gt 0) { exit 1 }

Write-Host "`nReady. Now run:" -ForegroundColor Green
Write-Host '  powershell -ExecutionPolicy Bypass -File tools\check.ps1'
