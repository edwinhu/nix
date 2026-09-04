# aerc, built against a vaxis whose embedded terminal DECODES a child's kitty
# graphics instead of discarding them.
#
# THE BUG. vaxis v0.17.1 can emit kitty graphics to the host terminal, but the
# child -> vaxis direction handles only sixel. widgets/term/action.go's entire
# APC arm was `vt.postEvent(EventAPC{Payload: seq.Data})`, and `EventAPC` has
# zero consumers in aerc, so a child's image became an event nobody caught. The
# practical consequence: chawan (sixel) is the only HTML engine that can show
# images under aerc, and terminal-browser -- which emits kitty and nothing else
# -- renders the mail's text and loses every picture.
#
# modules/linux/aerc-vaxis-kitty.patch adds widgets/term/kitty.go, the decoder,
# and routes the APC arm through it. It is the diff of the .vaxis-kitty working
# checkout against vaxis v0.17.1, minus the test file.
#
# It goes in as a `go mod edit -replace` onto a patched checkout because
# nixpkgs builds aerc from the module cache: there is no vendor/ tree in the
# build to edit, and the module cache is read-only in the store. A filesystem
# replace directive needs no go.sum entry, and the patch does not touch
# vaxis's own go.mod, so the module set -- and therefore aerc's vendorHash --
# is unchanged.
#
# `aerc = prev.aerc` explicitly at the call site: callPackage's auto-args resolve
# against the FINAL package set, so letting it fill `aerc` in would point this
# override at itself.
{ aerc, fetchFromGitHub, applyPatches }:

let
  # v0.17.1 is the version aerc 0.22.0 already pins, so this replaces the module
  # with itself-plus-patch and changes nothing else about the build.
  vaxisWithKittyDecode = applyPatches {
    name = "vaxis-0.17.1-kitty-graphics-decode";
    src = fetchFromGitHub {
      owner = "rockorager";
      repo = "vaxis";
      rev = "v0.17.1";
      hash = "sha256-Tr5QIz08H789e4WYcqe7etpwVK9EzYyU5eOQ2WGGAA0=";
    };
    patches = [ ./aerc-vaxis-kitty.patch ];

    # A build-time gate on the patched source. A patch that stops applying is
    # not silent here (applyPatches fails), but a patch that applies to a
    # RENAMED or restructured upstream can still land its hunks somewhere
    # useless -- and the resulting aerc builds, runs, and renders no images,
    # which is precisely the failure this whole change exists to fix.
    postPatch = ''
      if [ ! -f widgets/term/kitty.go ]; then
        echo "vaxis: the kitty-graphics patch did not deliver widgets/term/kitty.go." >&2
        exit 1
      fi
      if ! grep -q 'vt.kittyGraphics(seq.Data)' widgets/term/action.go; then
        echo "vaxis: widgets/term/action.go does not route APC through the kitty" >&2
        echo "decoder. A child's images would be posted as EventAPC and dropped." >&2
        exit 1
      fi
    '';
  };

  # The allowlist that decides which embedded terminal may use the kitty file
  # and shared-memory transmission media. Written unindented because Nix's
  # indented-string stripping keys on leading SPACES: a single tab-led line
  # would leave the whole block indented and the Go source misformatted.
  kittyFileMediaGate = builtins.toFile "aerc-kitty-file-media.go" ''
package app

import (
	"os/exec"
	"strings"
)

// kittyFileMediaFilterMarker appears in the store path of the terminal-browser
// text/html filter (modules/linux/aerc-html-terminal-browser.nix) and nowhere
// else. Renaming that script disables the media rather than misapplying them.
const kittyFileMediaFilterMarker = "aerc-html-terminal-browser"

// aercKittyFileMediaAllowed reports whether this child may transmit kitty
// graphics by file path or shared-memory name (t=f, t=t, t=s).
//
// Those media read a path the CHILD puts in its escape stream, so a terminal
// rendering untrusted input -- which is every HTML mail filter -- must not
// accept them. Only the terminal-browser filter is trusted with them, because
// it stages its own frames in shared memory. Every other embedded terminal
// keeps the library default of off.
func aercKittyFileMediaAllowed(cmd *exec.Cmd) bool {
	if cmd == nil {
		return false
	}
	for _, arg := range cmd.Args {
		if strings.Contains(arg, kittyFileMediaFilterMarker) {
			return true
		}
	}
	return false
}
  '';
in
aerc.overrideAttrs (prev: {
  postPatch = (prev.postPatch or "") + ''
    go mod edit -replace go.rockorager.dev/vaxis=${vaxisWithKittyDecode}

    # Turn on the file/shm transmission media for the ONE child that needs them.
    #
    # They are off by default in the library because t=f/t=t/t=s take a
    # filesystem path straight out of the child's escape stream: any child that
    # echoes untrusted bytes becomes an arbitrary-file-read primitive. aerc's
    # NewTerminal builds every embedded terminal, including the one a text/html
    # filter renders ATTACKER-CONTROLLED mail in, so switching the option on
    # there unconditionally hands that primitive to the mail sender. Gate it on
    # the child's argv instead: only the terminal-browser filter -- which sends
    # its own frames and stages large ones in shared memory -- is trusted with
    # it. See modules/linux/aerc-html-terminal-browser.nix, whose store path
    # carries the marker matched below.
    # A separate file rather than an append plus an import edit: the helper
    # needs "strings", and rewriting terminal.go's import block from a shell is
    # how a patch starts landing hunks in the wrong place.
    cp ${kittyFileMediaGate} app/kitty_file_media.go
    substituteInPlace app/terminal.go \
      --replace-fail 'term.New(term.WithVaxis(ui.Vaxis()))' \
                     'term.New(term.WithVaxis(ui.Vaxis()), term.WithKittyFileMedia(aercKittyFileMediaAllowed(cmd)))' \
      --replace-fail 'vterm = term.New()' \
                     'vterm = term.New(term.WithKittyFileMedia(aercKittyFileMediaAllowed(cmd)))'

    if grep -q 'term.WithKittyFileMedia(true)' app/terminal.go; then
      echo "aerc: WithKittyFileMedia is enabled unconditionally. Every embedded" >&2
      echo "terminal, including the one that renders untrusted HTML mail, would" >&2
      echo "then accept a child-supplied file path as an image source." >&2
      exit 1
    fi
    if ! grep -q 'aerc-html-terminal-browser' app/kitty_file_media.go; then
      echo "aerc: the kitty file-media allowlist did not land in app/." >&2
      exit 1
    fi

    if ! grep -q 'go.rockorager.dev/vaxis => ' go.mod; then
      echo "aerc: the vaxis kitty-graphics replace directive is not in go.mod." >&2
      echo "aerc would build against stock vaxis, which discards a child's kitty" >&2
      echo "graphics, and terminal-browser's images would never appear." >&2
      exit 1
    fi
  '';

  passthru = (prev.passthru or { }) // {
    vaxisKittyGraphics = true;
    inherit vaxisWithKittyDecode;
  };
})
