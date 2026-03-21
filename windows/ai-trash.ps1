# ai-trash.ps1 — browse, restore, and empty the AI trash
#
# Usage:
#   ai-trash.ps1 status
#   ai-trash.ps1 list
#   ai-trash.ps1 restore <name>
#   ai-trash.ps1 empty [--force] [--older-than <days>]
#   ai-trash.ps1 version

param(
    [Parameter(Position=0)]
    [string]$Command = '',

    [Parameter(Position=1, ValueFromRemainingArguments)]
    [string[]]$Args = @()
)

$ErrorActionPreference = 'Stop'

$TRASH_DIR = "$env:USERPROFILE\.Trash\ai-trash"
$PROG      = 'ai-trash'
$VERSION   = '1.0.1'

# ─── Helpers ───────────────────────────────────────────────────────────────────

function _Usage {
    Write-Host "Usage: $PROG <command> [options]"
    Write-Host ''
    Write-Host 'Commands:'
    Write-Host '  status                       Show summary of AI trash contents'
    Write-Host '  list                         List all items with deletion time and original path'
    Write-Host '  restore <name>               Restore item to its original location'
    Write-Host '  empty [--force]              Permanently delete all items'
    Write-Host '  empty --older-than <days>    Permanently delete items older than N days'
    Write-Host '  version                      Print version'
}

function _FmtSize {
    param([long]$Bytes)
    if     ($Bytes -ge 1073741824) { return '{0:F1}G' -f ($Bytes / 1073741824) }
    elseif ($Bytes -ge 1048576)    { return '{0:F1}M' -f ($Bytes / 1048576) }
    elseif ($Bytes -ge 1024)       { return '{0:F1}K' -f ($Bytes / 1024) }
    else                           { return "${Bytes}B" }
}

function _ReadMeta {
    param([string]$ItemPath, [string]$Key)

    # Try NTFS ADS first.
    try {
        $val = Get-Content -LiteralPath $ItemPath -Stream "ai-trash.$Key" -ErrorAction Stop
        return ($val -join '').Trim()
    } catch { }

    # Fall back to sidecar JSON.
    $sidecar = Join-Path (Split-Path $ItemPath -Parent) ('.' + (Split-Path $ItemPath -Leaf) + '.ai-trash')
    if (Test-Path -LiteralPath $sidecar) {
        try {
            $obj = Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json
            return $obj.$Key
        } catch { }
    }

    return $null
}

# ─── status ────────────────────────────────────────────────────────────────────

function Cmd-Status {
    if (-not (Test-Path -LiteralPath $TRASH_DIR)) {
        Write-Host 'AI trash is empty.'
        return
    }

    $items = Get-ChildItem -LiteralPath $TRASH_DIR -ErrorAction SilentlyContinue
    if (-not $items -or $items.Count -eq 0) {
        Write-Host 'AI trash is empty.'
        return
    }

    $count       = 0
    $totalBytes  = [long]0
    $oldestTime  = $null
    $oldestName  = ''
    $newestTime  = $null
    $newestName  = ''

    foreach ($item in $items) {
        $count++
        $rawSize   = _ReadMeta -ItemPath $item.FullName -Key 'original-size'
        $deletedAt = _ReadMeta -ItemPath $item.FullName -Key 'deleted-at'

        if ($rawSize -match '^\d+$') { $totalBytes += [long]$rawSize }

        if ($deletedAt) {
            try { $dt = [DateTime]::Parse($deletedAt) } catch { $dt = $null }
            if ($dt) {
                if ($null -eq $oldestTime -or $dt -lt $oldestTime) {
                    $oldestTime = $dt; $oldestName = $item.Name
                }
                if ($null -eq $newestTime -or $dt -gt $newestTime) {
                    $newestTime = $dt; $newestName = $item.Name
                }
            }
        }
    }

    Write-Host ('Items:    {0}' -f $count)
    if ($totalBytes -gt 0) {
        Write-Host ('Size:     {0}' -f (_FmtSize $totalBytes))
    }
    if ($oldestName) {
        Write-Host ('Oldest:   {0} ({1})' -f $oldestName, $oldestTime.ToString('yyyy-MM-dd'))
    }
    if ($newestName) {
        Write-Host ('Newest:   {0} ({1})' -f $newestName, $newestTime.ToString('yyyy-MM-dd'))
    }
    Write-Host ('Location: {0}' -f $TRASH_DIR)
}

