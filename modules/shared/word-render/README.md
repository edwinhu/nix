# word-render — faithful docx → PDF via real Microsoft Word in a QEMU guest

Renders `.docx` to PDF through the **real Word engine** so that fields
(`REF`/`NOTEREF`/`PAGEREF`/`TOC`/`TOF`/`TOA`) are recomputed faithfully — the one
thing LibreOffice and ONLYOFFICE x2t get wrong. Word runs inside a QEMU Windows
guest and is driven over SSH, so the exact same host scripts work on:

- **this Apple Silicon Mac now** — Win11 **ARM** guest (QEMU + HVF), and
- **a future x86_64 Linux desktop** — Win11 **x64** guest (QEMU + KVM).

Only the SSH target changes between environments.

## What Nix manages (the `programs.wordRender` module)

Enabling `programs.wordRender.enable = true` installs, per user:

- `qemu` (the hypervisor).
- `~/.local/share/word-render/render_docx.ps1` — the **guest-side** COM renderer.
- `~/.local/share/word-render/word_render_remote.sh` — the **host-side** transport.
- `~/.local/bin/word-render` — launcher: `word-render <docx> [out.pdf]`.
- `WINVM_SSH` / `WINVM_DIR` / `WINVM_SCRIPT` shell defaults.

Options (set per host — e.g. in `modules/darwin/home-manager.nix`):

| Option                        | Default                          | Notes |
|-------------------------------|----------------------------------|-------|
| `programs.wordRender.sshTarget`  | `word@winvm`                  | The **only** value that differs per machine. |
| `programs.wordRender.guestDir`   | `C:/Users/word/render`        | Scratch dir inside the guest. |
| `programs.wordRender.guestScript`| `C:/Users/word/render_docx.ps1` | Where `render_docx.ps1` lives in the guest. |

Keep `sshTarget` as `word@winvm` and add a `Host winvm` block to `~/.ssh/config`
pointing at the guest's address on each machine — then nothing but that one SSH
alias differs Mac↔Linux. (Or override `sshTarget` directly per host.)

## Usage

```bash
word-render draft.docx              # -> draft.pdf
word-render draft.docx out/foo.pdf  # explicit output
# one-off override without rebuilding:
WINVM_SSH=word@10.0.0.9 word-render draft.docx
```

## One-time manual setup (Nix cannot automate these)

Nix provisions the host, but the Windows guest — ISO download, Office licensing,
OpenSSH — is manual. Do this once per machine.

### 1. Create the Win11 guest in QEMU

- **Mac (Apple Silicon):** install **Windows 11 ARM64**. Get the ISO from
  Microsoft (Windows Insider Preview ARM64 VHDX/ISO) or use UTM/Parallels to
  create the VM — QEMU with `-accel hvf -machine virt` also works. Give it
  ≥ 4 vCPU / 8 GB RAM / 64 GB disk. Install the VirtIO / SPICE guest tools.
- **Linux (x86_64):** install **Windows 11 x64**. Boot the QEMU VM with
  `-enable-kvm -cpu host`; add a TPM (`swtpm`) and UEFI (OVMF) since Win11
  requires them. Same resource sizing.

Give the guest a stable address (static IP or a host-only/NAT alias) and add a
`Host winvm` entry to `~/.ssh/config` on the host so `word@winvm` resolves.

> This module intentionally does **not** ship a VM image or ISO — licensing and
> download are manual and machine-specific. Nix only manages the host tooling.

### 2. Install & license Microsoft Word inside the guest

1. In the guest, sign in at **https://portal.office.com** with the **UVA M365**
   credentials. This both **licenses and activates** Office for that account.
2. Install the Microsoft 365 / Office desktop apps from the portal ("Install
   Office"). Word must be the desktop app — the COM automation in
   `render_docx.ps1` needs the full engine, not the web app.
3. Launch Word once and complete first-run (accept EULA, sign in) so COM
   automation isn't blocked by first-run dialogs.

### 3. Enable OpenSSH Server in the guest

In an **elevated PowerShell** inside the guest:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
# allow inbound SSH
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

Create the `word` user (or reuse your account) and authorize the host's public
key. Windows OpenSSH reads authorized keys from `C:\Users\word\.ssh\authorized_keys`
for normal users:

```powershell
$sshDir = "C:\Users\word\.ssh"
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
# paste the HOST's public key (e.g. contents of ~/.ssh/id_ed25519.pub) into:
notepad "$sshDir\authorized_keys"
icacls "$sshDir\authorized_keys" /inheritance:r /grant "word:F" /grant "SYSTEM:F"
```

Verify from the host: `ssh word@winvm` should log in without a password.

### 4. Drop `render_docx.ps1` into the guest

Copy the guest-side renderer to the path in `guestScript` (default
`C:/Users/word/render_docx.ps1`) and create the scratch dir:

```bash
ssh word@winvm "powershell -Command New-Item -ItemType Directory -Force -Path C:/Users/word/render"
scp ~/.local/share/word-render/render_docx.ps1 word@winvm:C:/Users/word/render_docx.ps1
```

### 5. Smoke test

```bash
word-render some.docx
# -> writes some.pdf next to it
```

## Downstream integration (not part of this repo)

The high-fidelity renderer `~/projects/workflows/scripts/doc_render.py` will grow a
`renderer="word-remote"` backend that shells out to `word_render_remote.sh`. That
change lives in the workflows repo, not here — this module only provisions the VM
tooling and scripts.
