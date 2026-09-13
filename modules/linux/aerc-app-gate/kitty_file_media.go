package app

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// kittyFileMediaFilterMarker appears in the store path of the terminal-browser
// launcher and filter (modules/linux/aerc-html-terminal-browser.nix) and
// nowhere else. Renaming that script disables the media rather than
// misapplying them.
const kittyFileMediaFilterMarker = "aerc-html-terminal-browser"

// kittyFileMediaMaxHops bounds the symlink walk below. A chain longer than this
// -- or one that loops -- ends the walk undecided, which denies. Linux's own
// limit is 40, so no legitimate chain reaches it.
const kittyFileMediaMaxHops = 32

// aercKittyFileMediaAllowed reports whether this child may name its pixels by
// file path or shared-memory name (t=f, t=t, t=s).
//
// Those media put a path the CHILD chose into a command the HOST terminal then
// opens, so a terminal rendering untrusted input -- which is every HTML mail
// filter -- must not accept them. Only terminal-browser is trusted with them,
// because it stages its own frames in shared memory. Every other embedded
// terminal keeps the library default of off.
//
// cmd.Path is checked as well as cmd.Args, and so is EVERY HOP of the symlink
// chain it starts. The launcher is a symlinkJoin, so the store path carrying
// the marker is a middle hop: ~/.nix-profile/bin/aerc-mail-term ->
// <store>-aerc-html-terminal-browser/bin/aerc-mail-term (marker) ->
// <store>-aerc-mail-term/bin/aerc-mail-term (no marker). EvalSymlinks reports
// only that last hop, so an endpoint-only test refuses the real child. The
// EvalSymlinks test is kept as well: it resolves symlinked DIRECTORY components,
// which a walk over the final component alone does not see.
//
// A bare cmd.Path is resolved through PATH first: a `:term` binding names the
// launcher by BARE NAME, so argv[0] is "aerc-mail-term" and there is no chain to
// walk until the lookup has happened.
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

	start := cmd.Path
	if !strings.ContainsRune(start, filepath.Separator) {
		found, err := exec.LookPath(start)
		if err != nil {
			return false
		}
		if strings.Contains(found, kittyFileMediaFilterMarker) {
			return true
		}
		start = found
	}

	if kittyFileMediaChainCarriesMarker(start) {
		return true
	}

	resolved, err := filepath.EvalSymlinks(start)
	if err != nil {
		return false
	}
	return strings.Contains(resolved, kittyFileMediaFilterMarker)
}

// kittyFileMediaChainCarriesMarker walks the symlink chain starting at path one
// hop at a time and reports whether any hop's own path carries the marker.
//
// path itself is the caller's to test; this tests each TARGET. A relative target
// is resolved against the directory of the link that named it, and every hop is
// lexically cleaned before the test, so a target spelled
// ".../aerc-html-terminal-browser/../elsewhere" collapses to ".../elsewhere" and
// does not match. The walk stops at the first non-symlink, the first error (a
// dangling link included), or hop kittyFileMediaMaxHops -- all of which deny.
func kittyFileMediaChainCarriesMarker(path string) bool {
	for hop := 0; hop < kittyFileMediaMaxHops; hop++ {
		info, err := os.Lstat(path)
		if err != nil || info.Mode()&os.ModeSymlink == 0 {
			return false
		}
		target, err := os.Readlink(path)
		if err != nil {
			return false
		}
		if filepath.IsAbs(target) {
			path = filepath.Clean(target)
		} else {
			path = filepath.Join(filepath.Dir(path), target)
		}
		if strings.Contains(path, kittyFileMediaFilterMarker) {
			return true
		}
	}
	return false
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

// aercPaintOnDrainFor reports whether this child's embedded terminal should
// paint the moment the child's output drains, instead of waiting out the
// widget's 8 ms coalescing timer.
//
// AERC_TERM_PAINT_ON_DRAIN overrides the decision for every terminal: "1"
// forces it on, "0" forces it off, anything else -- including unset -- takes
// the per-child default below. It is read from AERC's OWN environment, which is
// the user's; a child cannot set it, and neither can a message, so the override
// is an A/B switch for the person running aerc and not an input.
//
// The default is terminal-browser and nothing else. That child stages its
// frames and scrolls them, so the 8 ms lands between the keypress and the page
// moving and is felt. Every other embedded terminal -- including the one a
// text/html filter renders untrusted mail in -- keeps the timer, which is the
// library default. The gate is the same marker aercKittyFileMediaAllowed uses,
// so "the trusted child" has one definition in this file rather than two that
// can drift.
func aercPaintOnDrainFor(cmd *exec.Cmd) bool {
	switch os.Getenv("AERC_TERM_PAINT_ON_DRAIN") {
	case "1":
		return true
	case "0":
		return false
	}
	return aercKittyFileMediaAllowed(cmd)
}
