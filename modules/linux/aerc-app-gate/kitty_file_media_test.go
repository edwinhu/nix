package app

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// mkexec writes a real executable file at path, creating its parents.
func mkexec(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%s): %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("WriteFile(%s): %v", path, err)
	}
}

// mklink makes target reachable from link, creating link's parents.
func mklink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatalf("MkdirAll(%s): %v", filepath.Dir(link), err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatalf("Symlink(%s -> %s): %v", link, target, err)
	}
}

// resolved reports what EvalSymlinks makes of path, for failure messages.
func resolved(path string) string {
	r, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "<unresolvable: " + err.Error() + ">"
	}
	return r
}

// TestFileMediaAllowedThroughSymlinkJoin builds the chain production actually
// has. `o` runs `aerc-mail-term <file>`, so cmd.Path is the profile symlink; it
// points at the symlinkJoin whose store path carries the marker, and THAT
// points at the inner derivation, whose store path does not. EvalSymlinks
// resolves the whole chain and returns only the last hop, so the marker on the
// middle hop is invisible to a gate that looks only at the endpoint.
func TestFileMediaAllowedThroughSymlinkJoin(t *testing.T) {
	tmp := t.TempDir()

	inner := filepath.Join(tmp, "store", "g9pl-aerc-mail-term", "bin", "aerc-mail-term")
	join := filepath.Join(tmp, "store", "kb4g-aerc-html-terminal-browser", "bin", "aerc-mail-term")
	profile := filepath.Join(tmp, "profile", "bin", "aerc-mail-term")

	mkexec(t, inner)
	mklink(t, inner, join)
	mklink(t, join, profile)

	cmd := exec.Command(profile, "/some/mail.eml")
	if !aercKittyFileMediaAllowed(cmd) {
		t.Fatalf("aercKittyFileMediaAllowed = false, want true\n"+
			"  cmd.Path = %s\n"+
			"  resolved = %s\n"+
			"the marker %q is on the MIDDLE hop of the chain, which EvalSymlinks "+
			"discards; the gate must examine every hop",
			cmd.Path, resolved(cmd.Path), kittyFileMediaFilterMarker)
	}
}

// TestFileMediaDeniedForOtherChildren is the security property: a child whose
// chain carries the marker nowhere must not be handed t=f/t=s.
func TestFileMediaDeniedForOtherChildren(t *testing.T) {
	tmp := t.TempDir()

	inner := filepath.Join(tmp, "store", "xxx-chawan", "bin", "chawan")
	profile := filepath.Join(tmp, "profile", "bin", "chawan")

	mkexec(t, inner)
	mklink(t, inner, profile)

	cmd := exec.Command(profile, "/some/mail.eml")
	if aercKittyFileMediaAllowed(cmd) {
		t.Fatalf("aercKittyFileMediaAllowed = true, want false\n"+
			"  cmd.Path = %s\n"+
			"  resolved = %s\n"+
			"no hop carries %q, so this child must keep the library default of off",
			cmd.Path, resolved(cmd.Path), kittyFileMediaFilterMarker)
	}
}

// TestFileMediaAllowedWhenPathCarriesMarker covers the simple case: cmd.Path
// itself is inside the marked store path, with no symlink in the way.
func TestFileMediaAllowedWhenPathCarriesMarker(t *testing.T) {
	tmp := t.TempDir()

	direct := filepath.Join(tmp, "store", "kb4g-aerc-html-terminal-browser", "bin", "aerc-mail-term")
	mkexec(t, direct)

	cmd := exec.Command(direct, "/some/mail.eml")
	if !aercKittyFileMediaAllowed(cmd) {
		t.Fatalf("aercKittyFileMediaAllowed = false, want true\n"+
			"  cmd.Path = %s\n"+
			"  resolved = %s\n"+
			"cmd.Path itself contains %q",
			cmd.Path, resolved(cmd.Path), kittyFileMediaFilterMarker)
	}
}
