# word-render — faithful docx → PDF via real Microsoft Word in a QEMU guest

Renders `.docx` to PDF through the **real Word engine** so fields
(`REF`/`NOTEREF`/`PAGEREF`/`TOC`/`TOF`/`TOA`) are recomputed faithfully — the one
thing LibreOffice and ONLYOFFICE x2t get wrong. Word runs in a QEMU Windows guest
and is driven over SSH, so the same host scripts work on:

- **Apple Silicon Mac** — Win11 **ARM64** guest (QEMU + HVF) — *verified end-to-end*.
- **x86_64 Linux** — Win11 **x64** guest (QEMU + KVM) — *same shape, unverified*.

Only the SSH target changes between machines.

## What Nix ships (`programs.wordRender`)

`programs.wordRender.enable = true` installs, per user:

- `qemu` + `swtpm` (and `xorriso` on Linux).
- `~/.local/share/word-render/render_docx.ps1` — guest-side COM renderer.
- `~/.local/share/word-render/word_render_remote.sh` — host transport.
- `~/.local/bin/word-render` — `word-render <docx> [out.pdf]`.
- `~/.local/share/word-render/vm/` — the provisioning kit: `provision.sh`,
  `start-winvm.sh`, `start-tpm.sh`, `typer.sh`, `guest-setup.ps1`,
  `autounattend.xml`.
- `~/.local/bin/word-render-provision` — one-time host setup for the guest.
- `WINVM_SSH` / `WINVM_DIR` / `WINVM_SCRIPT` shell defaults.

Options (set per host): `sshTarget` (default `word@winvm`), `guestDir`,
`guestScript`.

## Reproducing the guest on a new machine

The VM is a stateful artifact; Nix ships every script and pins the manual steps.
Two ways to stand it up:

### Tier A — rebuild from ISO (fully reproducible)

1. `nix run .#build-switch` (lands the kit above).
2. **Download the install media** (the one genuinely manual, licensing-gated step):
   - Win11 ARM64: <https://www.microsoft.com/software-download/windows11arm64> →
     "Windows 11 (multi-edition ISO for Arm64)", English → save as
     `~/.local/share/winvm/Win11_ARM64.iso`.
   - virtio drivers: `curl -L -o ~/.local/share/winvm/virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`
3. `word-render-provision` — generates `~/.ssh/id_winvm`, copies UEFI firmware,
   makes the 64 GB disk + TPM state, and builds `unattend.iso` (bundling
   `guest-setup.ps1` + `render_docx.ps1` + your SSH pubkey).
4. Add a `Host winvm` block to `~/.ssh/config` (see `vm/start-winvm.sh` header).
5. Boot the installer and drive the two headless prompts (below):
   ```bash
   cd ~/.local/share/winvm
   ~/.local/share/word-render/vm/start-tpm.sh &
   ~/.local/share/word-render/vm/start-winvm.sh --install
   ```
6. When SSH answers (`ssh winvm hostname`), install Word:
   `ssh winvm 'winget install --id Microsoft.Office -e --accept-package-agreements --accept-source-agreements'`
7. `word-render some.docx`.

The unattended install creates a local admin `word` (password `wordrender`,
auto-login), installs the **virtio-net NetKVM driver** + OpenSSH + authorizes
your key — all from `autounattend.xml` → `guest-setup.ps1`. No clicking through
Windows Setup.

### Tier B — clone the built VM (fast)

Copy `~/.local/share/winvm/winvm.qcow2` (the installed+configured guest, multi-GB)
to the new machine's `~/.local/share/winvm/`, run `word-render-provision` (for
firmware/key/ssh-config), and `start-winvm.sh`. Store the qcow2 on rjds/NAS, not
git.

## Manual boot-drive (headless install, two prompts)

QEMU is headless (VNC on `127.0.0.1:5900`, password `render123`); the monitor
socket takes scripted keystrokes via `typer.sh`. Two spots in a *fresh* install
need a nudge — everything else is unattended:

1. **"Press any key to boot from CD"** — the edk2 firmware drops to a UEFI shell
   instead of auto-booting the installer. From the shell, launch the installer:
   `typer.sh 'fs0:\efi\boot\bootaa64.efi'` then spam `sendkey spc` to catch the
   CD-boot prompt. (`fs0:` = the install CD; confirm with `map -r`.)
2. **After the file-copy reboot** it drops to the UEFI shell again. Add a
   persistent boot entry once so it auto-boots thereafter:
   `bcfg boot add 0 fs2:\efi\microsoft\boot\bootmgfw.efi winbootmgr`
   (`fs2:` = the NVMe EFI partition; confirm with `map -r`), then
   `fs2:\efi\microsoft\boot\bootmgfw.efi`.

Read the screen between steps with
`printf 'screendump %s/screen.ppm\n' "$VMDIR" | nc -U -w1 "$VMDIR/monitor.sock"`
then convert (`sips -s format png screen.ppm --out screen.png`).

## Things we learned (the non-obvious bits)

- **Unactivated Word still renders.** Word in reduced-functionality (unlicensed)
  mode opens read-only, recomputes fields, and `ExportAsFixedFormat` to PDF via
  COM. So M365 activation is **optional** — sign into Word only if you want it
  licensed (UVA M365: sign in at portal.office.com / in Word; account activation,
  no product key).
- **Networking = virtio-net + NetKVM, not usb-net.** usb-net (RNDIS, inbox
  driver) works on first boot but is flaky across reboots. virtio-net with the
  signed NetKVM driver (installed by `guest-setup.ps1` from the virtio-win CD,
  after importing Red Hat's cert into TrustedPublisher) is stable. The gotcha
  that bit us: the *stable* virtio ISO's ARM64 driver is Red-Hat-signed (not
  WHQL), so `pnputil /install` fails with "publisher not trusted" unless you
  import `virtio-win\cert\*.cer` first — which `guest-setup.ps1` now does.
- **NVMe system disk** avoids a "load driver" step during Setup (virtio-blk would
  need one); Win11 has an inbox NVMe driver.
- **No Secure Boot** in the plain edk2 firmware, so `autounattend.xml` sets the
  `LabConfig` `BypassSecureBootCheck` (+ TPM/RAM/CPU) keys.
- The guest transfer path is SSH/scp over the `localhost:2222` forward. (A FAT
  USB-image shuttle was tried as a no-network fallback and proved unreliable —
  Windows didn't flush removable-drive writes back to the image. Fix networking
  instead.)

## Downstream integration (separate repo)

`~/projects/workflows/scripts/doc_render.py` can grow a `renderer="word-remote"`
backend shelling out to `word_render_remote.sh`. That lives in the workflows
repo, not here — this module only provisions the VM + scripts.
