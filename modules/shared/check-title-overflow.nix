{
  writeShellApplication,
  python3,
  tinymist,
}:

# check-title-overflow — the Typst title/subtitle overflow linter, with an interpreter
# that has pymupdf.
#
# Same dependency argument as check-widows.nix, and verified the same way on this
# machine: `python3 -c "import fitz"` against the system interpreter raises
# ModuleNotFoundError, the script then exits 2, and a caller that reads only the finding
# count records that crash as "0 violations, clean".
#
# tinymist is a runtime input because the script compiles a .typ argument itself before
# reading the PDF back.
#
# The script is referenced at its repo path rather than vendored, for the reason
# check-widows.nix gives: a copy here would be a second home for a file vendor-parity.sh
# does not track.

writeShellApplication {
  name = "check-title-overflow";
  runtimeInputs = [
    (python3.withPackages (ps: [ ps.pymupdf ]))
    tinymist
  ];
  text = ''
    script="$HOME/projects/typst/scripts/check-title-overflow.py"
    if [ ! -f "$script" ]; then
      echo "check-title-overflow: $script not found (is ~/projects/typst checked out?)" >&2
      exit 2
    fi
    exec python3 "$script" "$@"
  '';
}
