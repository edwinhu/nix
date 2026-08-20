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

# port-spec | proto | comment
RULES=(
  "6002:6003|udp|owntone airplay"
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
  return $missing
}

if [ "${1:-}" = "--check" ]; then
  check && echo "all firewall rules present"
  exit $?
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
