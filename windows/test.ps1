#Requires -Version 5.1
# test.ps1 — automated test suite for ai-trash Windows PowerShell scripts
#
# Usage: pwsh -File windows/test.ps1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Colour helpers ────────────────────────────────────────────────────────────

$script:FAILURES = 0
function _Pass { param([string]$msg) Write-Host "  PASS  $msg" -ForegroundColor Green }
function _Fail { param([string]$msg) Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:FAILURES++ }
function _Skip { param([string]$msg) Write-Host "  SKIP  $msg" -ForegroundColor Yellow }
function _Section { param([string]$msg) Write-Host ""; Write-Host "── $msg ──" }

# ─── Isolated test environment ─────────────────────────────────────────────────

$RepoDir  = Split-Path $PSScriptRoot -Parent
$WorkDir  = Join-Path $env:USERPROFILE "ai-trash-test-$PID"
$TestHome = Join-Path $WorkDir "home"
$ConfDir  = Join-Path $TestHome ".config\ai-trash"
$ManifestPath = Join-Path $ConfDir "manifest.json"

New-Item -ItemType Directory -Force -Path $WorkDir, $TestHome, $ConfDir | Out-Null

# Override USERPROFILE so rm_wrapper and ai-trash use our isolated home
$env:USERPROFILE = $TestHome

# Dot-source the wrapper into this script scope.
# All $script: variables it sets live here, and Remove-Item overrides this session.
. "$RepoDir\windows\rm_wrapper.ps1"

# Override mode for tests (these $script: vars are now in this scope)
$script:_AiTrashMode     = 'always'
$script:_AiTrashManifestPath = $ManifestPath

# ─── Helper: call ai-trash CLI ─────────────────────────────────────────────────

function _AiTrash {
    param([string[]]$CliArgs)
    & pwsh -NoProfile -NonInteractive -File "$RepoDir\windows\ai-trash.ps1" @CliArgs 2>&1
}

# ─── Helper: set mode ─────────────────────────────────────────────────────────

function _SetMode { param([string]$Mode) $script:_AiTrashMode = $Mode }

# ─── Helper: read test manifest ───────────────────────────────────────────────

function _ReadTestManifest {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return @() }
    try {
        $json    = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
        $entries = $json | ConvertFrom-Json
        if ($null -eq $entries) { return @() }
        # PS7 auto-converts ISO 8601 strings to DateTime during JSON parse; normalize back to strings.
        foreach ($e in @($entries)) {
            $dat = $e.'deleted-at'
            if ($dat -is [DateTime]) { $e.'deleted-at' = $dat.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        }
        return @($entries)
    } catch { return @() }
}

# ─── Helper: find file in Recycle Bin ─────────────────────────────────────────

function _FindInBin {
    param([string]$OriginalPath)
    # Try COM Shell.Application first (works in interactive sessions).
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin   = $shell.Namespace(10)
        foreach ($item in $bin.Items()) {
            $from = $item.ExtendedProperty('System.Recycle.DeletedFrom')
            if ([string]::IsNullOrEmpty($from)) { continue }
            $full = Join-Path $from $item.Name
            if ($full -ieq $OriginalPath) { return $item }
        }
    } catch { }

    # Fallback: scan $RECYCLE.BIN\<SID> directly (headless/server environments).
    # $I file format: [int64 version][int64 size][int64 FILETIME][int32 pathLen (v2 only)][UTF-16LE path]
    try {
        $sid    = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $root   = [System.IO.Path]::GetPathRoot($OriginalPath)
        $binDir = Join-Path $root "`$RECYCLE.BIN\$sid"
        if (Test-Path -LiteralPath $binDir) {
            $iFiles = Get-ChildItem -LiteralPath $binDir -Filter '$I*' -Force -ErrorAction SilentlyContinue
            foreach ($iFile in $iFiles) {
                try {
                    $bytes = [System.IO.File]::ReadAllBytes($iFile.FullName)
                    if ($bytes.Length -lt 28) { continue }
                    $version   = [System.BitConverter]::ToInt64($bytes, 0)
                    $pathStart = if ($version -ge 2) { 28 } else { 24 }
                    $pathBytes = $bytes[$pathStart..($bytes.Length - 1)]
                    $path      = [System.Text.Encoding]::Unicode.GetString($pathBytes).TrimEnd([char]0)
                    if ($path -ieq $OriginalPath) { return [PSCustomObject]@{ Path = Join-Path $binDir ('$R' + $iFile.Name.Substring(2)) } }
                } catch { }
            }
        }
    } catch { }

    return $null
}

