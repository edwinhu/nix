# install-guest-fonts.ps1 — install the Windows-compatible Latin Modern set
# into the Word guest.  Run inside the guest (see install-guest-fonts.sh, which
# scp's the payload and invokes this).
#
# Idempotent: purges any earlier Latin Modern registration (including the
# CFF/OTF attempts that Word silently refuses to render) before installing.
$ErrorActionPreference = 'Continue'

$src = 'C:\Users\word\lm-winfonts'
$reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

# Word holds font files open; it must not be running while we replace them.
Get-Process WINWORD -ErrorAction SilentlyContinue | Stop-Process -Force

# Purge every prior Latin Modern install. Matching on the FILE name (the
# registry value) rather than the display name catches the stock lmodern
# filenames as well as our own.
$purged = 0
foreach ($p in (Get-ItemProperty -Path $reg).PSObject.Properties) {
  if ($p.Value -is [string] -and
      ($p.Value -like 'lm*.otf' -or $p.Value -like 'lm*.ttf' -or
       $p.Value -like 'latinmodern-math.*')) {
    Remove-ItemProperty -Path $reg -Name $p.Name -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\Fonts\$($p.Value)" -Force -ErrorAction SilentlyContinue
    $purged++
  }
}
Write-Host "purged=$purged"

if (-not (Test-Path "$src\lm-winfonts.tgz")) { throw "payload missing: $src\lm-winfonts.tgz" }
Set-Location $src
tar -xzf lm-winfonts.tgz

# Registry display names. The "(TrueType)" suffix is required — these are
# glyf-flavoured after conversion, and Windows keys the flavour off this.
$names = @{
  'lmroman10-regular.ttf'    = 'Latin Modern Roman (TrueType)';
  'lmroman10-bold.ttf'       = 'Latin Modern Roman Bold (TrueType)';
  'lmroman10-italic.ttf'     = 'Latin Modern Roman Italic (TrueType)';
  'lmroman10-bolditalic.ttf' = 'Latin Modern Roman Bold Italic (TrueType)';
  'lmmono10-regular.ttf'     = 'Latin Modern Mono (TrueType)';
  'lmmono10-italic.ttf'      = 'Latin Modern Mono Italic (TrueType)';
  'latinmodern-math.ttf'     = 'Latin Modern Math (TrueType)';
}

$n = 0
foreach ($f in Get-ChildItem "$src\*.ttf") {
  $display = $names[$f.Name]
  if (-not $display) { $display = "$($f.BaseName) (TrueType)" }
  Copy-Item $f.FullName "C:\Windows\Fonts\$($f.Name)" -Force
  New-ItemProperty -Path $reg -Name $display -Value $f.Name -PropertyType String -Force | Out-Null
  $n++
}
Write-Host "installed=$n"
