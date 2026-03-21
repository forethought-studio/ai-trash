# ai-trash-cleanup.ps1 — purge ai-trash entries older than 30 days
#
# Registered as a Task Scheduler task by install.ps1 to run every 6 hours.
# Can also be run manually at any time.

param(
    [int]$DaysOld = 30
)

$AI_TRASH = "$env:USERPROFILE\.Trash\ai-trash"

if (-not (Test-Path -LiteralPath $AI_TRASH)) {
    exit 0
}

$cutoff = (Get-Date).AddDays(-$DaysOld)

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