# ─── list ──────────────────────────────────────────────────────────────────────

function Cmd-List {
    if (-not (Test-Path -LiteralPath $TRASH_DIR)) {
        Write-Host 'AI trash is empty.'
        return
    }

    $items = Get-ChildItem -LiteralPath $TRASH_DIR -ErrorAction SilentlyContinue |
             Sort-Object Name
    if (-not $items -or $items.Count -eq 0) {
        Write-Host 'AI trash is empty.'
        return
    }

    # Determine terminal width for path column truncation.
    try { $termWidth = $Host.UI.RawUI.WindowSize.Width } catch { $termWidth = 120 }
    $pathWidth = $termWidth - 81
    if ($pathWidth -lt 30) { $pathWidth = 30 }

    $hdr = '{0,-36}  {1,-20}  {2,-5}  {3,-10}  {4}' -f 'NAME','DELETED (UTC)','SIZE','BY','ORIGINAL PATH'
    $sep = '{0,-36}  {1,-20}  {2,-5}  {3,-10}  {4}' -f (('-' * 36)),('-' * 20),'-----',('-' * 10),('-' * 30)
    Write-Host $hdr
    Write-Host $sep

    $count = 0
    foreach ($item in $items) {
        $origPath   = _ReadMeta -ItemPath $item.FullName -Key 'original-path'
        $deletedAt  = _ReadMeta -ItemPath $item.FullName -Key 'deleted-at'
        $deletedBy  = _ReadMeta -ItemPath $item.FullName -Key 'deleted-by'
        $deletedProc= _ReadMeta -ItemPath $item.FullName -Key 'deleted-by-process'
        $rawSize    = _ReadMeta -ItemPath $item.FullName -Key 'original-size'

        # Format deleted-at: replace T with space, strip trailing Z.
        if ($deletedAt) {
            $deletedAt = $deletedAt -replace 'T', ' ' -replace 'Z$', ''
        }

        if ($rawSize -match '^\d+$') {
            $sizeStr = _FmtSize ([long]$rawSize)
        } elseif ($item.PSIsContainer) {
            $sizeStr = 'dir'
        } else {
            $sizeStr = '-'
        }

        if (-not $origPath)   { $origPath  = '(unknown)' }
        if (-not $deletedAt)  { $deletedAt = '(unknown)' }
        if (-not $deletedBy)  { $deletedBy = '-' }
        if ($deletedProc -and $deletedProc -ne $deletedBy) {
            $deletedBy = "$deletedBy ($deletedProc)"
        }

        # Truncate path to fit terminal width.
        if ($origPath.Length -gt $pathWidth) {
            $origPath = '...' + $origPath.Substring($origPath.Length - ($pathWidth - 3))
        }

        $line = '{0,-36}  {1,-20}  {2,-5}  {3,-10}  {4}' -f `
            $item.Name, $deletedAt, $sizeStr, $deletedBy, $origPath
        Write-Host $line
        $count++
    }

    Write-Host ''
    Write-Host "$count item(s) in AI trash"
}

# ─── restore ───────────────────────────────────────────────────────────────────

function Cmd-Restore {
    param([string[]]$RestoreArgs)

    if (-not $RestoreArgs -or $RestoreArgs.Count -eq 0) {
        Write-Error "$PROG restore: item name required"
        exit 1
    }

    $target = $RestoreArgs[0]

    # Resolve the item in trash.
    $candidateInTrash = Join-Path $TRASH_DIR $target
    if (Test-Path -LiteralPath $candidateInTrash) {
        $itemPath = $candidateInTrash
    } elseif (Test-Path -LiteralPath $target) {
        $itemPath = $target
    } else {
        Write-Error "$PROG`: '$target' not found in AI trash"
        exit 1
    }

    $origPath = _ReadMeta -ItemPath $itemPath -Key 'original-path'
    if (-not $origPath) {
        Write-Error "$PROG`: no original path recorded for '$(Split-Path $itemPath -Leaf)'"
        exit 1
    }

    if (Test-Path -LiteralPath $origPath) {
        $response = Read-Host "$PROG`: '$origPath' already exists. Overwrite? [y/N]"
        if ($response -notmatch '^[Yy]') {
            Write-Host 'aborted.'
            exit 0
        }
    }

    $parentDir = Split-Path $origPath -Parent
    if (-not (Test-Path -LiteralPath $parentDir)) {
        $null = New-Item -ItemType Directory -Path $parentDir -Force
    }

    try {
        Move-Item -LiteralPath $itemPath -Destination $origPath -Force -ErrorAction Stop

        # Also move sidecar JSON if present (non-NTFS fallback).
        $sidecar = Join-Path (Split-Path $itemPath -Parent) ('.' + (Split-Path $itemPath -Leaf) + '.ai-trash')
        if (Test-Path -LiteralPath $sidecar) {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
        }

        Write-Host "restored -> $origPath"
    } catch {
        Write-Error "$PROG`: failed to restore '$(Split-Path $itemPath -Leaf)': $_"
        exit 1
    }
}

