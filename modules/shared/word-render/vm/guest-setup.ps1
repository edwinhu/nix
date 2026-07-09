<#
  guest-setup.ps1 — makes a freshly-installed Win11 guest render-ready. It is run
  ONCE, unattended, by autounattend.xml's FirstLogonCommand (which searches the
  attached media for this file). It can also be re-run by hand in an elevated
  PowerShell.

  It performs, in order:
    1. virtio-net (NetKVM) driver install from the attached virtio-win CD, so the
       guest gets a working network. This is why networking is reproducible on a
       fresh install instead of depending on Windows Update: the driver is on the
       CD, and its Red Hat signing cert is imported into TrustedPublisher first
       (that import is what fixes the "publisher not trusted" pnputil failure).
    2. OpenSSH Server install + start + firewall open (once step 1 gives network,
       the OpenSSH Feature-on-Demand can be fetched if not already inbox).
    3. Authorize the host's SSH key (read from authorized_key.txt beside this
       script — NOT hardcoded, so the kit stays machine-agnostic).
    4. Create the render scratch dir and copy render_docx.ps1 into place.

  Word itself: install Microsoft 365 (winget install --id Microsoft.Office, or
  from portal.office.com). Activation is OPTIONAL for rendering — unactivated
  Word still opens read-only, recomputes fields, and ExportAsFixedFormat to PDF
  via COM. Sign into Word with an M365 account only if you want it licensed.
#>
$ErrorActionPreference = 'Continue'
$User = 'word'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function Log($m){ Write-Host "[guest-setup] $m" }

# --- 1. virtio-net (NetKVM) driver ---------------------------------------
try {
  $arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM') { 'ARM64' } else { 'amd64' }
  # Find the virtio-win CD (has a NetKVM tree) across all drives.
  $vio = Get-PSDrive -PSProvider FileSystem |
    Where-Object { Test-Path (Join-Path $_.Root "NetKVM\w11\$arch\netkvm.inf") } |
    Select-Object -First 1
  if ($vio) {
    $inf = Join-Path $vio.Root "NetKVM\w11\$arch\netkvm.inf"
    # Trust Red Hat's driver-signing cert so pnputil /install won't prompt/fail.
    $certDir = Join-Path $vio.Root 'cert'
    if (Test-Path $certDir) {
      Get-ChildItem $certDir -Filter *.cer -ErrorAction SilentlyContinue | ForEach-Object {
        certutil -addstore -f TrustedPublisher $_.FullName | Out-Null
        certutil -addstore -f Root            $_.FullName | Out-Null
      }
    }
    Log "installing NetKVM from $inf"
    pnputil /add-driver $inf /install | Out-Null
    Start-Sleep 8
  } else {
    Log 'virtio-win CD not found; skipping NetKVM (relying on Windows Update / existing driver)'
  }
} catch { Log "NetKVM step error: $_" }

# --- 2. OpenSSH Server ---------------------------------------------------
Log 'installing OpenSSH Server'
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue | Out-Null
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name sshd -ErrorAction SilentlyContinue
if (-not (Get-NetFirewallRule -Name sshd-any -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name sshd-any -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any |
    Out-Null
}
Get-NetConnectionProfile -ErrorAction SilentlyContinue |
  Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

# --- 3. Authorize host key ----------------------------------------------
$keyFile = Join-Path $here 'authorized_key.txt'
if (Test-Path $keyFile) {
  $key = (Get-Content $keyFile -Raw).Trim()
  # Admin accounts: Windows OpenSSH reads this file, not the per-user one.
  $adminKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
  New-Item -ItemType Directory -Force -Path (Split-Path $adminKeys) | Out-Null
  Set-Content -Path $adminKeys -Value $key -Encoding ascii
  icacls $adminKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
  # Also the per-user file, in case the account is standard.
  $userSsh = "C:\Users\$User\.ssh"
  New-Item -ItemType Directory -Force -Path $userSsh | Out-Null
  Set-Content -Path "$userSsh\authorized_keys" -Value $key -Encoding ascii
  icacls "$userSsh\authorized_keys" /inheritance:r /grant "${User}:F" /grant 'SYSTEM:F' | Out-Null
  Log 'host key authorized'
} else {
  Log "WARNING: authorized_key.txt not found beside script; SSH will be password-only"
}
Restart-Service -Name sshd -ErrorAction SilentlyContinue

# --- 4. Render dir + renderer -------------------------------------------
New-Item -ItemType Directory -Force -Path "C:\Users\$User\render" | Out-Null
$rd = Join-Path $here 'render_docx.ps1'
if (Test-Path $rd) { Copy-Item $rd "C:\Users\$User\render_docx.ps1" -Force }

Log 'done. Guest IPv4:'
(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -ne '127.0.0.1' }).IPAddress
