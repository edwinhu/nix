# aerc + `:exec-tty` -- run a program on aerc's OWN terminal, full screen.
#
# THE PROBLEM IT SOLVES. aerc hosts full-screen programs with :term, which
# allocates a second pty and paints the child into a region of aerc's screen.
# That relay is cheap for CELLS (nvim in the composer sends a few hundred bytes
# a frame, diffed) and ruinous for IMAGES: terminal-browser hands the terminal a
# 5.75 MB frame as a file PATH in ~258 bytes, but aerc must open, decode,
# re-encode and re-stage its own copy to composite it -- two full-frame copies
# per frame. That is the flashing, the lag, and every defect the embedded path
# produced.
#
# The command adds no machinery: vaxis documents dropping out of the TUI to run
# another TUI, and aerc already wraps it as ui.SuspendScreen/ResumeScreen. The
# child is forked directly by aerc, so it inherits aerc's process group and IS
# the terminal's foreground group -- the thing a detached :pipe helper can never
# be, which is why those attempts suspended aerc and then hung on SIGTTIN.
{ lib
, aerc
, execTtySource ? ./aerc-exec-tty/exec-tty.go
}:

# NOTE: do not override pname. buildGoModule derives the vendor derivation's
# name from it, and renaming invalidates that fixed-output hash -- the build
# fails with a vendorHash mismatch that looks like a dependency change and is
# not one.
aerc.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    cp ${execTtySource} commands/exec-tty.go

    # Fail the build rather than ship an aerc where the command silently is not
    # registered: the file is only wired in by its init(), so a rename upstream
    # would leave a binary that builds, runs, and has no :exec-tty.
    grep -q 'Register(ExecTty{})' commands/exec-tty.go \
      || { echo "exec-tty.go does not register the command"; exit 1; }
  '';

  doCheck = false;
})
