# ai-trash-cleanup.ps1 — purge ai-trash entries older than 30 days
#
# Registered as a Task Scheduler task by install.ps1 to run every 6 hours.
# Can also be run manually at any time.

param(
    [int]$DaysOld = 30
)

$AI_TRASH      = "$env:USERPROFILE\.Trash\ai-trash"
$MANIFEST_PATH = "$env:USERPROFILE\.config\ai-trash\manifest.json"
$cutoff        = (Get-Date).AddDays(-$DaysOld)

# ─── Helpers ───────────────────────────────────────────────────────────────────

function _ReadManifest {
    if (-not (Test-Path -LiteralPath $MANIFEST_PATH)) { return @() }
    try {
        $json    = Get-Content -LiteralPath $MANIFEST_PATH -Raw -Encoding UTF8 -ErrorAction Stop
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

function _WriteManifest {
    param($Entries)
    $dir = Split-Path $MANIFEST_PATH -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue
    }
    try {
        $arr = @($Entries)
        if ($arr.Count -eq 0) {
            $json = '[]'
        } elseif ($arr.Count -eq 1) {
            $json = '[' + ($arr[0] | ConvertTo-Json -Depth 5 -Compress) + ']'
        } else {
            $json = $arr | ConvertTo-Json -Depth 5
        }
        Set-Content -LiteralPath $MANIFEST_PATH -Value $json -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function _FindInRecycleBin {
    param([string]$OriginalPath, [string]$DeletedAt = '')
    # Try COM Shell.Application first (works in interactive sessions).
    try {
        $shell    = New-Object -ComObject Shell.Application
        $bin      = $shell.Namespace(10)
        $best     = $null
        $bestDelta = [double]::MaxValue
        foreach ($item in $bin.Items()) {
            $from = $item.ExtendedProperty('System.Recycle.DeletedFrom')
            if ([string]::IsNullOrEmpty($from)) { continue }
            $full = Join-Path $from $item.Name
            if ($full -ieq $OriginalPath) {
                if (-not $DeletedAt) { return $item }
                try {
                    $d = $item.ExtendedProperty('System.Recycle.DeletedDate')
                    if ($null -ne $d) {
                        $delta = [Math]::Abs(([DateTime]::Parse($DeletedAt) - $d.ToUniversalTime()).TotalSeconds)
                        if ($delta -lt $bestDelta) { $best = $item; $bestDelta = $delta }
                    } elseif ($null -eq $best) { $best = $item }
                } catch { if ($null -eq $best) { $best = $item } }
            }
        }
        if ($null -ne $best) { return $best }
    } catch { }

    # Fallback: scan $RECYCLE.BIN\<SID> directly (headless/server environments).
    # $I file format: [int64 version][int64 size][int64 FILETIME][int32 pathLen (v2 only)][UTF-16LE path]
    try {
        $sid    = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $root   = [System.IO.Path]::GetPathRoot($OriginalPath)
        $binDir = Join-Path $root "`$RECYCLE.BIN\$sid"
        if (Test-Path -LiteralPath $binDir) {
            $best      = $null
            $bestDelta = [double]::MaxValue
            $iFiles = Get-ChildItem -LiteralPath $binDir -Filter '$I*' -Force -ErrorAction SilentlyContinue
            foreach ($iFile in $iFiles) {
                try {
                    $bytes = [System.IO.File]::ReadAllBytes($iFile.FullName)
                    if ($bytes.Length -lt 28) { continue }
                    $version   = [System.BitConverter]::ToInt64($bytes, 0)
                    $pathStart = if ($version -ge 2) { 28 } else { 24 }
                    $pathBytes = $bytes[$pathStart..($bytes.Length - 1)]
                    $path      = [System.Text.Encoding]::Unicode.GetString($pathBytes).TrimEnd([char]0)
                    if ($path -ieq $OriginalPath) {
                        $rLeaf = '$R' + $iFile.Name.Substring(2)
                        $rPath = Join-Path $binDir $rLeaf
                        if (-not $DeletedAt) { return [PSCustomObject]@{ Path = $rPath } }
                        try {
                            $filetime = [System.BitConverter]::ToInt64($bytes, 16)
                            $dt    = [DateTime]::FromFileTimeUtc($filetime)
                            $delta = [Math]::Abs(([DateTime]::Parse($DeletedAt) - $dt).TotalSeconds)
                            if ($delta -lt $bestDelta) { $best = [PSCustomObject]@{ Path = $rPath }; $bestDelta = $delta }
                        } catch { if ($null -eq $best) { $best = [PSCustomObject]@{ Path = $rPath } } }
                    }
                } catch { }
            }
            if ($null -ne $best) { return $best }
        }
    } catch { }

    return $null
}

function _GetIFile {
    param([string]$RFilePath)
    $parent = Split-Path $RFilePath -Parent
    $leaf   = Split-Path $RFilePath -Leaf
    $iLeaf  = '$I' + $leaf.Substring(2)
    return Join-Path $parent $iLeaf
}

# ─── Purge old manifest (Recycle Bin) entries ──────────────────────────────────

$manifest = _ReadManifest
$toKeep   = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $manifest) {
    $old = $false
    try {
        $dt  = [DateTime]::Parse($entry.'deleted-at')
        $old = ($dt -lt $cutoff)
    } catch { }

    if ($old) {
        $binItem = _FindInRecycleBin -OriginalPath $entry.'original-path' -DeletedAt $entry.'deleted-at'
        if ($null -ne $binItem) {
            try {
                $rFile = $binItem.Path
                $iFile = _GetIFile -RFilePath $rFile
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $rFile -Recurse -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $iFile) {
                    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $iFile -Force -ErrorAction SilentlyContinue
                }
            } catch {
                try {
                    Write-EventLog -LogName Application -Source 'ai-trash-cleanup' `
                        -EventId 1 -EntryType Warning `
                        -Message "ai-trash-cleanup: failed to delete Recycle Bin item '$($entry.'original-path')': $_" `
                        -ErrorAction SilentlyContinue
                } catch { }
            }
        }
        # Whether or not the bin item was found, drop from manifest.
    } else {
        $toKeep.Add($entry)
    }
}

_WriteManifest -Entries $toKeep

# ─── Purge old legacy folder entries ──────────────────────────────────────────

if (-not (Test-Path -LiteralPath $AI_TRASH)) {
    exit 0
}

$items = Get-ChildItem -LiteralPath $AI_TRASH -ErrorAction SilentlyContinue |
         Where-Object { $_.LastWriteTime -lt $cutoff }

foreach ($item in $items) {
    try {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
    } catch {
        # Non-fatal — log to event log if available, otherwise ignore.
        try {
            Write-EventLog -LogName Application -Source 'ai-trash-cleanup' `
                -EventId 1 -EntryType Warning `
                -Message "ai-trash-cleanup: failed to delete '$($item.FullName)': $_" `
                -ErrorAction SilentlyContinue
        } catch { }
    }

    # Remove sidecar JSON metadata file if present (non-NTFS fallback).
    $sidecar = Join-Path (Split-Path $item.FullName -Parent) ('.' + $item.Name + '.ai-trash')
    if (Test-Path -LiteralPath $sidecar) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
    }
}
