#!/usr/bin/env bash
# cwd-independent wrapper for the aerc-mail-tty launcher pytest gate. /home/eh/nix/pytest.py
# is a cwd-shim (it shadows the missing host pytest only when cwd is the repo root and hands off
# to the nixpkgs pytest), so cd there before running. Used as a craft mechanicalCheck, which runs
# from an unpredictable cwd.
set -euo pipefail
cd /home/eh/nix
exec python3 -m pytest -q modules/linux/test_aerc_mail_tty.py
