# uninstall.ps1 — remove ai-trash from Windows PowerShell
#
# Reverses install.ps1:
#   - Removes the dot-source line from $PROFILE
#   - Unregisters the Task Scheduler task
#   - Optionally removes the install directory and config
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 [--purge]
#
#   --purge   Also delete $env:USERPROFILE\.ai-trash\ and the config directory.
#             The ai-trash folder itself ($env:USERPROFILE\.Trash\ai-trash\) is
#             never removed automatically — use `ai-trash.ps1 empty` first if
#             you want to clear it.

#Requires -Version 5.1

param(
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$INSTALL_DIR    = "$env:USERPROFILE\.ai-trash"
$CONFIG_DIR     = "$env:USERPROFILE\.config\ai-trash"
$TASK_NAME      = 'ai-trash-cleanup'
$MARKER_COMMENT = '# ai-trash: dot-source Remove-Item wrapper'

function Write-Ok {
    param([string]$Msg)
    Write-Host "  [ok] $Msg"
}

function Write-Skip {
    param([string]$Msg)
    Write-Host "  [--] $Msg"
}

Write-Host ''
Write-Host 'ai-trash uninstaller'
Write-Host '===================='
Write-Host ''

# ─── 1. Remove dot-source line from $PROFILE ──────────────────────────────────

Write-Host 'Patching PowerShell profile...'

if (Test-Path -LiteralPath $PROFILE) {
    $lines = Get-Content -LiteralPath $PROFILE -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $lines) { $lines = @() }

    # Remove the marker comment line, the dot-source line, and the blank line
    # immediately preceding them (the blank line install.ps1 always inserts).
    $filtered  = [System.Collections.Generic.List[string]]::new()
    $skipNext  = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($skipNext) {
            $skipNext = $false
            continue
        }

        if ($line.Trim() -eq $MARKER_COMMENT) {
            # Remove the comment line and the dot-source line that follows it.
            $skipNext = $true
            # Also remove the preceding blank line if present.
            if ($filtered.Count -gt 0 -and [string]::IsNullOrWhiteSpace($filtered[$filtered.Count - 1])) {
                $filtered.RemoveAt($filtered.Count - 1)
            }
            continue
        }

        # Remove stray dot-source lines that reference the install dir
        # (belt-and-suspenders in case the comment was deleted manually).
        if ($line -like "*$INSTALL_DIR*rm_wrapper.ps1*") {
            continue
        }

        $filtered.Add($line)
    }

    $newContent = $filtered -join [System.Environment]::NewLine

    # Only write back if we actually changed something.
    $original = $lines -join [System.Environment]::NewLine
    if ($newContent -ne $original) {
        Set-Content -LiteralPath $PROFILE -Value $newContent -Encoding UTF8
        Write-Ok "removed ai-trash lines from $PROFILE"
    } else {
        Write-Skip "no ai-trash lines found in $PROFILE"
    }
} else {
    Write-Skip "profile not found: $PROFILE"
}

# ─── 2. Unregister Task Scheduler task ────────────────────────────────────────

Write-Host ''
Write-Host 'Removing scheduled task...'

try {
    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction Stop
        Write-Ok "unregistered task '$TASK_NAME'"
    } else {
        Write-Skip "task '$TASK_NAME' not found"
    }
} catch {
    Write-Warning "Could not unregister task '$TASK_NAME': $_"
}

# ─── 3. Optionally remove install directory and config ────────────────────────

if ($Purge) {
    Write-Host ''
    Write-Host 'Removing install directory and config (--purge)...'

    if (Test-Path -LiteralPath $INSTALL_DIR) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $INSTALL_DIR -Recurse -Force
        Write-Ok "removed $INSTALL_DIR"
    } else {
        Write-Skip "install dir not found: $INSTALL_DIR"
    }

    if (Test-Path -LiteralPath $CONFIG_DIR) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $CONFIG_DIR -Recurse -Force
        Write-Ok "removed $CONFIG_DIR"
    } else {
        Write-Skip "config dir not found: $CONFIG_DIR"
    }
} else {
    Write-Host ''
    Write-Host "Install directory and config left in place."
    Write-Host "  To fully remove: uninstall.ps1 -Purge"
}

# ─── Done ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host 'Uninstall complete.'
Write-Host ''
Write-Host "Note: your ai-trash folder was not touched."
Write-Host "  To clear it: & `"$INSTALL_DIR\ai-trash.ps1`" empty --force"
Write-Host "  Trash location: $env:USERPROFILE\.Trash\ai-trash\"
Write-Host ''
