#!/usr/bin/env bash
# provision.sh — one-time host provisioning for the Windows render guest. Lays
# out the mutable VM data dir ($HOME/.local/share/winvm), copies firmware, makes
# the disk + TPM state, generates the host SSH key, and builds the unattend ISO
# (bundling guest-setup.ps1 + render_docx.ps1 + your SSH pubkey). It does NOT
# download Windows (licensing/interactive) — see the printed instructions.
#
# After this: download the install ISO, then boot the installer:
#   ./start-tpm.sh &
#   ./start-winvm.sh --install
# and drive the two headless prompts per README ("Manual boot-drive" section).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMDIR="${WINVM_DATA_DIR:-$HOME/.local/share/winvm}"
mkdir -p "$VMDIR"
os="$(uname -s)"; arch="$(uname -m)"

echo "==> VM data dir: $VMDIR"

# --- host SSH key (authorizes us into the guest) -------------------------
if [ ! -f "$HOME/.ssh/id_winvm" ]; then
  echo "==> generating ~/.ssh/id_winvm"
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_winvm" -N "" -C "word-render host key for winvm guest"
fi

# --- firmware (UEFI) -----------------------------------------------------
qbin="$(command -v qemu-system-aarch64 || command -v qemu-system-x86_64)"
qshare="$(dirname "$(dirname "$(readlink -f "$qbin")")")/share/qemu"
if [ "$os" = "Darwin" ] && [ "$arch" = "arm64" ]; then
  cp -n "$qshare/edk2-aarch64-code.fd" "$VMDIR/edk2-aarch64-code.fd"
  [ -f "$VMDIR/edk2-arm-vars.fd" ] || cp "$qshare/edk2-arm-vars.fd" "$VMDIR/edk2-arm-vars.fd"
  chmod u+w "$VMDIR/edk2-arm-vars.fd"
  ISO_NAME="Win11_ARM64.iso"
elif [ "$os" = "Linux" ] && [ "$arch" = "x86_64" ]; then
  # UNVERIFIED path. OVMF filenames vary by distro; adjust if needed.
  for c in OVMF_CODE.fd edk2-x86_64-code.fd; do [ -f "$qshare/$c" ] && cp -n "$qshare/$c" "$VMDIR/OVMF_CODE.fd" && break; done
  for v in OVMF_VARS.fd edk2-i386-vars.fd;  do [ -f "$qshare/$v" ] && cp -n "$qshare/$v" "$VMDIR/OVMF_VARS.fd" && break; done
  ISO_NAME="Win11_x64.iso"
else
  echo "provision.sh: unsupported platform $os/$arch" >&2; exit 1
fi

# --- disk ----------------------------------------------------------------
[ -f "$VMDIR/winvm.qcow2" ] || qemu-img create -f qcow2 "$VMDIR/winvm.qcow2" 64G

# --- build unattend ISO --------------------------------------------------
stage="$(mktemp -d)"
cp "$here/autounattend.xml" "$stage/autounattend.xml"
cp "$here/guest-setup.ps1"  "$stage/guest-setup.ps1"
# render_docx.ps1 lives one dir up in the repo, or at the nix-deployed path.
if   [ -f "$here/../render_docx.ps1" ]; then cp "$here/../render_docx.ps1" "$stage/render_docx.ps1"
elif [ -f "$HOME/.local/share/word-render/render_docx.ps1" ]; then cp "$HOME/.local/share/word-render/render_docx.ps1" "$stage/render_docx.ps1"
fi
cp "$HOME/.ssh/id_winvm.pub" "$stage/authorized_key.txt"

rm -f "$VMDIR/unattend.iso"
if [ "$os" = "Darwin" ]; then
  hdiutil makehybrid -iso -joliet -default-volume-name UNATTEND -o "$VMDIR/unattend.iso" "$stage" >/dev/null
else
  xorriso -as mkisofs -J -V UNATTEND -o "$VMDIR/unattend.iso" "$stage" >/dev/null 2>&1 \
    || genisoimage -J -V UNATTEND -o "$VMDIR/unattend.iso" "$stage"
fi
rm -rf "$stage"
echo "==> built $VMDIR/unattend.iso (autounattend + guest-setup + render_docx + host key)"

# --- required ISOs -------------------------------------------------------
[ -f "$VMDIR/virtio-win.iso" ] || echo "!! MISSING: $VMDIR/virtio-win.iso — get https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
if [ ! -f "$VMDIR/$ISO_NAME" ]; then
  echo "!! MISSING: $VMDIR/$ISO_NAME"
  if [ "$arch" = "arm64" ]; then
    echo "   Get the Win11 ARM64 ISO from https://www.microsoft.com/software-download/windows11arm64 (select multi-edition Arm64, English), save as $VMDIR/$ISO_NAME"
  else
    echo "   Get the Win11 x64 ISO from https://www.microsoft.com/software-download/windows11, save as $VMDIR/$ISO_NAME"
  fi
fi

cat <<EOF

==> Provisioning done. Next:
    1. Ensure $ISO_NAME and virtio-win.iso are in $VMDIR (see any '!! MISSING' above).
    2. Add a 'Host winvm' block to ~/.ssh/config (see start-winvm.sh header).
    3. Boot the installer:
         $here/start-tpm.sh &
         $here/start-winvm.sh --install
       then drive the two headless prompts (README "Manual boot-drive").
    4. Install Word in the guest once online: ssh winvm 'winget install --id Microsoft.Office -e --accept-package-agreements --accept-source-agreements'
    5. Test:  word-render some.docx
EOF
