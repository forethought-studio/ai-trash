# rm_wrapper.ps1 — transparent Remove-Item replacement that routes files to ai-trash
#
# Dot-source this file from your $PROFILE to activate it:
#   . "$env:USERPROFILE\.ai-trash\rm_wrapper.ps1"
#
# This defines a Remove-Item function that shadows the built-in cmdlet.
# When the real cmdlet is needed it is called via its fully-qualified name:
#   Microsoft.PowerShell.Management\Remove-Item

Add-Type -AssemblyName Microsoft.VisualBasic

# ─── Configuration ─────────────────────────────────────────────────────────────

$_AiTrashConfigPath = "$env:USERPROFILE\.config\ai-trash\config.ps1"

# Defaults — overridden by the user's config file when present.
$_AiTrashMode = 'selective'

$_AiTrashAiProcesses = @(
    'claude',       # Claude Code (Anthropic)
    'gemini',       # Gemini CLI (Google)
    'goose',        # Goose (Block)
    'opencode',     # OpenCode
    'aider',        # Aider
    'devin',        # Devin (Cognition)
    'kiro-cli'      # Kiro CLI (AWS)
)

$_AiTrashAiProcessArgs = @(
    'codex',        # OpenAI Codex CLI   (node .../codex/...)
    'aider',        # Aider              (python .../aider/...)
    'gemini-cli',   # Gemini CLI via npx (node .../@google/gemini-cli/...)
    'gh copilot',   # GitHub Copilot CLI (node .../gh-copilot/...)
    'openhands',    # OpenHands          (python .../openhands/...)
    'opencode'      # OpenCode           (belt+suspenders)
)

$_AiTrashAiEnvVars = @(
    'TERM_PROGRAM=cursor',       # Cursor IDE
    'TERM_PROGRAM=vscode',       # VS Code (Copilot, Cline, Continue, Roo, etc.)
    'TERM_PROGRAM=windsurf',     # Windsurf (formerly Codeium)
    'TERM_PROGRAM=WarpTerminal'  # Warp terminal
)

# Load user config — dot-sourced so it overrides the defaults above.
if (Test-Path $_AiTrashConfigPath) {
    . $_AiTrashConfigPath
    # Map config variable names to the internal prefixed names used here.
    if ($null -ne $MODE)            { $script:_AiTrashMode            = $MODE }
    if ($null -ne $AI_PROCESSES)    { $script:_AiTrashAiProcesses     = $AI_PROCESSES }
    if ($null -ne $AI_PROCESS_ARGS) { $script:_AiTrashAiProcessArgs   = $AI_PROCESS_ARGS }
    if ($null -ne $AI_ENV_VARS)     { $script:_AiTrashAiEnvVars       = $AI_ENV_VARS }
}

# ─── AI process detection ──────────────────────────────────────────────────────

function _AiTrash-IsAiProcess {
    # Tier 1: environment variable check — zero process lookup cost.
    foreach ($entry in $script:_AiTrashAiEnvVars) {
        $parts = $entry -split '=', 2
        if ($parts.Count -eq 2) {
            $varName  = $parts[0]
            $varValue = $parts[1]
            $actual   = [System.Environment]::GetEnvironmentVariable($varName)
            if ($actual -eq $varValue) { return $true }
        }
    }

    # Tier 2: walk the process tree from the current process up to PID 0/1.
    # Use CimInstance for a single snapshot — faster than repeated Get-Process calls.
    try {
        $allProcs = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
                    Select-Object -Property ProcessId, ParentProcessId, Name, CommandLine
    } catch {
        return $false
    }

    # Build a hashtable keyed by PID for O(1) parent lookup.
    $procMap = @{}
    foreach ($p in $allProcs) {
        $procMap[$p.ProcessId] = $p
    }

    $pid = $PID
    $visited = [System.Collections.Generic.HashSet[int]]::new()

    while ($true) {
        if (-not $visited.Add($pid)) { break }   # loop guard

        $proc = $procMap[$pid]
        if ($null -eq $proc) { break }

        $procName = [System.IO.Path]::GetFileNameWithoutExtension($proc.Name)

        # Match executable name against AI_PROCESSES list.
        foreach ($ai in $script:_AiTrashAiProcesses) {
            if ($procName -eq $ai) { return $true }
        }

        # Match full command line against AI_PROCESS_ARGS (node/python wrappers).
        if ($null -ne $proc.CommandLine -and $script:_AiTrashAiProcessArgs.Count -gt 0) {
            foreach ($pattern in $script:_AiTrashAiProcessArgs) {
                if ($proc.CommandLine -like "*$pattern*") { return $true }
            }
        }

        $parentId = $proc.ParentProcessId
        if ($parentId -le 1 -or $parentId -eq $pid) { break }
        $pid = $parentId
    }

    return $false
}

