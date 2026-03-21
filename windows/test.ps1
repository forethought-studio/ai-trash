#Requires -Version 5.1
# test.ps1 — automated test suite for ai-trash Windows PowerShell scripts
#
# Usage: pwsh -File windows/test.ps1
# Requires: Windows (NTFS for ADS tests), PowerShell 5.1+

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Colour helpers ────────────────────────────────────────────────────────────

$script:FAILURES = 0

function _Pass { param([string]$msg) Write-Host "  PASS  $msg" -ForegroundColor Green }
function _Fail { param([string]$msg) Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:FAILURES++ }
function _Skip { param([string]$msg) Write-Host "  SKIP  $msg" -ForegroundColor Yellow }
function _Section { param([string]$msg) Write-Host ""; Write-Host "── $msg ──" }

# ─── Isolated test environment ─────────────────────────────────────────────────

$WorkDir  = Join-Path $env:USERPROFILE "ai-trash-test-$PID"
$TestHome = Join-Path $WorkDir "home"
$TrashDir = Join-Path $TestHome ".Trash\ai-trash"
$ConfDir  = Join-Path $TestHome ".config\ai-trash"

New-Item -ItemType Directory -Force -Path $WorkDir, $TestHome, $TrashDir, $ConfDir | Out-Null

# Cleanup on exit
trap { if (Test-Path $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue } }

$RepoDir = Split-Path $PSScriptRoot -Parent

# ─── Helper: call rm_wrapper with overridden USERPROFILE ───────────────────────

function _Rm {
    param([string[]]$RmArgs)
    $env:USERPROFILE = $TestHome
    $env:AI_TRASH_TEST_HOME = $TestHome
    # Dot-source into a child scope with overridden USERPROFILE
    $sb = {
        param($repo, $homeDir, $args_)
        $env:USERPROFILE = $homeDir
        . "$repo\windows\rm_wrapper.ps1"
        # Force always mode for most tests — override after sourcing
        $script:_AiTrashMode = 'always'
        # Redirect trash dir to our test home
        $script:_AiTrashDir = "$homeDir\.Trash\ai-trash"
        Remove-Item @args_
    }
    & $sb $RepoDir $TestHome $RmArgs
}

# ─── Helper: call ai-trash CLI with overridden USERPROFILE ─────────────────────

function _AiTrash {
    param([string[]]$CliArgs)
    $orig = $env:USERPROFILE
    $env:USERPROFILE = $TestHome
    try {
        & pwsh -NoProfile -NonInteractive -File "$RepoDir\windows\ai-trash.ps1" @CliArgs 2>&1
    } finally {
        $env:USERPROFILE = $orig
    }
}

# ─── Helper: source wrapper with a given mode ──────────────────────────────────

function _RmWithMode {
    param([string]$Mode, [string[]]$RmArgs)
    $sb = {
        param($repo, $homeDir, $mode, $args_)
        $env:USERPROFILE = $homeDir
        . "$repo\windows\rm_wrapper.ps1"
        $script:_AiTrashMode = $mode
        $script:_AiTrashDir  = "$homeDir\.Trash\ai-trash"
        Remove-Item @args_
    }
    & $sb $RepoDir $TestHome $Mode $RmArgs
}

# ──────────────────────────────────────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────────────────────────────────────

_Section "ai-trash CLI: status on empty trash"
$out = (_AiTrash @('status')) -join "`n"
if ($out -match 'AI trash is empty') {
    _Pass "status: empty trash"
} else {
    _Fail "status: expected 'AI trash is empty', got: $out"
}

_Section "ai-trash CLI: list on empty trash"
$out = (_AiTrash @('list')) -join "`n"
if ($out -match 'AI trash is empty') {
    _Pass "list: empty trash"
} else {
    _Fail "list: expected 'AI trash is empty', got: $out"
}

