#!/usr/bin/env bash
# start-winvm.sh — boot the Windows guest that renders docx via the real Word
# engine. Auto-detects platform:
#   * aarch64-darwin : Win11 ARM64 under QEMU + HVF (verified)
#   * x86_64-linux   : Win11 x64  under QEMU + KVM (same shape; UNVERIFIED)
#
# Usage:
#   ./start-tpm.sh &            # TPM 2.0 socket (leave running)
#   ./start-winvm.sh --install  # first boot: attach install + virtio + unattend ISOs
#   ./start-winvm.sh            # subsequent boots: from disk
#
# Display is headless VNC on 127.0.0.1:5900 (password: see VNC_PASSWORD below;
# connect with `open vnc://localhost:5900`). A QEMU monitor unix socket at
# $VMDIR/monitor.sock takes scripted `sendkey`/`screendump` (see typer.sh) — used
# to drive the one non-automatable install step (the UEFI "press any key to boot
# from CD" prompt) headlessly.
#
# Host->guest SSH is forwarded on localhost:2222 (add a `Host winvm` ssh block:
#   Host winvm
#     HostName localhost
#     Port 2222
#     User word
#     IdentityFile ~/.ssh/id_winvm
#     StrictHostKeyChecking accept-new
#     UserKnownHostsFile ~/.ssh/known_hosts_winvm
# ).
set -euo pipefail
VMDIR="${WINVM_DATA_DIR:-$HOME/.local/share/winvm}"
MODE="${1:-boot}"
VNC_PASSWORD="${WINVM_VNC_PASSWORD:-render123}"
MEM="${WINVM_MEM:-8192}"
CPUS="${WINVM_CPUS:-4}"

os="$(uname -s)"; arch="$(uname -m)"

common=(
  -name winvm
  -smp "$CPUS" -m "$MEM"
  -device qemu-xhci,id=usb
  -device usb-kbd -device usb-tablet
  # TPM 2.0 (Win11 requirement) via swtpm socket
  -chardev socket,id=chrtpm,path="$VMDIR/tpm/swtpm-sock"
  -tpmdev emulator,id=tpm0,chardev=chrtpm
  # System disk as NVMe: both Win11 ARM and x64 have an inbox NVMe driver, so
  # Setup sees the disk with NO "load driver" step (virtio-blk would need one).
  -drive if=none,id=sysdisk,format=qcow2,file="$VMDIR/winvm.qcow2"
  -device nvme,drive=sysdisk,serial=winvm001
  # Networking: virtio-net + the signed NetKVM driver (slipstreamed at install
  # time by autounattend.xml). user-mode NAT forwards host:2222 -> guest:22.
  -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56
  -netdev user,id=net0,hostfwd=tcp::2222-:22
  # Headless VNC, password-protected so macOS Screen Sharing will connect.
  -object secret,id=vncpw,data="$VNC_PASSWORD"
  -device ramfb
  -display none
  -vnc 127.0.0.1:0,password-secret=vncpw
  -monitor unix:"$VMDIR/monitor.sock",server,nowait
)

if [ "$os" = "Darwin" ] && [ "$arch" = "arm64" ]; then
  INSTALL_ISO="${WINVM_ISO:-$VMDIR/Win11_ARM64.iso}"
  plat=(
    -accel hvf
    -machine virt,gic-version=max,highmem=on
    -cpu host
    -device tpm-tis-device,tpmdev=tpm0
    -drive if=pflash,format=raw,readonly=on,file="$VMDIR/edk2-aarch64-code.fd"
    -drive if=pflash,format=raw,file="$VMDIR/edk2-arm-vars.fd"
  )
elif [ "$os" = "Linux" ] && [ "$arch" = "x86_64" ]; then
  # UNVERIFIED — mirrors the darwin path for a Win11 x64 + KVM guest.
  INSTALL_ISO="${WINVM_ISO:-$VMDIR/Win11_x64.iso}"
  plat=(
    -enable-kvm
    -machine q35,smm=on
    -cpu host
    -device tpm-tis,tpmdev=tpm0
    -global driver=cfi.pflash01,property=secure,value=on
    -drive if=pflash,format=raw,readonly=on,file="$VMDIR/OVMF_CODE.fd"
    -drive if=pflash,format=raw,file="$VMDIR/OVMF_VARS.fd"
  )
else
  echo "start-winvm.sh: unsupported platform $os/$arch" >&2; exit 1
fi

ARGS=("${plat[@]}" "${common[@]}")

if [ "$MODE" = "--install" ]; then
  ARGS+=(
    -boot menu=on
    -drive if=none,id=install,media=cdrom,file="$INSTALL_ISO"
    -device usb-storage,drive=install,bootindex=0
    -drive if=none,id=virtio,media=cdrom,file="$VMDIR/virtio-win.iso"
    -device usb-storage,drive=virtio
    -drive if=none,id=unattend,media=cdrom,file="$VMDIR/unattend.iso"
    -device usb-storage,drive=unattend
  )
fi

qemu="qemu-system-aarch64"
[ "$arch" = "x86_64" ] && qemu="qemu-system-x86_64"
exec "$qemu" "${ARGS[@]}"