# ──────────────────────────────────────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────────────────────────────────────

_Section "ai-trash CLI: status on empty trash"
$out = (_AiTrash @('status')) -join "`n"
if ($out -match 'AI trash is empty') { _Pass "status: empty trash" }
else { _Fail "status: expected 'AI trash is empty', got: $out" }

_Section "ai-trash CLI: list on empty trash"
$out = (_AiTrash @('list')) -join "`n"
if ($out -match 'AI trash is empty') { _Pass "list: empty trash" }
else { _Fail "list: expected 'AI trash is empty', got: $out" }

_Section "rm_wrapper: always mode — file goes to Recycle Bin"
_SetMode 'always'
$f = Join-Path $WorkDir "always-test.txt"
"hello" | Set-Content $f
$absF = [System.IO.Path]::GetFullPath($f)
Remove-Item -LiteralPath $f

# Check manifest entry was written.
$manifestEntries = _ReadTestManifest
$manifestEntry   = $manifestEntries | Where-Object { $_.'original-path' -ieq $absF }
if ($manifestEntry) { _Pass "always: manifest entry created" }
else { _Fail "always: manifest entry not found. Manifest: $(Get-Content $ManifestPath -Raw -EA SilentlyContinue)" }

# Check file actually appears in Recycle Bin.
$binItem = _FindInBin -OriginalPath $absF
if ($binItem) { _Pass "always: file in Windows Recycle Bin" }
else { _Fail "always: file not found in Recycle Bin" }

_Section "rm_wrapper: always mode — manifest metadata correct"
if ($manifestEntry) {
    if ($manifestEntry.'original-path' -ieq $absF) { _Pass "meta: original-path" }
    else { _Fail "meta: original-path='$($manifestEntry.'original-path')' want '$absF'" }

    if ($manifestEntry.'deleted-at' -match '^\d{4}-\d{2}-\d{2}T') { _Pass "meta: deleted-at ($($manifestEntry.'deleted-at'))" }
    else { _Fail "meta: deleted-at='$($manifestEntry.'deleted-at')'" }

    if ($manifestEntry.'deleted-by') { _Pass "meta: deleted-by ($($manifestEntry.'deleted-by'))" }
    else { _Fail "meta: deleted-by empty" }
} else {
    _Fail "meta: manifest entry not found, skipping metadata tests"
}

_Section "ai-trash CLI: status shows item"
$out = (_AiTrash @('status')) -join "`n"
if ($out -match 'Items:\s*(\d+)') {
    $count = [int]$Matches[1]
    if ($count -ge 1) { _Pass "status: reports $count item(s)" } else { _Fail "status: item count=$count" }
} else { _Fail "status: unexpected output: $out" }

_Section "ai-trash CLI: list shows item with timestamp"
$out = (_AiTrash @('list')) -join "`n"
if ($out -match 'always-test\.txt') { _Pass "list: item appears" }
else { _Fail "list: item not shown. Output: $out" }
if ($out -match '\d{4}-\d{2}-\d{2}') { _Pass "list: deletion timestamp shown" }
else { _Fail "list: timestamp missing. Output: $out" }

_Section "rm_wrapper: always mode — restore from Recycle Bin"
$f2    = Join-Path $WorkDir "restore-me.txt"
$absF2 = [System.IO.Path]::GetFullPath($f2)
"restore-content" | Set-Content $f2
Remove-Item -LiteralPath $f2

$binCheck = _FindInBin -OriginalPath $absF2
if ($binCheck) {
    $out = (_AiTrash @('restore', 'restore-me.txt')) -join "`n"
    if (Test-Path $f2) {
        _Pass "restore: file restored from Recycle Bin"
        $content = (Get-Content $f2 -Raw).Trim()
        if ($content -eq 'restore-content') { _Pass "restore: content intact" }
        else { _Fail "restore: content='$content'" }
        # Verify the manifest entry was removed after a successful restore.
        $staleEntry = @(_ReadTestManifest) | Where-Object { $_.'original-path' -ieq $absF2 }
        if (-not $staleEntry) { _Pass "restore: manifest entry removed after restore" }
        else { _Fail "restore: stale manifest entry remains after restore" }
    } else { _Fail "restore: file not at original path after restore. Output: $out" }
} else { _Fail "restore: file not found in Recycle Bin before restore" }

