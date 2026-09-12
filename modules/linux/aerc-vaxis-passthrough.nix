# aerc, built against a vaxis whose embedded terminal RELAYS a child's kitty
# graphics to the host terminal instead of discarding them.
#
# THE BUG. vaxis v0.17.1 can emit kitty graphics to the host terminal, but the
# child -> vaxis direction handles only sixel. widgets/term/action.go's entire
# APC arm was `vt.postEvent(EventAPC{Payload: seq.Data})`, and `EventAPC` has
# zero consumers in aerc, so a child's image became an event nobody caught. It
# also never answers the child's `a=q` probe, so terminal-browser -- which emits
# kitty and no sixel -- concludes the terminal has no graphics at all and
# renders the mail's text with every picture missing.
#
# WHY A RELAY AND NOT A DECODER. An earlier version of this module DECODED the
# child's frames to pixels and re-encoded them for the host. It worked and was
# retired for lag: two full-frame copies per frame at 15 frames a second. The
# measured protocol makes the cheap version possible -- terminal-browser sends
# one ~258-byte command per frame with a shm name or file path as the payload --
# so the embedded terminal can rename the child's image ids into the host's
# namespace, place at the widget's on-screen origin, translate deletes, answer
# `a=q` locally, and never touch a pixel.
#
# modules/linux/aerc-vaxis-passthrough.patch is the diff of the
# .vaxis-passthrough working checkout against vaxis v0.17.1, INCLUDING the
# widget's own test file -- postBuild below runs it inside the sandbox with the
# pinned toolchain, which is the only place the relay is exercised on the same
# Go that builds the shipped binary.
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
  vaxisWithKittyPassthrough = applyPatches {
    name = "vaxis-0.17.1-kitty-graphics-passthrough";
    src = fetchFromGitHub {
      owner = "rockorager";
      repo = "vaxis";
      rev = "v0.17.1";
      hash = "sha256-Tr5QIz08H789e4WYcqe7etpwVK9EzYyU5eOQ2WGGAA0=";
    };
    patches = [ ./aerc-vaxis-passthrough.patch ];

    # A build-time gate on the patched source. A patch that stops applying is
    # not silent here (applyPatches fails), but a patch that applies to a
    # RENAMED or restructured upstream can still land its hunks somewhere
    # useless -- and the resulting aerc builds, runs, and renders no images,
    # which is precisely the failure this whole change exists to fix. Each grep
    # names one seam of the relay, on both sides of the module boundary.
    postPatch = ''
      if [ ! -f widgets/term/kitty_passthrough.go ]; then
        echo "vaxis: the patch did not deliver widgets/term/kitty_passthrough.go." >&2
        exit 1
      fi
      if [ ! -f widgets/term/kitty_passthrough_test.go ]; then
        echo "vaxis: the patch did not deliver the passthrough test file, so" >&2
        echo "postBuild below would assert nothing." >&2
        exit 1
      fi
      if ! grep -q 'vt.kittyGraphics(seq.Data)' widgets/term/action.go; then
        echo "vaxis: widgets/term/action.go does not route APC through the kitty" >&2
        echo "relay. A child's images would be posted as EventAPC and dropped." >&2
        exit 1
      fi
      if ! grep -q 'func (vx \*Vaxis) NewKittyRelay' image.go; then
        echo "vaxis: image.go has no KittyRelay, so the embedded terminal has" >&2
        echo "nothing to forward a child's frames through." >&2
        exit 1
      fi
      if ! grep -q 'p1.rev == p2.rev' vaxis.go; then
        echo "vaxis: render() does not compare placement revisions, so a relayed" >&2
        echo "frame re-sent at the same cell is deduplicated and the pane freezes" >&2
        echo "on the first picture the child drew." >&2
        exit 1
      fi
      if ! grep -q 'drawKittyRelays' widgets/term/term.go; then
        echo "vaxis: Draw does not place relayed kitty images." >&2
        exit 1
      fi
      if ! grep -q 'releaseKittyRelays' widgets/term/term.go; then
        echo "vaxis: Close does not free the host images this widget opened," >&2
        echo "so every closed :term leaks a picture onto the real terminal." >&2
        exit 1
      fi
    '';
  };

  # The allowlist that decides which embedded terminal may name a file or a
  # shared-memory object as a kitty source. Written unindented because Nix's
  # indented-string stripping keys on leading SPACES: a single tab-led line
  # would leave the whole block indented and the Go source misformatted.
  kittyFileMediaGate = builtins.toFile "aerc-kitty-file-media.go" ''
package app

import (
	"os/exec"
	"path/filepath"
	"strings"
)

// kittyFileMediaFilterMarker appears in the store path of the terminal-browser
// launcher and filter (modules/linux/aerc-html-terminal-browser.nix) and
// nowhere else. Renaming that script disables the media rather than
// misapplying them.
const kittyFileMediaFilterMarker = "aerc-html-terminal-browser"

