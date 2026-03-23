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

$TRASH_DIR     = "$env:USERPROFILE\.Trash\ai-trash"
$MANIFEST_PATH = "$env:USERPROFILE\.config\ai-trash\manifest.json"
$PROG          = 'ai-trash'
$VERSION       = '1.2.0'

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

# ─── Manifest helpers ──────────────────────────────────────────────────────────

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

# ─── Recycle Bin helpers ───────────────────────────────────────────────────────

function _FindInRecycleBin {
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
                    if ($path -ieq $OriginalPath) {
                        $rLeaf = '$R' + $iFile.Name.Substring(2)
                        $rPath = Join-Path $binDir $rLeaf
                        return [PSCustomObject]@{ Path = $rPath }
                    }
                } catch { }
            }
        }
    } catch { }

    return $null
}

# Returns the $I metadata file path corresponding to a $R file path.
function _GetIFile {
    param([string]$RFilePath)
    $parent = Split-Path $RFilePath -Parent
    $leaf   = Split-Path $RFilePath -Leaf   # e.g. $R123456.txt
    $iLeaf  = '$I' + $leaf.Substring(2)     # e.g. $I123456.txt
    return Join-Path $parent $iLeaf
}

# ─── Legacy metadata helper ────────────────────────────────────────────────────

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
    # Load and reconcile manifest entries (Recycle Bin items).
    $manifest    = _ReadManifest
    $validEntries = [System.Collections.Generic.List[object]]::new()
    $pruned      = $false

    if ($manifest.Count -gt 0) {
        foreach ($entry in $manifest) {
            if ($null -ne (_FindInRecycleBin -OriginalPath $entry.'original-path')) {
                $validEntries.Add($entry)
            } else {
                $pruned = $true
            }
        }
        if ($pruned) { _WriteManifest -Entries $validEntries }
    }

    # Load legacy items (files in custom folder).
    $legacyItems = @()
    if (Test-Path -LiteralPath $TRASH_DIR) {
        $legacyItems = @(Get-ChildItem -LiteralPath $TRASH_DIR -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -notlike '.*' })
    }

    $totalCount = $validEntries.Count + $legacyItems.Count
    if ($totalCount -eq 0) {
        Write-Host 'AI trash is empty.'
        return
    }

    $totalBytes = [long]0
    $oldestTime = $null
    $oldestName = ''
    $newestTime = $null
    $newestName = ''

    # Aggregate manifest entries.
    foreach ($entry in $validEntries) {
        $rawSize = $entry.'original-size'
        if ($rawSize -match '^\d+$') { $totalBytes += [long]$rawSize }
        $deletedAt = $entry.'deleted-at'
        if ($deletedAt) {
            try { $dt = [DateTime]::Parse($deletedAt) } catch { $dt = $null }
            if ($dt) {
                $name = Split-Path $entry.'original-path' -Leaf
                if ($null -eq $oldestTime -or $dt -lt $oldestTime) { $oldestTime = $dt; $oldestName = $name }
                if ($null -eq $newestTime -or $dt -gt $newestTime) { $newestTime = $dt; $newestName = $name }
            }
        }
    }

    # Aggregate legacy items.
    foreach ($item in $legacyItems) {
        $rawSize   = _ReadMeta -ItemPath $item.FullName -Key 'original-size'
        $deletedAt = _ReadMeta -ItemPath $item.FullName -Key 'deleted-at'
        if ($rawSize -match '^\d+$') { $totalBytes += [long]$rawSize }
        if ($deletedAt) {
            try { $dt = [DateTime]::Parse($deletedAt) } catch { $dt = $null }
            if ($dt) {
                if ($null -eq $oldestTime -or $dt -lt $oldestTime) { $oldestTime = $dt; $oldestName = $item.Name }
                if ($null -eq $newestTime -or $dt -gt $newestTime) { $newestTime = $dt; $newestName = $item.Name }
            }
        }
    }

    Write-Host ('Items:    {0}' -f $totalCount)
    if ($totalBytes -gt 0) {
        Write-Host ('Size:     {0}' -f (_FmtSize $totalBytes))
    }
    if ($oldestName) {
        Write-Host ('Oldest:   {0} ({1})' -f $oldestName, $oldestTime.ToString('yyyy-MM-dd'))
    }
    if ($newestName) {
        Write-Host ('Newest:   {0} ({1})' -f $newestName, $newestTime.ToString('yyyy-MM-dd'))
    }
    Write-Host ('Location: Recycle Bin + {0}' -f $TRASH_DIR)
}