# ─── Manifest helpers ──────────────────────────────────────────────────────────

$_AiTrashManifestPath = "$env:USERPROFILE\.config\ai-trash\manifest.json"

function _AiTrash-ReadManifest {
    $path = $script:_AiTrashManifestPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $json    = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
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

function _AiTrash-WriteManifest {
    param($Entries)
    $path = $script:_AiTrashManifestPath
    $dir  = Split-Path $path -Parent
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
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function _AiTrash-AddManifestEntry {
    param(
        [string]$OriginalPath,
        [string]$DeletedAt,
        [string]$DeletedBy,
        [string]$DeletedByProcess,
        [string]$OriginalSize
    )
    $entries = @(_AiTrash-ReadManifest)
    $entry   = [ordered]@{
        'original-path'      = $OriginalPath
        'deleted-at'         = $DeletedAt
        'deleted-by'         = $DeletedBy
        'deleted-by-process' = $DeletedByProcess
        'original-size'      = $OriginalSize
    }
    $entries += $entry
    _AiTrash-WriteManifest -Entries $entries
}

# ─── Recycle Bin availability helpers ─────────────────────────────────────────

# Returns $true if the Windows Recycle Bin is available for the given path.
# $false means SendToRecycleBin will silently permanently delete — use legacy fallback instead.
function _AiTrash-IsBinAvailable {
    param([string]$Path)
    # Network paths (UNC or mapped network drive): SHFileOperation with FOF_ALLOWUNDO
    # silently permanently deletes them instead of recycling.
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if ($root.StartsWith('\\')) { return $false }  # UNC path
        $driveInfo = [System.IO.DriveInfo]::new($root)
        if ($driveInfo.DriveType -eq [System.IO.DriveType]::Network) { return $false }
    } catch { }

    # Policy: Recycle Bin disabled globally via Group Policy or user setting.
    try {
        $pol = Get-ItemProperty -LiteralPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
                   -Name 'NoRecycleFiles' -ErrorAction SilentlyContinue
        if ($pol -and $pol.NoRecycleFiles -eq 1) { return $false }
        $pol = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
                   -Name 'NoRecycleFiles' -ErrorAction SilentlyContinue
        if ($pol -and $pol.NoRecycleFiles -eq 1) { return $false }
    } catch { }

    return $true
}

# Returns $true if OriginalPath appears in $RECYCLE.BIN\<SID> as a $I metadata file.
# Used after DeleteFile/DeleteDirectory to verify the file was actually recycled (not
# silently permanently deleted due to quota, file-size limits, or other edge cases not
# caught by the pre-check). Returns $true when the bin directory is inaccessible (optimistic
# to avoid false "permanently deleted" warnings when we simply cannot read the bin).
function _AiTrash-ConfirmInRecycleBin {
    param([string]$OriginalPath)
    try {
        $sid    = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $root   = [System.IO.Path]::GetPathRoot($OriginalPath)
        $binDir = Join-Path $root "`$RECYCLE.BIN\$sid"
        if (-not (Test-Path -LiteralPath $binDir -ErrorAction SilentlyContinue)) { return $true }
        $iFiles = Get-ChildItem -LiteralPath $binDir -Filter '$I*' -Force -ErrorAction SilentlyContinue
        foreach ($iFile in $iFiles) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($iFile.FullName)
                if ($bytes.Length -lt 28) { continue }
                $version   = [System.BitConverter]::ToInt64($bytes, 0)
                $pathStart = if ($version -ge 2) { 28 } else { 24 }
                $pathBytes = $bytes[$pathStart..($bytes.Length - 1)]
                $path      = [System.Text.Encoding]::Unicode.GetString($pathBytes).TrimEnd([char]0)
                if ($path -ieq $OriginalPath) { return $true }
            } catch { }
        }
        return $false
    } catch { return $true }  # optimistic on error — avoid false "permanently deleted" warnings
}

# ─── Metadata helpers (legacy folder) ─────────────────────────────────────────

