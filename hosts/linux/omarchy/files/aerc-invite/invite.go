// Minting the Morgen Open Invite, and turning the returned link into a
// threaded reply draft.
package main

import (
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

var linkRe = regexp.MustCompile(`https://\S*book\.morgen\.so/\S+`)

// Mint creates the one-off booking link over the chosen spans.
func Mint(title string, dur time.Duration, spans []Span, calendar string) (string, error) {
	var slots []string
	for _, s := range spans {
		slots = append(slots, s.Start.Format(time.RFC3339)+"/"+s.End.Format(time.RFC3339))
	}
	args := []string{"open-invite", "--title", title,
		"--duration", fmt.Sprintf("%dm", int(dur.Minutes())),
		"--slots", strings.Join(slots, ",")}
	if calendar != "" {
		args = append(args, "--calendar", calendar)
	}
	out, err := exec.Command("morgen", args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", clip(lastLine(string(out)), 300))
	}
	link := linkRe.FindString(string(out))
	if link == "" {
		return "", fmt.Errorf("no booking link in morgen's output: %s", clip(string(out), 200))
	}
	return link, nil
}

// Draft builds a THREADED reply carrying the link and leaves it in Drafts.
// Never sends: the composed reply is the user's to review (S then y in aerc).
func Draft(account, rawMessage, body, link string) error {
	mml := fmt.Sprintf(
		"<#part type=text/html>\n%s\n<p><a href=\"%s\">Pick a time that suits you</a></p>\n",
		body, link)
	sig := fmt.Sprintf("cat %s/.local/share/himalaya/signatures/%s.html", homeDir(), account)

	// templates reply gives the threading headers; the header block alone is
	// kept because -b "" leaves an EMPTY text/plain part that would otherwise
	// make the HTML a multipart/mixed sibling -- i.e. an attachment.
	script := fmt.Sprintf(`set -o pipefail
src=$(mktemp); cat > "$src"
{ mml -a %[1]s templates reply -b "" < "$src" | sed -n '1,/^$/p'
  cat <<'MMLBODY'
%[2]s
MMLBODY
  %[3]s
  printf '\n'
} | mml -a %[1]s compile | %[4]s
rm -f "$src"`, account, mml, sig, draftCmd(account))

	cmd := exec.Command("sh", "-c", script)
	cmd.Stdin = strings.NewReader(rawMessage)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%s", clip(lastLine(string(out)), 300))
	}
	return nil
}

// The two backends disagree about how a draft is created.
func draftCmd(account string) string {
	if account == "work" {
		return "himalaya msgraph message create -a work -f drafts"
	}
	return "himalaya gmail drafts create -a personal"
}

func homeDir() string {
	out, _ := exec.Command("sh", "-c", "echo $HOME").Output()
	return strings.TrimSpace(string(out))
}

func lastLine(s string) string {
	l := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(l[len(l)-1])
}
