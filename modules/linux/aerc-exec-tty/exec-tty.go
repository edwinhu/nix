package commands

import (
	"errors"
	"os"
	"os/exec"

	"git.sr.ht/~rjarry/aerc/lib/ui"
)

// ExecTty runs a program ON AERC'S OWN TERMINAL, full screen, and returns to
// aerc when it exits.
//
// WHY THIS EXISTS. aerc can already host a full-screen program with :term, but
// that allocates a SECOND pty and paints the child's output into a region of
// aerc's screen. For a program that emits cells -- $EDITOR, and nvim in the
// composer -- that relay is cheap: vaxis diffs the cells and repaints a few
// hundred bytes. For a program that emits IMAGES it is not. Measured with
// terminal-browser rendering HTML mail: the child hands the terminal a 5.75 MB
// frame as a FILE PATH in ~258 bytes on the wire, but aerc must open that file,
// decode it, re-encode and re-stage its own copy to composite it -- two
// full-frame copies per frame, ~170 MB/s at fifteen frames a second, which the
// terminal cannot keep up with. Run on aerc's own terminal instead, the child
// talks to the terminal directly and none of that exists.
//
// WHY IT IS THIS SHORT. vaxis documents the case explicitly -- "Suspend can be
// useful to, for example, drop out of the full screen TUI and run another TUI"
// -- and aerc already wraps it as ui.SuspendScreen/ResumeScreen. The only
// missing piece was a command.
//
// WHY A DIRECT CHILD, and not :pipe -b or a detached helper. A terminal
// delivers input only to its FOREGROUND process group. A child forked here
// inherits aerc's process group and stdio, so it IS the foreground group and
// can read the keyboard. A detached helper is not, and takes SIGTTIN on its
// first read -- which looks exactly like "aerc suspended and nothing opened".
type ExecTty struct {
	Cmd []string `opt:"..." required:"true"`
}

func init() {
	Register(ExecTty{})
}

func (ExecTty) Description() string {
	return "Run a command on aerc's terminal, full screen, until it exits."
}

func (ExecTty) Context() CommandContext {
	return GLOBAL
}

func (ExecTty) Aliases() []string {
	return []string{"exec-tty"}
}

func (e ExecTty) Execute(args []string) error {
	if len(e.Cmd) == 0 {
		return errors.New("usage: exec-tty <command> [args...]")
	}

	ui.SuspendScreen()
	// Resume even if the child fails to start or dies badly: leaving aerc
	// suspended would strand the user in a terminal with no visible program.
	defer ui.ResumeScreen()

	cmd := exec.Command(e.Cmd[0], e.Cmd[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
