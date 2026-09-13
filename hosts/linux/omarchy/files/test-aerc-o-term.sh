#!/usr/bin/env bash
# Build aerc and the launcher package, then press `o` in a fixture aerc and
# assert terminal-browser is what appears underneath it. Exit code is pytest's.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/../../../.."
mkdir -p .craft/o-term-build

nix build '/home/eh/nix#homeConfigurations.eh.pkgs.aerc' \
  -o .craft/o-term-build/aerc
nix build '/home/eh/nix#homeConfigurations.eh.pkgs.aerc-html-terminal-browser' \
  -o .craft/o-term-build/launcher

echo "aerc:     $(readlink -f .craft/o-term-build/aerc)"
echo "launcher: $(readlink -f .craft/o-term-build/launcher)"
ls .craft/o-term-build/launcher/bin

export AERC_BIN="$PWD/.craft/o-term-build/aerc/bin/aerc"
export LAUNCHER_BIN="$PWD/.craft/o-term-build/launcher/bin"

exec python3 -m pytest -q hosts/linux/omarchy/files/test_aerc_o_term.py "$@"