# Detect whether the volume hosting $Path uses NTFS.
function _AiTrash-IsNtfs {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        $drive = Get-PSDrive -Name ($root.TrimEnd(':\')) -ErrorAction SilentlyContinue
        if ($null -ne $drive -and $drive.Provider.Name -eq 'FileSystem') {
            $vol = Get-Volume -DriveLetter ($root[0]) -ErrorAction SilentlyContinue
            if ($null -ne $vol) {
                return ($vol.FileSystemType -eq 'NTFS')
            }
        }
    } catch { }
    # Default to assuming NTFS on Windows when we cannot determine.
    return $true
}

function _AiTrash-WriteMeta {
    param(
        [string]$DestPath,
        [string]$OriginalPath,
        [string]$DeletedAt,
        [string]$DeletedBy,
        [string]$DeletedByProcess,
        [string]$OriginalSize
    )

    $useAds = _AiTrash-IsNtfs -Path $DestPath

    if ($useAds) {
        try {
            Set-Content -LiteralPath $DestPath -Stream 'ai-trash.original-path'      -Value $OriginalPath     -Encoding UTF8 -ErrorAction Stop
            Set-Content -LiteralPath $DestPath -Stream 'ai-trash.deleted-at'         -Value $DeletedAt        -Encoding UTF8 -ErrorAction Stop
            Set-Content -LiteralPath $DestPath -Stream 'ai-trash.deleted-by'         -Value $DeletedBy        -Encoding UTF8 -ErrorAction Stop
            Set-Content -LiteralPath $DestPath -Stream 'ai-trash.deleted-by-process' -Value $DeletedByProcess -Encoding UTF8 -ErrorAction Stop
            if ($OriginalSize) {
                Set-Content -LiteralPath $DestPath -Stream 'ai-trash.original-size'  -Value $OriginalSize     -Encoding UTF8 -ErrorAction Stop
            }
            return
        } catch {
            # Fall through to sidecar on ADS write failure.
        }
    }

    # Sidecar JSON fallback (non-NTFS volumes, e.g. FAT32 USB drives).
    $sidecar = Join-Path (Split-Path $DestPath -Parent) ('.' + (Split-Path $DestPath -Leaf) + '.ai-trash')
    $meta = [ordered]@{
        'original-path'      = $OriginalPath
        'deleted-at'         = $DeletedAt
        'deleted-by'         = $DeletedBy
        'deleted-by-process' = $DeletedByProcess
        'original-size'      = $OriginalSize
    }
    try {
        $meta | ConvertTo-Json | Set-Content -LiteralPath $sidecar -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ─── Trash directory helpers ───────────────────────────────────────────────────

$_AiTrashDir        = "$env:USERPROFILE\.Trash\ai-trash"
$_AiTrashSystemDir  = "$env:USERPROFILE\.Trash"

function _AiTrash-GetTrashDir {
    param([string]$FilePath)
    # On Windows there is only one concept of "boot volume" for user files.
    # Use the per-drive .Recycle.Bin convention for other volumes.
    try {
        $fileRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($FilePath))
        $homeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($env:USERPROFILE))
        if ($fileRoot -ieq $homeRoot) {
            return $script:_AiTrashDir
        } else {
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            return "${fileRoot}`$Recycle.Bin\$sid\ai-trash"
        }
    } catch {
        return $script:_AiTrashDir
    }
}

function _AiTrash-GetUniqueTrashPath {
    param(
        [string]$TrashDir,
        [string]$Name
    )
    # Finder-style collision renaming: foo.txt -> foo (2).txt -> foo (3).txt
    # Hidden files (.bashrc) have no extension.
    if ($Name.StartsWith('.')) {
        $stem = $Name; $ext = ''
    } elseif ($Name.Contains('.')) {
        $ext  = '.' + $Name.Split('.')[-1]
        $stem = $Name.Substring(0, $Name.Length - $ext.Length)
    } else {
        $stem = $Name; $ext = ''
    }

    $candidate = Join-Path $TrashDir $Name
    $i = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $TrashDir "$stem ($i)$ext"
        $i++
    }
    return $candidate
}

# ─── Move to system Recycle Bin (safe mode, non-AI calls) ─────────────────────

function _AiTrash-MoveToRecycleBin {
    param([string[]]$Paths, [bool]$HasForce)
    $shell = New-Object -ComObject Shell.Application
    foreach ($f in $Paths) {
        if (-not (Test-Path -LiteralPath $f)) {
            if (-not $HasForce) {
                Write-Error "Remove-Item: cannot find path '$f'"
            }
            continue
        }
        try {
            $abs = [System.IO.Path]::GetFullPath($f)
            $folder = $shell.Namespace((Split-Path $abs -Parent))
            $item   = $folder.ParseName((Split-Path $abs -Leaf))
            if ($null -ne $item) {
                $item.InvokeVerb('delete')
            } else {
                # Fall back to real Remove-Item if shell cannot parse the item.
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $f -Recurse -Force
            }
        } catch {
            Write-Error "Remove-Item: could not move '$f' to Recycle Bin: $_"
        }
    }
}

