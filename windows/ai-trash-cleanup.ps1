# ai-trash-cleanup.ps1 — purge ai-trash entries older than RETENTION_DAYS (default: 30)
#
# Registered as a Task Scheduler task by install.ps1 to run every 6 hours.
# Can also be run manually at any time.

param(
    [int]$DaysOld = -1   # -1 means "read from config"
)

# Load user config to pick up $RETENTION_DAYS.
$CONFIG_FILE = "$env:USERPROFILE\.config\ai-trash\config.ps1"
$RETENTION_DAYS = 30
if (Test-Path -LiteralPath $CONFIG_FILE) {
    . $CONFIG_FILE
}

# CLI override takes precedence; otherwise use config value.
if ($DaysOld -lt 0) { $DaysOld = $RETENTION_DAYS }

$MANIFEST_PATH = "$env:USERPROFILE\.config\ai-trash\manifest.json"
$cutoff        = (Get-Date).AddDays(-$DaysOld)

# Load shared Recycle Bin helpers (_FindInRecycleBin, _GetIFile).
. "$PSScriptRoot\_recycle-bin.ps1"

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