_Section "rm_wrapper: always mode — directory goes to Recycle Bin"
$d    = Join-Path $WorkDir "testdir"
$absD = [System.IO.Path]::GetFullPath($d)
New-Item -ItemType Directory $d | Out-Null
New-Item -ItemType Directory "$d\subdir" | Out-Null
"x" | Set-Content "$d\file.txt"
Remove-Item -LiteralPath $d -Recurse
$dirEntry = (_ReadTestManifest) | Where-Object { $_.'original-path' -ieq $absD }
if ($dirEntry) { _Pass "always: directory manifest entry created" }
else { _Fail "always: directory manifest entry not found. Manifest: $(Get-Content $ManifestPath -Raw -EA SilentlyContinue)" }

_Section "rm_wrapper: name collision — two files with same name"
$fa = Join-Path $WorkDir "collision.txt"
"first"  | Set-Content $fa; Remove-Item -LiteralPath $fa
"second" | Set-Content $fa; Remove-Item -LiteralPath $fa
$collEntries = (_ReadTestManifest) | Where-Object { (Split-Path $_.'original-path' -Leaf) -eq 'collision.txt' }
$collCount   = ($collEntries | Measure-Object).Count
if ($collCount -ge 2) { _Pass "collision: both copies tracked in manifest ($collCount entries)" }
else { _Fail "collision: expected 2 manifest entries for collision.txt, found $collCount" }

_Section "rm_wrapper: missing file with -Force — no error"
try {
    Remove-Item -LiteralPath (Join-Path $WorkDir "does-not-exist.txt") -Force
    _Pass "-Force on missing file exits cleanly"
} catch { _Fail "-Force on missing file threw: $_" }

_Section "rm_wrapper: missing file without -Force — throws"
try {
    Remove-Item -LiteralPath (Join-Path $WorkDir "does-not-exist.txt")
    _Fail "missing file without -Force should have thrown"
} catch { _Pass "missing file without -Force throws as expected" }

_Section "rm_wrapper: selective mode — non-AI caller passes through (permanent delete)"
_SetMode 'selective'
$fSel    = Join-Path $WorkDir "selective-passthrough.txt"
"selective-content" | Set-Content $fSel
$absFSel = [System.IO.Path]::GetFullPath($fSel)
Remove-Item -LiteralPath $fSel

if (-not (Test-Path $fSel)) { _Pass "selective: file deleted" }
else { _Fail "selective: file still exists after Remove-Item" }

$selEntry = @(_ReadTestManifest) | Where-Object { $_.'original-path' -ieq $absFSel }
if (-not $selEntry) { _Pass "selective: no manifest entry (non-AI caller bypasses ai-trash)" }
else { _Fail "selective: manifest entry unexpectedly created for non-AI caller" }

$selBinItem = _FindInBin -OriginalPath $absFSel
if (-not $selBinItem) { _Pass "selective: not in Recycle Bin (permanent delete)" }
else { _Fail "selective: file in Recycle Bin; expected permanent delete for non-AI caller" }
_SetMode 'always'

_Section "rm_wrapper: safe mode — non-AI caller deleted, no manifest entry"
_SetMode 'safe'
$fSafe    = Join-Path $WorkDir "safe-passthrough.txt"
"safe-content" | Set-Content $fSafe
$absFSafe = [System.IO.Path]::GetFullPath($fSafe)
Remove-Item -LiteralPath $fSafe

# File must be gone from its original path (Recycle Bin or permanent delete — both acceptable in headless CI).
if (-not (Test-Path $fSafe)) { _Pass "safe: file deleted from original path" }
else { _Fail "safe: file still exists after Remove-Item" }

# Critically: safe mode must NOT write a manifest entry for a non-AI caller.
$safeEntry = @(_ReadTestManifest) | Where-Object { $_.'original-path' -ieq $absFSafe }
if (-not $safeEntry) { _Pass "safe: no manifest entry (non-AI caller not tracked)" }
else { _Fail "safe: manifest entry unexpectedly created for non-AI caller in safe mode" }
_SetMode 'always'

