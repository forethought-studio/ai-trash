# install.ps1 — install ai-trash for Windows PowerShell
#
# Run as a normal user (no elevation required).
# The script installs to:
#   $env:USERPROFILE\.ai-trash\          — scripts
#   $env:USERPROFILE\.config\ai-trash\   — config
#
# And registers a Task Scheduler task that runs ai-trash-cleanup.ps1
# every 6 hours.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$INSTALL_DIR   = "$env:USERPROFILE\.ai-trash"
$CONFIG_DIR    = "$env:USERPROFILE\.config\ai-trash"
$CONFIG_FILE   = "$CONFIG_DIR\config.ps1"
$TASK_NAME     = 'ai-trash-cleanup'

# Resolve the directory this script lives in so installs work from any cwd.
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Msg)
    Write-Host "  $Msg"
}

function Write-Ok {
    param([string]$Msg)
    Write-Host "  [ok] $Msg"
}

function Write-Skip {
    param([string]$Msg)
    Write-Host "  [--] $Msg (already present, not overwritten)"
}

# ─── 1. Create install directory ──────────────────────────────────────────────

Write-Host ''
Write-Host 'ai-trash installer'
Write-Host '=================='
Write-Host ''
Write-Host 'Installing files...'

$null = New-Item -ItemType Directory -Path $INSTALL_DIR -Force
Write-Ok "install dir: $INSTALL_DIR"

# ─── 2. Copy scripts ──────────────────────────────────────────────────────────

$filesToCopy = @(
    'rm_wrapper.ps1',
    'ai-trash.ps1',
    'ai-trash-cleanup.ps1'
)

foreach ($file in $filesToCopy) {
    $src  = Join-Path $SCRIPT_DIR $file
    $dest = Join-Path $INSTALL_DIR $file
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warning "Source file not found: $src — skipping"
        continue
    }
    Copy-Item -LiteralPath $src -Destination $dest -Force
    Write-Ok "copied $file"
}

# ─── 3. Install config (never overwrite an existing user config) ───────────────

$null = New-Item -ItemType Directory -Path $CONFIG_DIR -Force

$configSrc = Join-Path $SCRIPT_DIR 'config.default.ps1'
if (Test-Path -LiteralPath $CONFIG_FILE) {
    Write-Skip "config ($CONFIG_FILE)"
} else {
    if (Test-Path -LiteralPath $configSrc) {
        Copy-Item -LiteralPath $configSrc -Destination $CONFIG_FILE -Force
        Write-Ok "config: $CONFIG_FILE"
    } else {
        Write-Warning "config.default.ps1 not found — skipping config install"
    }
}

# ─── 4. Patch $PROFILE to dot-source rm_wrapper.ps1 ──────────────────────────

Write-Host ''
Write-Host 'Patching PowerShell profile...'

$wrapperPath   = Join-Path $INSTALL_DIR 'rm_wrapper.ps1'
$sourceLine    = ". `"$wrapperPath`""
$markerComment = '# ai-trash: dot-source Remove-Item wrapper'
$profileBlock  = @"

$markerComment
$sourceLine
"@

# Ensure the profile file exists.
if (-not (Test-Path -LiteralPath $PROFILE)) {
    $profileDir = Split-Path $PROFILE -Parent
    $null = New-Item -ItemType Directory -Path $profileDir -Force
    $null = New-Item -ItemType File      -Path $PROFILE    -Force
    Write-Ok "created $PROFILE"
}

$profileContent = Get-Content -LiteralPath $PROFILE -Raw -ErrorAction SilentlyContinue
if ($null -eq $profileContent) { $profileContent = '' }

if ($profileContent -like "*$markerComment*") {
    Write-Skip 'profile already contains ai-trash dot-source line'
} else {
    Add-Content -LiteralPath $PROFILE -Value $profileBlock -Encoding UTF8
    Write-Ok "added dot-source line to $PROFILE"
}

# ─── 5. Register Task Scheduler task (every 6 hours) ─────────────────────────

Write-Host ''
Write-Host 'Registering scheduled cleanup task...'

$cleanupScript = Join-Path $INSTALL_DIR 'ai-trash-cleanup.ps1'

# Build the task action: run PowerShell with the cleanup script.
$psExe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source
if (-not $psExe) {
    # PowerShell 7+
    $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
}
if (-not $psExe) {
    $psExe = 'powershell.exe'
}

$taskAction = New-ScheduledTaskAction `
    -Execute $psExe `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$cleanupScript`""

# Trigger: every 6 hours, starting at next midnight.
$taskTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 6) -Once `
    -At (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(1)

$taskSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false

$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

try {
    $existingTask = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
        Write-Step "replaced existing task '$TASK_NAME'"
    }

    Register-ScheduledTask `
        -TaskName  $TASK_NAME `
        -Action    $taskAction `
        -Trigger   $taskTrigger `
        -Settings  $taskSettings `
        -Principal $taskPrincipal `
        -Description 'Purges ai-trash entries older than 30 days' `
        -Force | Out-Null

    Write-Ok "scheduled task '$TASK_NAME' registered (runs every 6 hours)"
} catch {
    Write-Warning "Could not register scheduled task: $_"
    Write-Warning "You can register it manually or run ai-trash-cleanup.ps1 on a schedule."
}

# ─── Done ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host 'Installation complete.'
Write-Host ''
Write-Host 'To activate in the current session without restarting:'
Write-Host "  . `"$wrapperPath`""
Write-Host ''
Write-Host 'To use the CLI:'
Write-Host "  & `"$(Join-Path $INSTALL_DIR 'ai-trash.ps1')`" list"
Write-Host ''
Write-Host "Edit config: $CONFIG_FILE"
Write-Host ''
