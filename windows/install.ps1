<#
.SYNOPSIS
  Give a Windows Hermes its own visible Chrome with a persistent profile and a
  DevTools (CDP) port, started in the user's interactive session at logon.

.DESCRIPTION
  On Windows the human's own desktop IS the desktop, so there is nothing to
  stream: no VNC, no Xpra, no RDP. What the agent needs is a Chrome it can drive
  exactly, with a profile that keeps logins, and a window the human can watch
  and take over.

  This script:
    * finds Chrome (or Edge as the fallback),
    * creates a persistent profile directory,
    * registers a Scheduled Task that starts the browser at logon, in the
      interactive session (a service in session 0 could not show a window),
    * starts it now and proves CDP answers.

  The debugging port listens on 127.0.0.1 only. Nothing is exposed to the LAN.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -CdpPort 9334 -ProfileDir 'D:\hermes\chrome-2'
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [int]$CdpPort = 9333,
    [string]$ProfileDir = '',
    [ValidateSet('auto', 'chrome', 'edge')]
    [string]$Browser = 'auto',
    [switch]$NoAutostart,
    [switch]$DryRun,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$TaskName = "HermesDesktopBrowser-$CdpPort"

function Say($m) { Write-Host "  $m" }
function Die($m) { Write-Error $m; exit 1 }

if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
    $ProfileDir = Join-Path $env:LOCALAPPDATA "hermes-desktop\browser-$CdpPort"
}

# ---------------------------------------------------------------- uninstall --
if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Say "removed scheduled task $TaskName"
    }
    else {
        Say "no scheduled task named $TaskName"
    }
    Say "profile kept at $ProfileDir (holds logins; delete it yourself if you mean to)"
    exit 0
}

# ------------------------------------------------------------ find browser --
function Find-Browser {
    $candidates = @()
    if ($Browser -eq 'auto' -or $Browser -eq 'chrome') {
        $candidates += (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
        if (${env:ProgramFiles(x86)}) {
            $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
        }
        $candidates += (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    }
    if ($Browser -eq 'auto' -or $Browser -eq 'edge') {
        if (${env:ProgramFiles(x86)}) {
            $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
        }
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

$exe = Find-Browser
if (-not $exe) {
    Die "No Chrome or Edge found. Install Google Chrome, or run with -Browser edge."
}

$leaf = Split-Path $exe -Leaf
if ($leaf -match 'chrome') { $browserName = 'chrome' } else { $browserName = 'edge' }

# The profile must persist: refuse anything under the temp directory.
$tempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$fullProfile = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')
if ($fullProfile.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Die "profile must persist across reboots - refusing a temp directory: $fullProfile"
}

$arguments = @(
    ('--user-data-dir="{0}"' -f $fullProfile),
    ('--remote-debugging-port={0}' -f $CdpPort),
    '--remote-allow-origins=*',
    '--no-first-run',
    '--no-default-browser-check',
    '--password-store=basic',
    '--start-maximized'
) -join ' '

Write-Host ''
Write-Host '== Hermes desktop browser (Windows) =='
Say "browser : $exe ($browserName)"
Say "profile : $fullProfile"
Say "CDP     : http://127.0.0.1:$CdpPort  (loopback only)"
Say "task    : $TaskName"

if ($DryRun) {
    Say '[dry-run] would create the profile directory'
    Say ('[dry-run] would register scheduled task at logon: ' + $exe + ' ' + $arguments)
    Say '[dry-run] would start it now and check /json/version'
    exit 0
}

New-Item -ItemType Directory -Force -Path $fullProfile | Out-Null
Say "created profile directory"

function Get-CdpVersion {
    try {
        return Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/version" -f $CdpPort) -TimeoutSec 5
    }
    catch { return $null }
}

$version = Get-CdpVersion
if (-not $version) {
    Start-Process -FilePath $exe -ArgumentList $arguments
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $version = Get-CdpVersion
        if ($version) { break }
    }
}

if (-not $version) {
    Die "started $browserName but CDP did not answer on 127.0.0.1:$CdpPort (profile locked by another browser?)"
}

if ($NoAutostart) {
    Say 'skipped the logon task (-NoAutostart)'
}
else {
    $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    # $env:USERDOMAIN is WORKGROUP on a machine that is not domain-joined, and
    # "WORKGROUP\user" does not resolve: Register-ScheduledTask then fails with
    # 0x80070534 (no mapping between account names and SIDs). The Windows
    # identity always resolves, whatever the machine's domain state.
    $principalUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $principalUser -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    }
    catch {
        Die ("could not register task {0} for {1}: {2}" -f $TaskName, $principalUser, $_.Exception.Message)
    }
    Say "registered logon task $TaskName for $principalUser (interactive session - a service could not show a window)"
}

Write-Host ''
Write-Host 'RESULT: browser is up and drivable.'
Say "version : $($version.Browser)"
Say "cdp     : $($version.webSocketDebuggerUrl)"
Say "profile : $fullProfile"
Write-Host ''
Write-Host ('Agent: connect with Playwright connect_over_cdp("http://127.0.0.1:{0}")' -f $CdpPort)
Write-Host 'Human: this is a normal window on the desktop; use it or take over any time.'
Write-Host 'Login once in that window and the profile keeps the session.'