# ─── list ──────────────────────────────────────────────────────────────────────

function Cmd-List {
    # Load and reconcile manifest entries (Recycle Bin items).
    $manifest     = _ReadManifest
    $validEntries = [System.Collections.Generic.List[object]]::new()
    $pruned       = $false

    if ($manifest.Count -gt 0) {
        foreach ($entry in $manifest) {
            if ($null -ne (_FindInRecycleBin -OriginalPath $entry.'original-path')) {
                $validEntries.Add($entry)
            } else {
                $pruned = $true
            }
        }
        if ($pruned) { _WriteManifest -Entries $validEntries }
    }

    # Load legacy items.
    $legacyItems = @()
    if (Test-Path -LiteralPath $TRASH_DIR) {
        $legacyItems = @(Get-ChildItem -LiteralPath $TRASH_DIR -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -notlike '.*' } |
                         Sort-Object Name)
    }

    $totalCount = $validEntries.Count + $legacyItems.Count
    if ($totalCount -eq 0) {
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

    # Display manifest (Recycle Bin) entries.
    foreach ($entry in ($validEntries | Sort-Object { $_.'deleted-at' })) {
        $origPath  = $entry.'original-path'
        $deletedAt = $entry.'deleted-at'
        $deletedBy = $entry.'deleted-by'
        $deletedProc = $entry.'deleted-by-process'
        $rawSize   = $entry.'original-size'
        $name      = Split-Path $origPath -Leaf

        if ($deletedAt) { $deletedAt = $deletedAt -replace 'T', ' ' -replace 'Z$', '' }
        if ($rawSize -match '^\d+$') { $sizeStr = _FmtSize ([long]$rawSize) } else { $sizeStr = '-' }
        if (-not $origPath)   { $origPath  = '(unknown)' }
        if (-not $deletedAt)  { $deletedAt = '(unknown)' }
        if (-not $deletedBy)  { $deletedBy = '-' }
        if ($deletedProc -and $deletedProc -ne $deletedBy) { $deletedBy = "$deletedBy ($deletedProc)" }
        if ($origPath.Length -gt $pathWidth) { $origPath = '...' + $origPath.Substring($origPath.Length - ($pathWidth - 3)) }

        Write-Host ('{0,-36}  {1,-20}  {2,-5}  {3,-10}  {4}' -f $name, $deletedAt, $sizeStr, $deletedBy, $origPath)
    }

    # Display legacy folder entries.
    foreach ($item in $legacyItems) {
        $origPath    = _ReadMeta -ItemPath $item.FullName -Key 'original-path'
        $deletedAt   = _ReadMeta -ItemPath $item.FullName -Key 'deleted-at'
        $deletedBy   = _ReadMeta -ItemPath $item.FullName -Key 'deleted-by'
        $deletedProc = _ReadMeta -ItemPath $item.FullName -Key 'deleted-by-process'
        $rawSize     = _ReadMeta -ItemPath $item.FullName -Key 'original-size'

        if ($deletedAt) { $deletedAt = $deletedAt -replace 'T', ' ' -replace 'Z$', '' }
        if ($rawSize -match '^\d+$') { $sizeStr = _FmtSize ([long]$rawSize) }
        elseif ($item.PSIsContainer) { $sizeStr = 'dir' }
        else                         { $sizeStr = '-' }
        if (-not $origPath)   { $origPath  = '(unknown)' }
        if (-not $deletedAt)  { $deletedAt = '(unknown)' }
        if (-not $deletedBy)  { $deletedBy = '-' }
        if ($deletedProc -and $deletedProc -ne $deletedBy) { $deletedBy = "$deletedBy ($deletedProc)" }
        if ($origPath.Length -gt $pathWidth) { $origPath = '...' + $origPath.Substring($origPath.Length - ($pathWidth - 3)) }

        Write-Host ('{0,-36}  {1,-20}  {2,-5}  {3,-10}  {4}' -f $item.Name, $deletedAt, $sizeStr, $deletedBy, $origPath)
    }

    Write-Host ''
    Write-Host "$totalCount item(s) in AI trash"
}

# ─── restore ───────────────────────────────────────────────────────────────────

