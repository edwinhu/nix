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

Log 'done'