# ─── Move files to ai-trash with metadata ─────────────────────────────────────

function _AiTrash-MoveToAiTrash {
    param([string[]]$Paths, [bool]$HasForce, [bool]$Verbose)
    $result = 0
    foreach ($f in $Paths) {
        if (-not (Test-Path -LiteralPath $f)) {
            if (-not $HasForce) {
                Write-Error "Remove-Item: cannot find path '$f'"
                $result = 1
            }
            continue
        }

        try {
            $absPath = [System.IO.Path]::GetFullPath($f)
        } catch {
            $absPath = $f
        }

        # Determine the deleting process name by walking up from parent.
        $deletedByProcess = ''
        try {
            $parentProc = Get-Process -Id (
                (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
            ) -ErrorAction Stop
            $deletedByProcess = [System.IO.Path]::GetFileNameWithoutExtension($parentProc.Name)
        } catch { }

        $deletedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $deletedBy = $env:USERNAME

        # Capture size before deletion (skip for directories — too slow).
        $origSize = ''
        try {
            $itemObj = Get-Item -LiteralPath $f -ErrorAction Stop
            if (-not $itemObj.PSIsContainer) {
                $origSize = $itemObj.Length.ToString()
            }
        } catch { }

        # Primary path: send to the real Windows Recycle Bin via VisualBasic.FileIO.
        # Option 1 (pre-check): skip bin entirely for paths where SendToRecycleBin is known
        # to silently permanently delete (network paths, NoRecycleFiles policy).
        $sentToRecycleBin   = $false
        $permanentlyDeleted = $false
        if (_AiTrash-IsBinAvailable -Path $absPath) {
            try {
                $itemObj = Get-Item -LiteralPath $f -ErrorAction Stop
                if ($itemObj.PSIsContainer) {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                        $absPath,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                    )
                } else {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                        $absPath,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                    )
                }
                # Option 2 (post-scan): verify the file actually landed in the Recycle Bin.
                # SendToRecycleBin can silently permanently delete when the bin quota is full
                # or other edge cases the pre-check cannot predict.
                if (_AiTrash-ConfirmInRecycleBin -OriginalPath $absPath) {
                    $sentToRecycleBin = $true
                } else {
                    $permanentlyDeleted = $true
                    Write-Warning "Remove-Item: '$f' could not be sent to the Recycle Bin and was permanently deleted."
                }
            } catch { }
        }

        if ($sentToRecycleBin) {
            if ($Verbose) { Write-Host $f }
            _AiTrash-AddManifestEntry `
                -OriginalPath     $absPath `
                -DeletedAt        $deletedAt `
                -DeletedBy        $deletedBy `
                -DeletedByProcess $deletedByProcess `
                -OriginalSize     $origSize
            continue
        }

        if ($permanentlyDeleted) {
            # File is already gone — no fallback possible, no manifest entry written.
            continue
        }

        # Fallback: move to legacy custom folder (cross-volume, permissions failure, etc.).
        $trashDir = _AiTrash-GetTrashDir -FilePath $f

        try {
            $null = New-Item -ItemType Directory -Path $trashDir -Force -ErrorAction Stop
        } catch {
            Write-Warning "Remove-Item: trash unavailable for '$f', deleting permanently"
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }

        $destPath = _AiTrash-GetUniqueTrashPath -TrashDir $trashDir -Name (Split-Path $f -Leaf)

        try {
            Move-Item -LiteralPath $f -Destination $destPath -ErrorAction Stop
        } catch {
            Write-Error "Remove-Item: could not move '$f' to ai-trash: $_"
            $result = 1
            continue
        }

        if ($Verbose) { Write-Host $f }

        _AiTrash-WriteMeta `
            -DestPath         $destPath `
            -OriginalPath     $absPath `
            -DeletedAt        $deletedAt `
            -DeletedBy        $deletedBy `
            -DeletedByProcess $deletedByProcess `
            -OriginalSize     $origSize

        # Touch the mtime so 30-day cleanup uses trash-time, not original mtime.
        try {
            (Get-Item -LiteralPath $destPath -ErrorAction Stop).LastWriteTimeUtc = [DateTime]::UtcNow
        } catch { }
    }
    return $result
}

# ─── Remove-Item override ──────────────────────────────────────────────────────

function Remove-Item {
    <#
    .SYNOPSIS
        Transparent Remove-Item replacement that routes files deleted by AI tools
        to a recoverable ai-trash folder instead of permanently deleting them.
    .DESCRIPTION
        Dot-source rm_wrapper.ps1 from your PowerShell profile to activate.
        The original cmdlet is always available as:
            Microsoft.PowerShell.Management\Remove-Item
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium', DefaultParameterSetName='Path')]
    param(
        [Parameter(ParameterSetName='Path', Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$Path,

        [Parameter(ParameterSetName='LiteralPath', Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('PSPath')]
        [string[]]$LiteralPath,

        [switch]$Recurse,
        [switch]$Force,

        # Passthrough parameters forwarded to the real cmdlet when needed.
        [string]$Filter,
        [string[]]$Include,
        [string[]]$Exclude
    )

    begin {
        $allPaths = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($LiteralPath) {
            foreach ($lp in $LiteralPath) { $allPaths.Add($lp) }
        } elseif ($Path) {
            foreach ($p in $Path) {
                # Expand wildcards the same way the real cmdlet would.
                $resolved = $null
                try {
                    $resolved = Resolve-Path -Path $p -ErrorAction SilentlyContinue
                } catch { }
                if ($resolved) {
                    foreach ($r in $resolved) { $allPaths.Add($r.ProviderPath) }
                } else {
                    $allPaths.Add($p)
                }
            }
        }
    }

    end {
        # Pass unsupported scenarios straight to the real cmdlet:
        # - WhatIf / Confirm interactive flows
        # - Filter / Include / Exclude (glob filtering within directories)
        if ($PSBoundParameters.ContainsKey('WhatIf') -or $PSBoundParameters.ContainsKey('Confirm') -or $Filter -or $Include -or $Exclude) {
            $params = @{ Path = $allPaths.ToArray(); Force = $Force; Recurse = $Recurse }
            if ($Filter)  { $params['Filter']  = $Filter }
            if ($Include) { $params['Include'] = $Include }
            if ($Exclude) { $params['Exclude'] = $Exclude }
            if ($PSBoundParameters.ContainsKey('Confirm')) { $params['Confirm'] = $true }
            if ($PSBoundParameters.ContainsKey('WhatIf'))  { $params['WhatIf']  = $true }
            Microsoft.PowerShell.Management\Remove-Item @params
            return
        }

        $hasForce   = $Force.IsPresent
        $hasRecurse = $Recurse.IsPresent
        $hasVerbose = $PSBoundParameters.ContainsKey('Verbose')

        # Guard: no user profile (e.g. SYSTEM account) — pass through unchanged.
        if ([string]::IsNullOrEmpty($env:USERPROFILE)) {
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $allPaths.ToArray() `
                -Recurse:$hasRecurse -Force:$hasForce
            return
        }

        # Determine mode behaviour.
        $isAi = $false
        $safePassthrough = $false
        $mode = $script:_AiTrashMode

        if ($mode -eq 'selective' -or $mode -eq 'safe') {
            $isAi = _AiTrash-IsAiProcess
            if (-not $isAi) {
                if ($mode -eq 'selective') {
                    # Non-AI in selective mode: pass straight through.
                    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $allPaths.ToArray() `
                        -Recurse:$hasRecurse -Force:$hasForce
                    return
                } else {
                    # safe mode: non-AI calls go to Recycle Bin.
                    $safePassthrough = $true
                }
            }
        }
        # 'always' mode: $isAi stays false but we still trash everything.

        # Validate paths exist (for non-Force calls).
        $trashList = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $allPaths) {
            if (-not (Test-Path -LiteralPath $f) -and -not $hasForce) {
                Write-Error "Remove-Item: cannot find path '$f'"
                continue
            }
            $trashList.Add($f)
        }

        if ($trashList.Count -gt 0) {
            if ($safePassthrough) {
                _AiTrash-MoveToRecycleBin -Paths $trashList.ToArray() -HasForce $hasForce
            } else {
                _AiTrash-MoveToAiTrash -Paths $trashList.ToArray() -HasForce $hasForce -Verbose $hasVerbose
            }
        }
    }
}

# Export the function so it is available in the session.
if ($MyInvocation.CommandOrigin -eq 'Module') {
    Export-ModuleMember -Function Remove-Item
}
