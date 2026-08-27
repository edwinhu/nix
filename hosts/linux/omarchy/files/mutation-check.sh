#!/usr/bin/env bash
# Does the suite actually pin the reaper's RUNTIME behaviour?
#
# Each mutation below is a plausible one-line regression that would send SIGTERM
# to a live preview server. A suite that stays green under one of them is not
# testing that behaviour. Every mutation must make pytest FAIL.
#
# Runs against a throwaway copy, so the working tree is never touched.
# test_nix_wires_the_renamed_reaper is deselected: it reads ../default.nix,
# which does not exist beside the copy, so it fails under EVERY mutation and
# would report a green suite as caught.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST=${PYTEST:-pytest}
SKIP=test_nix_wires_the_renamed_reaper

summary() {  # last pytest tally line from the run in $1
  grep -Eo '[0-9]+ (passed|failed)(, [0-9]+ (passed|failed))*' "$1/out" | tail -1
}

run_suite() {  # $1 = dir holding the copies
  "$PYTEST" -q -p no:cacheprovider -k "not $SKIP" \
    "$1/test_preview_reap.py" >"$1/out" 2>&1
}

# name | sed program applied to the copied preview-reap.py
#
# tinymist's `parent is not None` guard is deliberately absent: an unreadable
# parent cannot be staged from a test without a hidepid mount, so pinning it
# would be a gate no faithful test can close. The guard stays in the code.
MUTATIONS=(
  "drop-cpu-conjunct|s/ and cpu_unchanged(proc, ctx)$//"
  "missing-log-means-idle|/if mtime is None:/{n;s/return False/return True/}"
  "tinymist-match-drops-preview|s/and \"preview\" in p\[\"args\"\]/and True/"
  "tinymist-orphan-never-fires|s/return \"orphan (editor gone)\"/return None/"
  "tinymist-drops-has-client|s/not has_client(proc\[\"pid\"\], ctx\[\"estab\"\]) and //"
  "tinymist-idle-drops-cpu|/def _tinymist_idle/{n;s/ and cpu_unchanged(proc, ctx)//}"
  "tinymist-parent-guard-dropped|s/parent is not None and parent != \"nvim\"/parent != \"nvim\"/"
  "state-key-ignores-starttime|s/f\"{p\['pid'\]}:{p\['start'\]}\"/str(p[\"pid\"])/"
  "hold-strikes-instead-of-resetting|s/if (idle and prev) else 0/if (idle and prev) else (prev[\"strikes\"] if prev else 0)/"
)

# Baseline: an UNMUTATED copy must be green, or every "caught" below is noise.
base=$(mktemp -d)
cp "$HERE/preview-reap.py" "$HERE/test_preview_reap.py" "$base/"
if ! run_suite "$base"; then
  echo "ERROR  the unmutated copy does not pass — mutation results would be meaningless" >&2
  cat "$base/out" >&2
  rm -rf "$base"
  exit 2
fi
rm -rf "$base"

survived=()
for entry in "${MUTATIONS[@]}"; do
  name=${entry%%|*}
  prog=${entry#*|}
  work=$(mktemp -d)
  cp "$HERE/preview-reap.py" "$HERE/test_preview_reap.py" "$work/"
  before=$(md5sum < "$work/preview-reap.py")
  sed -i "$prog" "$work/preview-reap.py"
  if [ "$before" = "$(md5sum < "$work/preview-reap.py")" ]; then
    echo "ERROR  $name — mutation matched nothing; the sed program is stale" >&2
    survived+=("$name (inapplicable)")
    rm -rf "$work"
    continue
  fi
  if run_suite "$work"; then
    echo "SURVIVED  $name — $(summary "$work"), suite still green with this regression applied"
    survived+=("$name")
  else
    echo "caught    $name — $(summary "$work")"
  fi
  rm -rf "$work"
done

if [ ${#survived[@]} -ne 0 ]; then
  echo
  echo "${#survived[@]} of ${#MUTATIONS[@]} mutation(s) survived: ${survived[*]}"
  exit 1
fi
echo
echo "all ${#MUTATIONS[@]} mutations caught"
