#!/usr/bin/env bash
# Firewall rules this host needs that home-manager cannot place itself: ufw is
# root-owned system state and this is Arch, not NixOS, so there is no
# networking.firewall option to declare them with.
#
# Idempotent. `--check` verifies without root by reading the world-readable
# /etc/ufw/user.rules, so drift is detectable from an ordinary shell (and from
# a user systemd unit).
#
#   ./ufw-rules.sh --check     # exit 1 and name what is missing
#   sudo ./ufw-rules.sh        # apply whatever is missing
set -uo pipefail

LAN=192.168.4.0/22

# port-spec | proto | comment  (allowed FROM the LAN subnet)
RULES=(
  "6002:6003|udp|owntone airplay"
)

# iface | port | proto | comment  (allowed IN on a specific interface, any source).
# SSH is opened on tailscale0 ONLY: reachable over the tailnet from anywhere, never
# exposed to the LAN or the internet.
IFACE_RULES=(
  "tailscale0|22|tcp|ssh over tailscale"
)

check() {
  local missing=0 rule spec
  for rule in "${RULES[@]}"; do
    IFS='|' read -r spec proto comment <<<"$rule"
    # user.rules writes a range as 6002:6003; a single port appears bare.
    if ! grep -qF -- "$spec" /etc/ufw/user.rules 2>/dev/null; then
      echo "MISSING: $spec/$proto from $LAN  ($comment)"
      missing=1
    fi
  done
  local iface port
  for rule in "${IFACE_RULES[@]}"; do
    IFS='|' read -r iface port proto comment <<<"$rule"
    # user.rules writes an interface rule as: -A ufw-user-input -i tailscale0 -p tcp --dport 22 ...
    if ! grep -qE -- "-i ${iface} -p ${proto} --dport ${port}\\b" /etc/ufw/user.rules 2>/dev/null; then
      echo "MISSING: ${port}/${proto} in on ${iface}  ($comment)"
      missing=1
    fi
  done
  return $missing
}

if [ "${1:-}" = "--check" ]; then
  check && echo "all firewall rules present"
  exit $?
fi

# --ensure: apply only what is missing, and only if sudo can be had WITHOUT a
# prompt. sudo here is passwordless only while the YubiKey is inserted
# (pam_yubico, mode=challenge-response, sufficient in /etc/pam.d/sudo), so this
# is best-effort by design: it heals silently when the key is in and says so
# plainly when it is not. It must never block on a password prompt — it runs
# unattended from a systemd unit with no terminal to type into.
if [ "${1:-}" = "--ensure" ]; then
  if check; then
    echo "all firewall rules present"
    exit 0
  fi
  if ! sudo -n true 2>/dev/null; then
    echo "firewall rules missing and sudo needs a password (YubiKey out?)." >&2
    echo "run: sudo $0" >&2
    exit 1
  fi
  exec sudo -n "$0"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "error: apply needs root — re-run with sudo (or pass --check)" >&2
  exit 2
fi

for rule in "${RULES[@]}"; do
  IFS='|' read -r spec proto comment <<<"$rule"
  # ufw itself is idempotent ("Skipping adding existing rule") but say so.
  echo "ufw allow from $LAN to any port $spec proto $proto"
  ufw allow from "$LAN" to any port "$spec" proto "$proto" comment "$comment"
done

for rule in "${IFACE_RULES[@]}"; do
  IFS='|' read -r iface port proto comment <<<"$rule"
  echo "ufw allow in on $iface to any port $port proto $proto"
  ufw allow in on "$iface" to any port "$port" proto "$proto" comment "$comment"
done