_Section "rm_wrapper: always mode — file goes to ai-trash"
$f = Join-Path $WorkDir "always-test.txt"
"hello" | Set-Content $f
_RmWithMode 'always' @($f)
$trashed = Get-ChildItem $TrashDir -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "always-test*" }
if ($trashed) {
    _Pass "always: file moved to ai-trash"
} else {
    _Fail "always: file not found in ai-trash. Contents: $(Get-ChildItem $TrashDir -EA SilentlyContinue | Select-Object -Expand Name)"
}

_Section "rm_wrapper: always mode — ADS metadata written"
$item = Join-Path $TrashDir "always-test.txt"
if (Test-Path $item) {
    # Try NTFS ADS; fall back to sidecar JSON
    $origPath = $null
    $deletedAt = $null
    $deletedBy = $null
    try {
        $origPath  = (Get-Content -LiteralPath $item -Stream 'ai-trash.original-path'  -EA Stop) -join ''
        $deletedAt = (Get-Content -LiteralPath $item -Stream 'ai-trash.deleted-at'     -EA Stop) -join ''
        $deletedBy = (Get-Content -LiteralPath $item -Stream 'ai-trash.deleted-by'     -EA Stop) -join ''
    } catch {
        $sidecar = Join-Path $TrashDir ".always-test.txt.ai-trash"
        if (Test-Path $sidecar) {
            $obj = Get-Content $sidecar -Raw | ConvertFrom-Json
            $origPath  = $obj.'original-path'
            $deletedAt = $obj.'deleted-at'
            $deletedBy = $obj.'deleted-by'
        }
    }
    if ($origPath -eq $f) { _Pass "meta: original-path" } else { _Fail "meta: original-path='$origPath' want '$f'" }
    if ($deletedAt -match '^\d{4}-\d{2}-\d{2}T') { _Pass "meta: deleted-at ($deletedAt)" } else { _Fail "meta: deleted-at='$deletedAt'" }
    if ($deletedBy) { _Pass "meta: deleted-by ($deletedBy)" } else { _Fail "meta: deleted-by empty" }
} else {
    _Fail "meta: item not found in trash, skipping metadata tests"
}

_Section "ai-trash CLI: status shows item"
$out = (_AiTrash @('status')) -join "`n"
if ($out -match 'Items:\s*(\d+)') {
    $count = [int]$Matches[1]
    if ($count -ge 1) { _Pass "status: reports $count item(s)" } else { _Fail "status: item count=$count" }
} else {
    _Fail "status: unexpected output: $out"
}

_Section "ai-trash CLI: list shows item with timestamp"
$out = (_AiTrash @('list')) -join "`n"
if ($out -match 'always-test\.txt') { _Pass "list: item appears" } else { _Fail "list: item not shown. Output: $out" }
if ($out -match '\d{4}-\d{2}-\d{2}') { _Pass "list: deletion timestamp shown" } else { _Fail "list: timestamp missing. Output: $out" }

_Section "rm_wrapper: always mode — restore"
$f2 = Join-Path $WorkDir "restore-me.txt"
"restore-content" | Set-Content $f2
_RmWithMode 'always' @($f2)
if (Get-ChildItem $TrashDir | Where-Object { $_.Name -like "restore-me*" }) {
    $out = (_AiTrash @('restore', 'restore-me.txt')) -join "`n"
    if (Test-Path $f2) {
        _Pass "restore: file restored to original path"
        $content = Get-Content $f2 -Raw
        if ($content.Trim() -eq 'restore-content') { _Pass "restore: content intact" } else { _Fail "restore: content='$content'" }
    } else {
        _Fail "restore: file not at original path after restore. Output: $out"
    }
} else {
    _Fail "restore: file not found in trash"
}

_Section "rm_wrapper: always mode — directory goes to ai-trash"
$d = Join-Path $WorkDir "testdir"
New-Item -ItemType Directory $d | Out-Null
New-Item -ItemType Directory "$d\subdir" | Out-Null
"x" | Set-Content "$d\file.txt"
_RmWithMode 'always' @('-Recurse', $d)
if (Get-ChildItem $TrashDir | Where-Object { $_.Name -eq 'testdir' }) {
    _Pass "always: directory moved to ai-trash"
} else {
    _Fail "always: directory not found in ai-trash. Contents: $(Get-ChildItem $TrashDir -EA SilentlyContinue | Select-Object -Expand Name)"
}

