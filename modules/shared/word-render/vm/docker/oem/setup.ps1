<#
  setup.ps1 -- makes a fresh dockur/windows guest render-ready, unattended.

  The QEMU kit's guest-setup.ps1 does the same job in four steps; step 1 there
  is virtio driver installation, which dockur handles itself, so this is steps
  2-4 plus Word.

    1. OpenSSH Server: install, autostart, open the firewall.
    2. Authorize the host key from authorized_key.txt (written beside this file
       by word-render-docker-provision, so the kit stays machine-agnostic).
    3. Render scratch dir + render_docx.ps1 into place.
    4. Word, via the Office Deployment Tool. Activation is OPTIONAL: unactivated
       Word still opens read-only, recomputes fields, and ExportAsFixedFormat to
       PDF over COM -- which is all word-render asks of it.

  Re-runnable by hand in an elevated PowerShell if any step needs redoing.
#>
$ErrorActionPreference = 'Continue'
$User = 'word'
$here = 'C:\OEM'
function Log($m) { Write-Host "[setup] $m" }

# --- 1. OpenSSH Server ------------------------------------------------------
Log 'installing OpenSSH Server'
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# --- 2. Authorize the host's key -------------------------------------------
$keyFile = Join-Path $here 'authorized_key.txt'
if (Test-Path $keyFile) {
  Log 'authorizing host ssh key'
  $sshDir = "C:\Users\$User\.ssh"
  New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
  Get-Content $keyFile | Set-Content -Path "$sshDir\authorized_keys" -Encoding ascii

  # An administrator's keys are read from administrators_authorized_keys, NOT
  # from their profile -- and the file must not be writable by non-admins or
  # sshd silently refuses it.
  $admKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
  Get-Content $keyFile | Set-Content -Path $admKeys -Encoding ascii
  icacls $admKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
} else {
  Log 'WARNING: no authorized_key.txt found; ssh will be password-only'
}

# --- 3. Render scratch dir + script ----------------------------------------
Log 'placing render_docx.ps1'
New-Item -ItemType Directory -Force -Path "C:\Users\$User\render" | Out-Null
if (Test-Path (Join-Path $here 'render_docx.ps1')) {
  Copy-Item (Join-Path $here 'render_docx.ps1') "C:\Users\$User\render_docx.ps1" -Force
}

# --- 4. Word ----------------------------------------------------------------
# ODT is used rather than `winget install Microsoft.Office` because it takes a
# config XML: Word only, no Teams/OneDrive, no forced sign-in prompt.
Log 'installing Word via the Office Deployment Tool'
$odtDir = 'C:\OEM\odt'
New-Item -ItemType Directory -Force -Path $odtDir | Out-Null
try {
  $page = Invoke-WebRequest -Uri 'https://www.microsoft.com/en-us/download/details.aspx?id=49117' -UseBasicParsing
  $url = ($page.Links | Where-Object { $_.href -match 'officedeploymenttool.*\.exe$' } | Select-Object -First 1).href
  if (-not $url) { throw 'could not find the ODT download link' }
  Invoke-WebRequest -Uri $url -OutFile "$odtDir\odt.exe" -UseBasicParsing
  Start-Process -FilePath "$odtDir\odt.exe" -ArgumentList "/quiet /extract:$odtDir" -Wait
  Start-Process -FilePath "$odtDir\setup.exe" -ArgumentList "/configure $here\office-config.xml" -Wait
  Log 'Word install finished'
} catch {
  Log "Word install FAILED: $_"
  Log 'install by hand: winget install --id Microsoft.Office, or portal.office.com'
}

# --- 5. Turn off the consumer surface ---------------------------------------
# Nobody looks at this desktop. Everything here is either background CPU that
# competes with a render, or something that can reboot the box mid-job.
Log 'disabling background services'
# WSearch indexes the filesystem continuously; SysMain prefetches for
# interactive use; DiagTrack is telemetry; the Xbox stack has no purpose here.
foreach ($svc in 'WSearch','SysMain','DiagTrack','dmwappushservice','XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','MapsBroker','RetailDemo','WalletService') {
  $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
  if ($s) { Stop-Service $svc -Force -ErrorAction SilentlyContinue; Set-Service $svc -StartupType Disabled -ErrorAction SilentlyContinue }
}