_Section "ai-trash-cleanup.ps1: old entries purged from manifest and Recycle Bin"
# Delete a file so it lands in the bin + manifest.
$cleanupOldFile = Join-Path $WorkDir "cleanup-old.txt"
"old" | Set-Content $cleanupOldFile
$absCleanupOld = [System.IO.Path]::GetFullPath($cleanupOldFile)
Remove-Item -LiteralPath $cleanupOldFile

$preCleanupEntry = @(_ReadTestManifest) | Where-Object { $_.'original-path' -ieq $absCleanupOld }
if ($preCleanupEntry) { _Pass "cleanup: pre-cleanup manifest entry present" }
else { _Fail "cleanup: file not in manifest before cleanup test" }

# Backdate the manifest entry to 31 days ago so the cleanup script will purge it.
$allEntries = @(_ReadTestManifest)
$oldDate    = (Get-Date).AddDays(-31).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
foreach ($e in $allEntries) {
    if ($e.'original-path' -ieq $absCleanupOld) { $e.'deleted-at' = $oldDate }
}
_AiTrash-WriteManifest -Entries $allEntries

$countBeforeCleanup = @(_ReadTestManifest).Count

# Run the cleanup script (inherits the test USERPROFILE so it uses the test manifest).
& pwsh -NoProfile -NonInteractive -File "$RepoDir\windows\ai-trash-cleanup.ps1" -DaysOld 30 2>&1 | Out-Null

$afterEntries = @(_ReadTestManifest)

# Old entry must be gone from manifest.
$oldEntryAfter = $afterEntries | Where-Object { $_.'original-path' -ieq $absCleanupOld }
if (-not $oldEntryAfter) { _Pass "cleanup: old manifest entry removed" }
else { _Fail "cleanup: old manifest entry still present after cleanup" }

# Recent entries must be untouched.
$expectedAfter = $countBeforeCleanup - 1
if ($afterEntries.Count -eq $expectedAfter) { _Pass "cleanup: recent entries kept ($($afterEntries.Count) remain)" }
else { _Fail "cleanup: expected $expectedAfter entries after cleanup, got $($afterEntries.Count)" }

# The actual $R/$I files must be deleted from the Recycle Bin.
$binAfterCleanup = _FindInBin -OriginalPath $absCleanupOld
if (-not $binAfterCleanup) { _Pass "cleanup: old bin item deleted from Recycle Bin" }
else { _Fail "cleanup: old bin item still in Recycle Bin after cleanup" }

_Section "ai-trash CLI: empty --older-than (recent items not deleted)"
$beforeCount = @(_ReadTestManifest).Count
_AiTrash @('empty', '--force', '--older-than', '1') | Out-Null
$afterCount = @(_ReadTestManifest).Count
if ($beforeCount -eq $afterCount) { _Pass "empty --older-than 1: recent items untouched" }
else { _Fail "empty --older-than 1: item count changed ($beforeCount -> $afterCount)" }

_Section "ai-trash CLI: empty --force"
$beforeCount = @(_ReadTestManifest).Count
_AiTrash @('empty', '--force') | Out-Null
$afterCount = @(_ReadTestManifest).Count
if ($afterCount -eq 0) { _Pass "empty --force: manifest cleared (was $beforeCount items)" }
else { _Fail "empty --force: $afterCount manifest items remain" }

_Section "ai-trash CLI: status after empty"
$out = (_AiTrash @('status')) -join "`n"
if ($out -match 'AI trash is empty') { _Pass "status: empty after empty --force" }
else { _Fail "status: unexpected output after empty: $out" }

_Section "ai-trash CLI: version"
$out = (_AiTrash @('version')) -join "`n"
if ($out -match '1\.\d+\.\d+') { _Pass "version: $($out.Trim())" }
else { _Fail "version: unexpected output: $out" }

# ─── Cleanup ──────────────────────────────────────────────────────────────────
# Empty any remaining Recycle Bin entries from our tests before removing WorkDir.
_AiTrash @('empty', '--force') | Out-Null

if (Test-Path $WorkDir) {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $WorkDir -Recurse -Force -EA SilentlyContinue
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "──────────────────────────────────────"
if ($script:FAILURES -eq 0) {
    Write-Host "All tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:FAILURES) test(s) failed." -ForegroundColor Red
    exit 1
}
