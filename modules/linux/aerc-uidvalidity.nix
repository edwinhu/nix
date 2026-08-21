# aerc, with the upstream CheckMail UIDVALIDITY fix backported onto 0.21.0.
#
# THE BUG. worker/imap/checkmail.go asks the server for MESSAGES, RECENT,
# UNSEEN and UIDNEXT -- not UIDVALIDITY -- and then, for the mailbox that is
# currently open, does `w.selected = status`. The replacement MailboxStatus
# therefore carries UidValidity == 0, throwing away what SELECT returned.
# worker/imap/cache.go keys every cached header as
#
#     header.<mailbox>.<w.selected.UidValidity>.<uid>
#
# so from the first CheckMail onward the mailbox is cached under
# `header.<mailbox>.0.<uid>`. Observed directly: a fresh isolated cache
# against archive 1143 wrote `header.Focused.0.<uid>` while SELECT Focused
# returned 57404435 and go-imap v1.2.1 parsed that 57404435 correctly. The
# namespace then stops changing when the server invalidates UIDs -- the exact
# condition UIDVALIDITY exists to detect -- and anything written before the
# first CheckMail is orphaned.
#
# WHY A PACKAGE OVERRIDE. checkmail.go:73 is the ONLY site in 0.21.0 that
# replaces w.selected from a STATUS response (open.go:27 assigns from SELECT,
# which carries UIDVALIDITY; worker.go:393 resets to an empty struct). The
# other STATUS caller, list.go:72, only posts directory counts and never
# touches w.selected, so it does not need the item. One line in one file fixes
# it, which is narrower than any lock bump -- and a bump would not help anyway:
# the fix is on aerc master, unreleased, so no nixpkgs rev carries it.
#
# WHAT IS BACKPORTED. Only the items-slice half of upstream's change. Master
# also exposes the value as models.DirectoryInfo.Uid; that field does not
# exist in 0.21.0, is a separate feature, and is unrelated to the cache key.
#
# THE GATE. buildGoModule's checkPhase runs `go test` over every directory
# holding a *_test.go, so the second patch -- a loopback fake-IMAP regression
# test -- is executed by the ordinary build and fails it if the fix is absent.
# postPatch adds a source-level assertion for the same reason at lower cost,
# and passthru.uidValidityBackport lets a consumer assert at EVAL time that it
# got the patched package rather than stock nixpkgs aerc.
{ aerc }:

aerc.overrideAttrs (prev: {
  patches = (prev.patches or [ ]) ++ [
    ./aerc-checkmail-uidvalidity.patch
    ./aerc-checkmail-uidvalidity-test.patch
  ];

  # Neither patch touches go.mod/go.sum and the test adds no import beyond
  # what worker/imap already requires, so vendorHash is unchanged.

  postPatch = (prev.postPatch or "") + ''
    # Decidable proof the backport landed, independent of `patch` exit codes:
    # every STATUS items list that can replace w.selected must name
    # UIDVALIDITY. Cheap enough to run on every build.
    grep -q 'imap.StatusUidValidity' worker/imap/checkmail.go || {
      echo "aerc: worker/imap/checkmail.go does not request UIDVALIDITY --" >&2
      echo "the CheckMail backport did not apply. Cache keys would be" >&2
      echo "header.<mailbox>.0.<uid>. See modules/linux/aerc-uidvalidity.nix." >&2
      exit 1
    }
    test -f worker/imap/checkmail_uidvalidity_test.go || {
      echo "aerc: regression test missing; the build gate is gone." >&2
      exit 1
    }
  '';

  passthru = (prev.passthru or { }) // { uidValidityBackport = true; };
})