_Section "rm_wrapper: disposable patterns — .log file permanently deleted"
$fLog = Join-Path $WorkDir "debug.log"
"log content" | Set-Content $fLog
$beforeCount = (Get-ChildItem $TrashDir -EA SilentlyContinue | Measure-Object).Count
_RmWithMode 'always' @($fLog)
$afterCount = (Get-ChildItem $TrashDir -EA SilentlyContinue | Measure-Object).Count
if (($afterCount -eq $beforeCount) -and (-not (Test-Path $fLog))) {
    _Pass "disposable: .log file permanently deleted (not in ai-trash)"
} else {
    _Fail "disposable: before=$beforeCount after=$afterCount file_exists=$(Test-Path $fLog)"
}

_Section "rm_wrapper: name collision — Windows-style renaming"
$fa = Join-Path $WorkDir "collision.txt"
"first"  | Set-Content $fa; _RmWithMode 'always' @($fa)
"second" | Set-Content $fa; _RmWithMode 'always' @($fa)
$hits  = Get-ChildItem $TrashDir | Where-Object { $_.Name -like "collision*" }
$count = ($hits | Measure-Object).Count
if ($count -ge 2) {
    $renamed = $hits | Where-Object { $_.Name -ne 'collision.txt' } | Select-Object -First 1 -Expand Name
    _Pass "collision: second copy renamed to '$renamed'"
} else {
    _Fail "collision: expected 2 collision.txt variants, found: $($hits.Name -join ', ')"
}

_Section "rm_wrapper: missing file with -Force — no error"
try {
    _RmWithMode 'always' @('-Force', (Join-Path $WorkDir "does-not-exist.txt"))
    _Pass "-Force on missing file exits cleanly"
} catch {
    _Fail "-Force on missing file threw: $_"
}

_Section "rm_wrapper: missing file without -Force — throws"
try {
    _RmWithMode 'always' @((Join-Path $WorkDir "does-not-exist.txt"))
    _Fail "missing file without -Force should have thrown"
} catch {
    _Pass "missing file without -Force throws as expected"
}

_Section "ai-trash CLI: empty --older-than (recent items not deleted)"
$beforeCount = (Get-ChildItem $TrashDir -EA SilentlyContinue | Measure-Object).Count
_AiTrash @('empty', '--force', '--older-than', '1') | Out-Null
$afterCount = (Get-ChildItem $TrashDir -EA SilentlyContinue | Measure-Object).Count
if ($beforeCount -eq $afterCount) {
    _Pass "empty --older-than 1: recent items untouched"
} else {
    _Fail "empty --older-than 1: item count changed ($beforeCount -> $afterCount)"
}

_Section "ai-trash CLI: empty --force"
$before = (Get-ChildItem $TrashDir -EA SilentlyContinue | Measure-Object).Count
_AiTrash @('empty', '--force') | Out-Null
$after = (Get-ChildItem $TrashDir -EA SilentlyContinue | Measure-Object).Count
if ($after -eq 0) {
    _Pass "empty --force: trash cleared (was $before items)"
} else {
    _Fail "empty --force: $after items remain"
}

_Section "ai-trash CLI: status after empty"
$out = (_AiTrash @('status')) -join "`n"
if ($out -match 'AI trash is empty') {
    _Pass "status: empty after empty --force"
} else {
    _Fail "status: unexpected output after empty: $out"
}

_Section "ai-trash CLI: version"
$out = (_AiTrash @('version')) -join "`n"
if ($out -match '1\.\d+\.\d+') {
    _Pass "version: $($out.Trim())"
} else {
    _Fail "version: unexpected output: $out"
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────
if (Test-Path $WorkDir) {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "──────────────────────────────────────"
if ($script:FAILURES -eq 0) {
    Write-Host "All tests passed." -ForegroundColor Green
} else {
    Write-Host "$($script:FAILURES) test(s) failed." -ForegroundColor Red
    exit 1
}