Log 'blocking silently-installed consumer apps'
$cdm = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
New-Item -Path $cdm -Force | Out-Null
Set-ItemProperty $cdm -Name 'DisableWindowsConsumerFeatures' -Value 1 -Type DWord
Set-ItemProperty $cdm -Name 'DisableCloudOptimizedContent' -Value 1 -Type DWord

Log 'removing inbox store apps'
# Keep nothing: no Store app is reachable over ssh. Failures are expected for
# packages Windows refuses to remove, hence SilentlyContinue.
Get-AppxPackage -AllUsers |
  Where-Object { $_.Name -notmatch 'VCLibs|NET\.Native|UI\.Xaml|WindowsStore' } |
  Remove-AppxPackage -ErrorAction SilentlyContinue
Get-AppxProvisionedPackage -Online |
  Where-Object { $_.DisplayName -notmatch 'VCLibs|NET\.Native|UI\.Xaml|WindowsStore' } |
  Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null

Log 'disabling telemetry'
$dc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
New-Item -Path $dc -Force | Out-Null
Set-ItemProperty $dc -Name 'AllowTelemetry' -Value 0 -Type DWord

Log 'stopping Windows Update from rebooting mid-render'
# Not disabled outright -- set to manual, so `usoclient StartScan` still works
# when you deliberately want patches, but nothing reboots on its own.
Set-Service wuauserv -StartupType Manual -ErrorAction SilentlyContinue
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
Set-ItemProperty $au -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord
Set-ItemProperty $au -Name 'AUOptions' -Value 2 -Type DWord

Log 'excluding the render dir from Defender'
# Real-time scanning of every docx/pdf write adds latency to each render.
# An exclusion is used rather than disabling Defender: Tamper Protection
# blocks the registry kill-switch anyway, so it would fail silently.
Add-MpPreference -ExclusionPath "C:\Users\$User\render" -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionProcess 'WINWORD.EXE' -ErrorAction SilentlyContinue

Log 'disabling scheduled maintenance'
foreach ($t in '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
               '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
               '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
               '\Microsoft\Windows\Feedback\Siuf\DmClient') {
  Disable-ScheduledTask -TaskPath (Split-Path $t) -TaskName (Split-Path $t -Leaf) -ErrorAction SilentlyContinue | Out-Null
}

# --- 6. Slim the guest -------------------------------------------------------
# On a 16 GB VM the big consumers are not Windows itself: hiberfil.sys is
# RAM-sized, and the pagefile grows to match. A container guest never
# hibernates and only ever runs Word behind ssh, so both are dead weight.
Log 'slimming: hibernation off'
powercfg /h off 2>&1 | Out-Null

Log 'slimming: fixed 2 GB pagefile'
$cs = Get-WmiObject Win32_ComputerSystem
if ($cs.AutomaticManagedPagefile) {
  $cs.AutomaticManagedPagefile = $false
  $cs.Put() | Out-Null
}
$pf = Get-WmiObject -Query "SELECT * FROM Win32_PageFileSetting WHERE Name='C:\\\\pagefile.sys'"
if ($pf) { $pf.InitialSize = 2048; $pf.MaximumSize = 2048; $pf.Put() | Out-Null }

Log 'slimming: System Restore off'
Disable-ComputerRestore -Drive 'C:\' 2>&1 | Out-Null

Log 'slimming: CompactOS'
compact /compactos:always 2>&1 | Select-Object -Last 2 | ForEach-Object { Log $_ }

# Runs last: after Word is installed, so superseded components from both the
# OS install and the Office install are collapsed in one pass.
Log 'slimming: component store cleanup (slow)'
Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet 2>&1 | Out-Null

$free = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
$used = [math]::Round((Get-PSDrive C).Used / 1GB, 1)
Log "disk after slimming: ${used} GB used, ${free} GB free"

Log 'done'