// aercKittyFileMediaAllowed reports whether this child may name its pixels by
// file path or shared-memory name (t=f, t=t, t=s).
//
// Those media put a path the CHILD chose into a command the HOST terminal then
// opens, so a terminal rendering untrusted input -- which is every HTML mail
// filter -- must not accept them. Only terminal-browser is trusted with them,
// because it stages its own frames in shared memory. Every other embedded
// terminal keeps the library default of off.
//
// cmd.Path is checked as well as cmd.Args, and through EvalSymlinks: a `:term`
// binding names the launcher by BARE NAME, so argv[0] is "aerc-mail-term" and
// the store path carrying the marker is only visible once the PATH lookup and
// the wrapper symlink have both been resolved.
func aercKittyFileMediaAllowed(cmd *exec.Cmd) bool {
	if cmd == nil {
		return false
	}
	for _, arg := range cmd.Args {
		if strings.Contains(arg, kittyFileMediaFilterMarker) {
			return true
		}
	}
	if cmd.Path == "" {
		return false
	}
	if strings.Contains(cmd.Path, kittyFileMediaFilterMarker) {
		return true
	}
	resolved, err := filepath.EvalSymlinks(cmd.Path)
	if err != nil {
		return false
	}
	return strings.Contains(resolved, kittyFileMediaFilterMarker)
}

// aercKittyKeyboardFor reports whether this child should get kitty KEYBOARD
// passthrough. Everything keeps the host-derived default except
// terminal-browser, which must not have it.
//
// vaxis enables passthrough whenever the host advertises the protocol, and
// ghostty does. terminal-browser negotiates it too (it sends CSI >1u), but does
// not act on keys delivered in that encoding: the page renders and then cannot
// be scrolled. Measured both ways against a real aerc -- with the host
// advertising kitty keyboard the rendered frame is byte-identical after arrow
// keys, space and j; with it withheld the frame changes and the page moves.
// Legacy keys it handles correctly, so withhold the protocol for this one child.
func aercKittyKeyboardFor(cmd *exec.Cmd, host bool) bool {
	if aercKittyFileMediaAllowed(cmd) {
		return false
	}
	return host
}
  '';
in
aerc.overrideAttrs (prev: {
  postPatch = (prev.postPatch or "") + ''
    go mod edit -replace go.rockorager.dev/vaxis=${vaxisWithKittyPassthrough}

    # Turn on the file/shm transmission media for the ONE child that needs them.
    #
    # They are off by default in the library because t=f/t=t/t=s name a
    # filesystem path the child chose and this build RELAYS that name to the
    # host terminal, which opens it. aerc's NewTerminal builds every embedded
    # terminal, including the one a text/html filter renders ATTACKER-CONTROLLED
    # mail in, so switching the option on there unconditionally would let a mail
    # sender pick a path for ghostty to read. Gate it on the child instead.
    # A separate file rather than an append plus an import edit: the helper
    # needs "strings" and "path/filepath", and rewriting terminal.go's import
    # block from a shell is how a patch starts landing hunks in the wrong place.
    cp ${kittyFileMediaGate} app/kitty_file_media.go
    # WithVaxis must come FIRST: it sets EnableKittyKeyboard from the host's
    # capability, so a WithKittyKeyboard passed before it would be overwritten.
    substituteInPlace app/terminal.go \
      --replace-fail 'term.New(term.WithVaxis(ui.Vaxis()))' \
                     'term.New(term.WithVaxis(ui.Vaxis()), term.WithKittyFileMedia(aercKittyFileMediaAllowed(cmd)), term.WithKittyKeyboard(aercKittyKeyboardFor(cmd, ui.Vaxis() != nil && ui.Vaxis().CanKittyKeyboard())))' \
      --replace-fail 'vterm = term.New()' \
                     'vterm = term.New(term.WithKittyFileMedia(aercKittyFileMediaAllowed(cmd)))'

    if grep -q 'term.WithKittyFileMedia(true)' app/terminal.go; then
      echo "aerc: WithKittyFileMedia is enabled unconditionally. Every embedded" >&2
      echo "terminal, including the one that renders untrusted HTML mail, would" >&2
      echo "then hand the host a child-supplied path to open." >&2
      exit 1
    fi
    if ! grep -q 'aercKittyKeyboardFor' app/terminal.go; then
      echo "aerc: kitty-keyboard passthrough is not gated per child. The" >&2
      echo "terminal-browser child would render a page that cannot be" >&2
      echo "scrolled, which looks like a hang rather than a bug." >&2
      exit 1
    fi
    if ! grep -q 'EvalSymlinks' app/kitty_file_media.go; then
      echo "aerc: the file-media allowlist does not resolve cmd.Path. A :term" >&2
      echo "binding names the launcher by bare name, so the marker would never" >&2
      echo "match and terminal-browser's frames would be refused." >&2
      exit 1
    fi
    if ! grep -q 'aerc-html-terminal-browser' app/kitty_file_media.go; then
      echo "aerc: the kitty file-media allowlist did not land in app/." >&2
      exit 1
    fi

    if ! grep -q 'go.rockorager.dev/vaxis => ' go.mod; then
      echo "aerc: the vaxis kitty-passthrough replace directive is not in go.mod." >&2
      echo "aerc would build against stock vaxis, which discards a child's kitty" >&2
      echo "graphics, and terminal-browser's images would never appear." >&2
      exit 1
    fi
  '';

  # Run the relay's own tests against the SAME module tree and toolchain that
  # produced the binary. The checkout on the developer's machine is not what
  # ships; this is.
  postBuild = (prev.postBuild or "") + ''
    go test go.rockorager.dev/vaxis/widgets/term -run Kitty
  '';

  passthru = (prev.passthru or { }) // {
    vaxisKittyPassthrough = true;
    inherit vaxisWithKittyPassthrough;
  };
})
