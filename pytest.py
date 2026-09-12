"""Make `python3 -m pytest` work from this repo on a host python with no pytest.

Run with `-m` from the repo root, this file IS the module python finds, because
`-m` puts the cwd first on sys.path. Drop that entry and the real pytest -- built
from nixpkgs for this exact interpreter version -- imports normally.
"""

import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _HERE]


def _add_nix_pytest():
    tag = f"python{sys.version_info[0]}.{sys.version_info[1]}"
    out = subprocess.run(
        ["nix", "build", "--no-link", "--print-out-paths",
         "nixpkgs#python3Packages.pytest"],
        capture_output=True, text=True, check=True).stdout.split()[-1]
    closure = subprocess.run(["nix", "path-info", "-r", out],
                             capture_output=True, text=True,
                             check=True).stdout.split()
    for store in closure:
        site = os.path.join(store, "lib", tag, "site-packages")
        if os.path.isdir(site):
            sys.path.append(site)


try:
    import pytest
except ImportError:
    _add_nix_pytest()
    import pytest

sys.exit(pytest.main(sys.argv[1:]))