# ─── empty ─────────────────────────────────────────────────────────────────────

function Cmd-Empty {
    param([string[]]$EmptyArgs)

    $force      = $false
    $olderThan  = $null

    $i = 0
    while ($i -lt $EmptyArgs.Count) {
        switch ($EmptyArgs[$i]) {
            '--force'      { $force = $true }
            '--older-than' {
                $i++
                if ($i -ge $EmptyArgs.Count) {
                    Write-Error "$PROG empty: --older-than requires a value"
                    exit 1
                }
                $olderThan = [int]$EmptyArgs[$i]
            }
            default {
                Write-Error "$PROG empty: unknown option '$($EmptyArgs[$i])'"
                exit 1
            }
        }
        $i++
    }

    if (-not (Test-Path -LiteralPath $TRASH_DIR)) {
        Write-Host 'AI trash is already empty.'
        return
    }

    $allItems = Get-ChildItem -LiteralPath $TRASH_DIR -ErrorAction SilentlyContinue

    if ($null -ne $olderThan) {
        $cutoff = (Get-Date).AddDays(-$olderThan)
        $items  = $allItems | Where-Object { $_.LastWriteTime -lt $cutoff }
    } else {
        $items  = $allItems
    }

    if (-not $items -or @($items).Count -eq 0) {
        Write-Host 'No items to delete.'
        return
    }

    $count = @($items).Count

    if (-not $force) {
        $qualifier = if ($null -ne $olderThan) { " older than $olderThan days" } else { '' }
        $response  = Read-Host "$PROG`: permanently delete $count item(s)${qualifier}? [y/N]"
        if ($response -notmatch '^[Yy]') {
            Write-Host 'aborted.'
            exit 0
        }
    }

    foreach ($item in $items) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        # Remove sidecar if present.
        $sidecar = Join-Path (Split-Path $item.FullName -Parent) ('.' + $item.Name + '.ai-trash')
        if (Test-Path -LiteralPath $sidecar) {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "deleted $count item(s)."
}

# ─── dispatch ──────────────────────────────────────────────────────────────────

switch ($Command.ToLower()) {
    'status'              { Cmd-Status }
    'list'                { Cmd-List }
    'restore'             { Cmd-Restore -RestoreArgs $Args }
    'empty'               { Cmd-Empty   -EmptyArgs   $Args }
    { $_ -in 'version','--version','-v' } { Write-Host "ai-trash $VERSION" }
    { $_ -in 'help','--help','-h','' }    { _Usage }
    default {
        Write-Error "$PROG`: unknown command '$Command'"
        _Usage
        exit 1
    }
}
