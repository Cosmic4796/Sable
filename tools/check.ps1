# Sable :: check.ps1
#
#   powershell -ExecutionPolicy Bypass -File tools\check.ps1
#
# 1. syntax-gates every src module with luau-compile
# 2. typechecks + lints each src module against real Roblox API definitions
#    ("Unknown require" is filtered: modules are resolved by the bundle's
#     require shim, which the analyzer cannot follow)
# 3. rebuilds dist/Sable.lua and analyzes it -- this is the authoritative pass,
#    since it is the artifact that actually ships

param(
    [switch]$SkipBuild,
    # Defaults to the repo-local toolchain. Run tools\bootstrap.ps1 once to
    # populate it, or point SABLE_LUAU_DIR at your own install.
    [string]$LuauDir = $(if ($env:SABLE_LUAU_DIR) { $env:SABLE_LUAU_DIR } else { Join-Path $PSScriptRoot 'luau' })
)

$ErrorActionPreference = 'Continue'
$root    = Split-Path -Parent $PSScriptRoot
$compile = Join-Path $LuauDir 'luau-compile.exe'
$lsp     = Join-Path $LuauDir 'lsp\luau-lsp.exe'
$defs    = Join-Path $root 'tools\globalTypes.d.luau'

foreach ($tool in @($compile, $lsp, $defs)) {
    if (-not (Test-Path $tool)) {
        Write-Host "MISSING TOOL: $tool" -ForegroundColor Red
        Write-Host "Run:  powershell -ExecutionPolicy Bypass -File tools\bootstrap.ps1" -ForegroundColor Yellow
        exit 2
    }
}

# Lines that are artifacts of analyzing modules outside their bundle.
$noise = @(
    'Unknown require'
)
function Test-Noise([string]$line) {
    if ($line -match '^\[INFO\]') { return $true }
    foreach ($n in $noise) { if ($line -like "*$n*") { return $true } }
    return $false
}

$srcFiles = Get-ChildItem (Join-Path $root 'src') -Recurse -Filter *.lua | ForEach-Object { $_.FullName }

Write-Host "== syntax gate ==" -ForegroundColor Cyan
$syntaxFailed = 0
foreach ($f in $srcFiles) {
    $out = & $compile --binary $f 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $syntaxFailed++
        Write-Host ("  FAIL " + $f.Replace("$root\", '')) -ForegroundColor Red
        ($out.Trim() -split "`n" | Select-Object -First 5) | ForEach-Object { Write-Host "        $_" }
    }
}
if ($syntaxFailed -eq 0) { Write-Host "  $($srcFiles.Count) module(s) parse clean" -ForegroundColor Green }

Write-Host "`n== src typecheck + lint ==" -ForegroundColor Cyan
$srcIssues = @(& $lsp analyze --definitions=$defs $srcFiles 2>&1 |
    ForEach-Object { $_.ToString() } | Where-Object { -not (Test-Noise $_) } | Where-Object { $_.Trim() -ne '' })
if ($srcIssues.Count -eq 0) {
    Write-Host "  clean" -ForegroundColor Green
} else {
    $srcIssues | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

$bundleIssues = @()
if (-not $SkipBuild) {
    Write-Host "`n== bundle ==" -ForegroundColor Cyan
    Push-Location $root
    $buildOut = & python (Join-Path $root 'tools\build.py') 2>&1 | Out-String
    $buildExit = $LASTEXITCODE
    Pop-Location
    Write-Host ($buildOut.Trim() -split "`n" | Select-Object -First 3)

    if ($buildExit -ne 0) {
        Write-Host "  BUILD FAILED" -ForegroundColor Red
        Write-Host $buildOut
        exit 1
    }

    Write-Host "`n== bundle typecheck + lint (authoritative) ==" -ForegroundColor Cyan
    $dist = Join-Path $root 'dist\Sable.lua'
    $bundleIssues = @(& $lsp analyze --definitions=$defs $dist 2>&1 |
        ForEach-Object { $_.ToString() } | Where-Object { -not (Test-Noise $_) } | Where-Object { $_.Trim() -ne '' })
    if ($bundleIssues.Count -eq 0) {
        Write-Host "  clean" -ForegroundColor Green
    } else {
        $bundleIssues | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }
}

$smokeFailed = $false
if (-not $SkipBuild) {
    Write-Host "`n== headless smoke test ==" -ForegroundColor Cyan
    $smokeOut = & python (Join-Path $root 'tools\smoke.py') 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $smokeFailed = $true
        Write-Host $smokeOut.Trim() -ForegroundColor Yellow
    } else {
        ($smokeOut.Trim() -split "`n" | Select-Object -Last 2) | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
    }
}

Write-Host ""
if ($syntaxFailed -eq 0 -and $srcIssues.Count -eq 0 -and $bundleIssues.Count -eq 0 -and -not $smokeFailed) {
    Write-Host "ALL CLEAN" -ForegroundColor Green
    exit 0
}
Write-Host "syntax failures: $syntaxFailed | src issues: $($srcIssues.Count) | bundle issues: $($bundleIssues.Count)" -ForegroundColor Yellow
exit 1