function Cmd-Restore {
    param([string[]]$RestoreArgs)

    if (-not $RestoreArgs -or $RestoreArgs.Count -eq 0) {
        Write-Error "$PROG restore: item name required"
        exit 1
    }

    $target = $RestoreArgs[0]

    # ── Try manifest (Recycle Bin) first ──────────────────────────────────────
    $manifest = _ReadManifest
    # Match by filename component of original-path (most recent first).
    $matches_ = @($manifest | Where-Object { (Split-Path $_.'original-path' -Leaf) -ieq $target }) |
                Sort-Object { $_.'deleted-at' } -Descending

    if ($matches_.Count -gt 0) {
        $entry    = $matches_[0]
        $origPath = $entry.'original-path'
        $binItem  = _FindInRecycleBin -OriginalPath $origPath

        if ($null -ne $binItem) {
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
                # Move the $R file back to its original location.
                Microsoft.PowerShell.Management\Move-Item -LiteralPath $binItem.Path -Destination $origPath -Force -ErrorAction Stop

                # Remove the orphaned $I metadata file.
                $iFile = _GetIFile -RFilePath $binItem.Path
                if (Test-Path -LiteralPath $iFile) {
                    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $iFile -Force -ErrorAction SilentlyContinue
                }

                # Remove the manifest entry.
                $remaining = @($manifest | Where-Object { $_ -ne $entry })
                _WriteManifest -Entries $remaining

                Write-Host "restored -> $origPath"
                return
            } catch {
                Write-Error "$PROG`: failed to restore '$target' from Recycle Bin: $_"
                exit 1
            }
        }
        # Bin item not found (user may have emptied Recycle Bin) — prune and fall through.
        $remaining = @($manifest | Where-Object { $_ -ne $entry })
        _WriteManifest -Entries $remaining
    }

    # ── Fall through to legacy folder ─────────────────────────────────────────
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

        # Remove sidecar JSON if present (non-NTFS fallback).
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

    $force     = $false
    $olderThan = $null

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

    # ── Collect manifest (Recycle Bin) entries to delete ──────────────────────
    $manifest = _ReadManifest
    $toDelete = [System.Collections.Generic.List[object]]::new()
    $toKeep   = [System.Collections.Generic.List[object]]::new()

    if ($null -ne $olderThan) {
        $cutoff = (Get-Date).AddDays(-$olderThan)
        foreach ($entry in $manifest) {
            $keep = $true
            try {
                $dt = [DateTime]::Parse($entry.'deleted-at')
                if ($dt -lt $cutoff) { $keep = $false }
            } catch { }
            if ($keep) { $toKeep.Add($entry) } else { $toDelete.Add($entry) }
        }
    } else {
        $toDelete.AddRange($manifest)
    }

    # ── Collect legacy folder items to delete ─────────────────────────────────
    $legacyToDelete = @()
    if (Test-Path -LiteralPath $TRASH_DIR) {
        $allLegacy = @(Get-ChildItem -LiteralPath $TRASH_DIR -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -notlike '.*' })
        if ($null -ne $olderThan) {
            $cutoff         = (Get-Date).AddDays(-$olderThan)
            $legacyToDelete = $allLegacy | Where-Object { $_.LastWriteTime -lt $cutoff }
        } else {
            $legacyToDelete = $allLegacy
        }
    }

    $totalCount = $toDelete.Count + @($legacyToDelete).Count
    if ($totalCount -eq 0) {
        Write-Host 'No items to delete.'
        return
    }

    if (-not $force) {
        $qualifier = if ($null -ne $olderThan) { " older than $olderThan days" } else { '' }
        $response  = Read-Host "$PROG`: permanently delete $totalCount item(s)${qualifier}? [y/N]"
        if ($response -notmatch '^[Yy]') {
            Write-Host 'aborted.'
            exit 0
        }
    }

    # Delete manifest (Recycle Bin) entries.
    foreach ($entry in $toDelete) {
        $binItem = _FindInRecycleBin -OriginalPath $entry.'original-path'
        if ($null -ne $binItem) {
            try {
                $rFile = $binItem.Path
                $iFile = _GetIFile -RFilePath $rFile
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $rFile -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $iFile) {
                    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $iFile -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }
    _WriteManifest -Entries $toKeep

    # Delete legacy folder items.
    foreach ($item in $legacyToDelete) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $sidecar = Join-Path (Split-Path $item.FullName -Parent) ('.' + $item.Name + '.ai-trash')
        if (Test-Path -LiteralPath $sidecar) {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "deleted $totalCount item(s)."
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
