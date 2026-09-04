#!/usr/bin/env bash
# Does the vaxis kitty-graphics patch actually apply, build, and evaluate?
#
# This is the red gate for the nix wiring task, and it exists because that
# wiring fails SILENTLY. A `go mod edit -replace` onto a patch that no longer
# applies still produces an aerc that builds and runs -- it just renders no
# images, which is the exact defect the patch was written to fix. The same trap
# is why modules/linux/aerc-pty-pixels.nix carries a postPatch grep.
#
# Checks, in order, each fatal:
#   1. the patch exists and applies cleanly to a FRESH v0.17.1 checkout
#      (not to the working tree, which already has the changes)
#   2. the patched tree still compiles
#   3. the patched tree decodes kitty APC rather than only posting an event
#   4. the nix module exists and the flake still evaluates with it
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH="$REPO/modules/linux/aerc-vaxis-kitty.patch"
MODULE="$REPO/modules/linux/aerc-vaxis-kitty.nix"
BASE_REF="v0.17.1"

# Report in go test's shape. This is a test as far as the harness is concerned,
# and a probe that cannot recognise the output treats a real failure as a
# broken runner instead of a red bar.
fail() {
  echo "=== RUN   TestKittyPatchApplies"
  echo "    kitty-patch-gate.sh: $*"
  echo "--- FAIL: TestKittyPatchApplies (0.00s)"
  echo "FAIL"
  echo "FAIL	modules/linux/kitty-patch-gate.sh"
  exit 1
}

[ -f "$PATCH" ]  || fail "no patch at modules/linux/aerc-vaxis-kitty.patch"
[ -s "$PATCH" ]  || fail "the patch is empty"
[ -f "$MODULE" ] || fail "no module at modules/linux/aerc-vaxis-kitty.nix"

# A fresh checkout, so this proves the patch applies to what nix will fetch
# rather than to the tree it was developed in.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SEED="$REPO/.vaxis-kitty"
if [ -d "$SEED/.git" ]; then
  git clone --quiet --shared --no-checkout "$SEED" "$WORK/vaxis" 2>/dev/null \
    || fail "could not clone the local vaxis seed"
  git -C "$WORK/vaxis" checkout --quiet "$BASE_REF" 2>/dev/null \
    || fail "the seed has no $BASE_REF to check out"
else
  git clone --quiet --depth 1 --branch "$BASE_REF" \
    https://github.com/rockorager/vaxis "$WORK/vaxis" 2>/dev/null \
    || fail "could not obtain a clean vaxis $BASE_REF"
fi

git -C "$WORK/vaxis" apply --check "$PATCH" 2>/dev/null \
  || fail "the patch does not apply cleanly to a fresh $BASE_REF checkout"
git -C "$WORK/vaxis" apply "$PATCH" 2>/dev/null \
  || fail "the patch failed to apply"

( cd "$WORK/vaxis" && go build ./... ) >/dev/null 2>&1 \
  || fail "the patched vaxis does not build"

# The patch is the artefact that SHIPS, so judge it by behaviour and not by its
# diff. The suite is deliberately not in the patch -- tests are not vaxis's to
# carry -- so copy it into the patched tree and run it there. A patch that
# builds but fails these is a patch that renders nothing, or one that hands a
# child an unbounded allocation.
for suite in kitty_test.go kitty_hardening_test.go kitty_confine_test.go; do
  [ -f "$REPO/.vaxis-kitty/widgets/term/$suite" ] \
    || fail "missing red suite $suite -- cannot judge the patched tree"
  cp "$REPO/.vaxis-kitty/widgets/term/$suite" "$WORK/vaxis/widgets/term/$suite"
done
( cd "$WORK/vaxis" && go test ./widgets/term -run TestKitty -count=1 ) >"$WORK/test.log" 2>&1 \
  || fail "the patched vaxis fails its kitty suite: $(grep -m1 -E '_test\.go:[0-9]+:' "$WORK/test.log" | sed 's/^[[:space:]]*//')"

# The behaviour, not just the diff: the APC arm must do more than post an event.
APC_ARM="$WORK/vaxis/widgets/term/action.go"
grep -q 'case ansi.APC' "$APC_ARM" \
  || fail "the patched action.go has no APC arm at all"
if ! grep -rq 'kitty' "$WORK/vaxis/widgets/term/kitty.go" 2>/dev/null; then
  fail "the patched tree has no widgets/term/kitty.go -- the decoder is missing"
fi

# And the nix side has to evaluate, or the patch is wired to nothing.
( cd "$REPO" && nix-instantiate --parse "$MODULE" ) >/dev/null 2>&1 \
  || fail "modules/linux/aerc-vaxis-kitty.nix does not parse"
( cd "$REPO" && nix-instantiate --parse flake.nix ) >/dev/null 2>&1 \
  || fail "flake.nix does not parse"
grep -q 'aerc-vaxis-kitty' "$REPO/flake.nix" \
  || fail "flake.nix does not reference aerc-vaxis-kitty.nix, so the patch is not wired in"

# The consuming half. Decoding kitty graphics is only worth having if something
# in this repo actually sends them: without a terminal-browser filter the whole
# change is a library improvement nobody's mail benefits from, which is what the
# criteria lens flagged. Require the filter to exist and to name the browser.
TB_FILTER="$REPO/modules/linux/aerc-html-terminal-browser.nix"
[ -f "$TB_FILTER" ] \
  || fail "no modules/linux/aerc-html-terminal-browser.nix -- nothing in the repo sends kitty graphics, so the decoder has no consumer"
grep -q 'terminal-browser' "$TB_FILTER" \
  || fail "the html filter module never mentions terminal-browser"
( cd "$REPO" && nix-instantiate --parse "$TB_FILTER" ) >/dev/null 2>&1 \
  || fail "modules/linux/aerc-html-terminal-browser.nix does not parse"

echo "=== RUN   TestKittyPatchApplies"
echo "    patch applies to a fresh $BASE_REF, builds, carries the decoder, nix wiring evaluates"
echo "--- PASS: TestKittyPatchApplies (0.00s)"
echo "PASS"
echo "ok  	modules/linux/kitty-patch-gate.sh"
