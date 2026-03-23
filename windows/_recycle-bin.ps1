# _recycle-bin.ps1 — shared Recycle Bin helpers
#
# Dot-sourced by ai-trash.ps1 and ai-trash-cleanup.ps1.
# DO NOT dot-source from a PowerShell profile — use rm_wrapper.ps1 for that.

# Finds a Recycle Bin item whose stored original path matches OriginalPath.
# When DeletedAt is provided, returns the item whose deletion time is closest
# to it, disambiguating multiple deletions of the same path.
# Returns a COM FolderItem (interactive) or [PSCustomObject]@{ Path = $rPath }
# ($RECYCLE.BIN fallback), or $null if not found.
function _FindInRecycleBin {
    param([string]$OriginalPath, [string]$DeletedAt = '')
    # Try COM Shell.Application first (works in interactive sessions).
    try {
        $shell     = New-Object -ComObject Shell.Application
        $bin       = $shell.Namespace(10)
        $best      = $null
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

# Returns the $I metadata file path corresponding to a $R file path.
function _GetIFile {
    param([string]$RFilePath)
    $parent = Split-Path $RFilePath -Parent
    $leaf   = Split-Path $RFilePath -Leaf   # e.g. $R123456.txt
    $iLeaf  = '$I' + $leaf.Substring(2)     # e.g. $I123456.txt
    return Join-Path $parent $iLeaf
}
