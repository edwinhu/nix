// aerc-cal — the selected message becomes a calendar event. Bound to `b` in
// aerc: Gemini reads the mail, this form opens beside it so the extraction can
// be checked against the message it came from, and `morgen calendar create`
// runs only on ctrl+s.
//
// Styled after brscan-tui (rounded panels, selected-row highlight, keybind
// bar) and coloured from the ANSI 16-palette, so it follows the omarchy theme
// with nothing hardcoded.
//
// TWO INVARIANTS:
//  1. stdin is the MESSAGE, not the keyboard -- aerc's :pipe hands the mail
//     over fd 0. The program reads it to EOF, then hands bubbletea /dev/tty
//     via tea.WithInput. Skip that and the form reads mail headers as keys.
//  2. The extraction's JSON shape is forced by responseSchema, not requested
//     in the prompt. See extract.go.
package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"
	_ "time/tzdata" // so an unusual zone resolves without a system tzdata

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

const defaultZoom = "https://law-virginia.zoom.us/j/3823453577"

// ANSI palette indices — resolved by the terminal's theme (Catppuccin Mocha).
var (
	cAccent = lipgloss.Color("4") // blue
	cPink   = lipgloss.Color("5") // mauve/pink
	cOK     = lipgloss.Color("2") // green
	cBad    = lipgloss.Color("1") // red
	cMuted  = lipgloss.Color("8") // overlay / bright-black
	cBase   = lipgloss.Color("0") // base

	stTitle    = lipgloss.NewStyle().Foreground(cPink).Bold(true)
	stPanel    = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cMuted).Padding(1, 2)
	stPanelOn  = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).Padding(1, 2)
	stLabel    = lipgloss.NewStyle().Foreground(lipgloss.Color("7"))
	stSelLabel = lipgloss.NewStyle().Foreground(cBase).Background(cAccent).Bold(true)
	stValue    = lipgloss.NewStyle().Foreground(cAccent)
	stCycle    = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	stHint     = lipgloss.NewStyle().Foreground(cPink)
	stKey      = lipgloss.NewStyle().Foreground(cPink).Bold(true)
	stKeyDesc  = lipgloss.NewStyle().Foreground(cMuted)
	stOK       = lipgloss.NewStyle().Foreground(cOK).Bold(true)
	stBad      = lipgloss.NewStyle().Foreground(cBad).Bold(true)
	stMuted    = lipgloss.NewStyle().Foreground(cMuted)
	stMailHead = lipgloss.NewStyle().Foreground(cMuted)
)

const labelW = 10

type createDoneMsg struct{ err error }

type pane int

const (
	paneForm pane = iota
	paneMail
)

type model struct {
	form     Form
	cursor   int
	focus    pane
	mailView viewport.Model
	spin     spinner.Model
	status   string
	bad      bool
	creating bool
	created  bool
	width    int
	height   int
	ready    bool

	// Start as it was when the cursor entered that field, so moving Start can
	// carry End along and keep the duration the user already had.
	startWas string
}

func newModel(f Form) model {
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(cAccent)
	m := model{form: f, spin: sp}
	m.form.inputs[fTitle].Focus()
	m.startWas = f.Get(fStart)
	return m
}

func (m model) Init() tea.Cmd { return textinput.Blink }

// ---------------------------------------------------------------- update

func (m *model) focusField(i int) {
	for idx := range m.form.inputs {
		m.form.inputs[idx].Blur()
	}
	m.cursor = i
	if !fields[i].cycle {
		m.form.inputs[fields[i].id].Focus()
	}
}

func (m *model) move(delta int) {
	next := (m.cursor + delta + len(fields)) % len(fields)
	m.focusField(next)
	m.status, m.bad = "", false
}

// commitTimes rewrites the time fields as soon as the user is done with them,
// so "2pm" becomes 14:00 in front of them rather than silently at save time --
// and moves End with Start, keeping whatever duration the event already had.
// Run on every focus change and again before creating.
func (m *model) commitTimes() {
	for _, id := range []fieldID{fStart, fEnd} {
		if v := m.form.inputs[id].Value(); v != "" {
			m.form.inputs[id].SetValue(NormalizeTime(v))
		}
	}
	start, end := m.form.Get(fStart), m.form.Get(fEnd)
	switch {
	case start == "": // all-day; End is ignored either way
	case end == "":
		m.form.inputs[fEnd].SetValue(PlusDefault(start))
	case m.startWas != "" && m.startWas != start:
		m.form.inputs[fEnd].SetValue(shiftEnd(m.startWas, start, end))
	}
	m.startWas = m.form.Get(fStart)
}

// shiftEnd moves end by however far start moved, preserving the duration. A
// duration that has gone non-positive falls back to the 15-minute default.
func shiftEnd(oldStart, newStart, oldEnd string) string {
	o, err1 := time.Parse("15:04", oldStart)
	n, err2 := time.Parse("15:04", newStart)
	e, err3 := time.Parse("15:04", oldEnd)
	if err1 != nil || err2 != nil || err3 != nil {
		return PlusDefault(newStart)
	}
	dur := e.Sub(o)
	if dur <= 0 {
		dur = defaultDuration
	}
	return n.Add(dur).Format("15:04")
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.layout()
		m.ready = true
		return m, nil

	case createDoneMsg:
		m.creating = false
		if msg.err != nil {
			m.bad, m.status = true, msg.err.Error()
			return m, nil
		}
		m.created = true
		return m, tea.Quit

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case tea.KeyMsg:
		if m.creating {
			return m, nil
		}
		switch msg.String() {
		case "ctrl+c", "esc":
			return m, tea.Quit
		case "ctrl+s":
			m.commitTimes()
			if why := m.form.Validate(); why != "" {
				m.bad, m.status = true, why
				return m, nil
			}
			m.creating = true
			m.bad, m.status = false, ""
			form := m.form
			return m, tea.Batch(m.spin.Tick, func() tea.Msg {
				return createDoneMsg{err: form.Create()}
			})
		case "tab", "down":
			m.commitTimes()
			m.move(1)
			return m, nil
		case "shift+tab", "up":
			m.commitTimes()
			m.move(-1)
			return m, nil
		case "enter":
			m.commitTimes()
			m.move(1)
			return m, nil
		case "left":
			if fields[m.cursor].cycle {
				m.form.calIdx = (m.form.calIdx - 1 + len(m.form.cals)) % len(m.form.cals)
				return m, nil
			}
		case "right":
			if fields[m.cursor].cycle {
				m.form.calIdx = (m.form.calIdx + 1) % len(m.form.cals)
				return m, nil
			}
		// NOT ctrl+d/ctrl+u: bubbles' textinput binds ctrl+u to delete-to-start
		// and ctrl+w to delete-word, so stealing them breaks line editing in
		// every field. pgup/pgdn and alt+arrows are free.
		case "pgdown", "alt+down":
			m.mailView.HalfViewDown()
			return m, nil
		case "pgup", "alt+up":
			m.mailView.HalfViewUp()
			return m, nil
		}
		if !fields[m.cursor].cycle {
			id := fields[m.cursor].id
			var cmd tea.Cmd
			m.form.inputs[id], cmd = m.form.inputs[id].Update(msg)
			m.status, m.bad = "", false
			return m, cmd
		}
	}
	return m, nil
}

// ---------------------------------------------------------------- layout

func (m *model) layout() {
	fw, mw := m.paneWidths()
	for i := range m.form.inputs {
		m.form.inputs[i].Width = valueWidth(fw) - 1 // room for the cursor cell
	}
	inner := mw - 4 // the panel's padding
	head := stMailHead.Render(wrap(m.form.mail.headerBlock(), inner))
	body := m.form.mail.Body
	if body == "" {
		body = stMuted.Render("(no text body)")
	}
	m.mailView = viewport.New(inner, m.paneHeight()-4) // title + blank + padding
	m.mailView.SetContent(head + "\n\n" + wrap(body, inner))
}

// paneWidths splits the terminal between the two panels. A bordered panel
// renders TWO columns wider than its Width(), and the panels are separated by
// one space -- so the budget is form + mail + 5, not form + mail. Getting this
// wrong pushes the mail panel's right border off-screen, where it wraps.
func (m model) paneWidths() (form, mail int) {
	w := m.width
	if w < 60 {
		w = 100
	}
	form = w * 52 / 100
	if form > 68 {
		form = 68
	}
	mail = w - form - 5
	if mail < 28 {
		mail = 28
	}
	return form, mail
}

// paneHeight is shared by both panels so their borders line up.
func (m model) paneHeight() int {
	h := m.height - 6 // status line, keybar and the blank rows between
	if h < 10 {
		h = 10
	}
	return h
}

// ---------------------------------------------------------------- view

func (m model) View() string {
	if !m.ready {
		return ""
	}
	fw, mw := m.paneWidths()

	var rows []string
	for i, fl := range fields {
		lab := stLabel
		if i == m.cursor {
			lab = stSelLabel
		}
		label := lab.Render(fmt.Sprintf(" %-*s", labelW, fl.label))

		// ansi.Truncate, not lipgloss MaxWidth: MaxWidth leaves the overflow
		// behind, and a value that spills re-wraps the panel and knocks every
		// row under it out of alignment.
		valW := valueWidth(fw)
		var value string
		if fl.cycle {
			value = stCycle.Render("‹ " + m.form.Calendar().Label + " ›")
		} else {
			value = stValue.Render(m.form.inputs[fl.id].View())
		}
		rows = append(rows, label+"  "+ansi.Truncate(value, valW, "…"))

		// the local-time hint rides directly under the zone it qualifies
		if fl.id == fZone {
			if hint := m.form.LocalHint(); hint != "" {
				rows = append(rows, strings.Repeat(" ", labelW+3)+stHint.Render("↳ "+hint))
			}
		}
	}

	formPanel := panelStyle(m.focus == paneForm).Width(fw).Height(m.paneHeight()).Render(
		stTitle.Render("New event") + "\n" +
			stMuted.Render("from "+clip(m.form.mail.From, fw-10)) + "\n\n" +
			strings.Join(rows, "\n"))

	mailPanel := stPanel.Width(mw).Height(m.paneHeight()).Render(
		stTitle.Render("Message") + "\n\n" + m.mailView.View())

	panes := lipgloss.JoinHorizontal(lipgloss.Top, formPanel, " ", mailPanel)

	var statusLine string
	switch {
	case m.creating:
		statusLine = m.spin.View() + stValue.Render(" creating…")
	case m.bad && m.status != "":
		statusLine = stBad.Render("✗ " + m.status)
	case m.status != "":
		statusLine = stOK.Render("✓ " + m.status)
	default:
		when := m.form.Get(fDate)
		if !m.form.AllDay() {
			when += " " + m.form.Get(fStart) + "–" + m.form.Get(fEnd)
		} else {
			when += stMuted.Render(" all day")
		}
		statusLine = stMuted.Render("→ ") + stValue.Render(when) +
			stMuted.Render("  on  ") + stValue.Render(m.form.Calendar().Name)
	}

	key := func(k, d string) string { return stKey.Render(k) + " " + stKeyDesc.Render(d) }
	bar := strings.Join([]string{
		key("tab", "field"), key("←/→", "calendar"), key("ctrl+s", "create"),
		key("pgup/dn", "scroll mail"), key("esc", "cancel"),
	}, stKeyDesc.Render("  •  "))

	return lipgloss.JoinVertical(lipgloss.Left, panes, "", " "+statusLine, "", " "+bar)
}

// valueWidth: what is left of a form row after the panel's own padding, the
// label column and the gap. Width() sizes the content box INCLUDING padding,
// so the padding has to come off here or every row overruns by 2 and wraps.
func valueWidth(formW int) int {
	w := formW - 4 - (labelW + 1) - 2
	if w < 12 {
		w = 12
	}
	return w
}

func panelStyle(active bool) lipgloss.Style {
	if active {
		return stPanelOn
	}
	return stPanel
}

func wrap(s string, w int) string {
	if w < 20 {
		w = 20
	}
	var out []string
	for _, line := range strings.Split(s, "\n") {
		for len([]rune(line)) > w {
			cut := w
			if idx := strings.LastIndex(line[:w], " "); idx > w/3 {
				cut = idx
			}
			out = append(out, strings.TrimRight(line[:cut], " "))
			line = strings.TrimLeft(line[cut:], " ")
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// ---------------------------------------------------------------- main

// fail prints and holds: aerc closes this terminal tab the moment we exit
// (:pipe -s), so a message nobody can read is no message at all.
func fail(msg string) {
	fmt.Printf("\033[2J\033[H\n  %s\n\n  %s\n", stBad.Render("✗ "+msg),
		stMuted.Render("press enter"))
	if tty, err := os.OpenFile("/dev/tty", os.O_RDONLY, 0); err == nil {
		buf := make([]byte, 1)
		tty.Read(buf)
		tty.Close()
	}
	os.Exit(1)
}

func main() {
	var account, from string
	args := os.Args[1:]
	for i, a := range args {
		switch a {
		case "--account":
			if i+1 < len(args) {
				account = args[i+1]
			}
		case "--from":
			if i+1 < len(args) {
				from = args[i+1]
			}
		}
	}
	_ = account

	raw, err := io.ReadAll(os.Stdin)
	if err != nil || len(strings.TrimSpace(string(raw))) == 0 {
		fail("no message on stdin")
	}
	msg, err := ParseMail(raw)
	if err != nil {
		fail("could not parse the message: " + err.Error())
	}

	here := localZone()
	me := from
	if me == "" {
		me = "the reader"
	}

	fmt.Printf("\033[2J\033[H\n  %s\n", stMuted.Render("reading with "+model_()+"…"))
	ev, err := Extract(msg, here, me, model_())
	if err != nil {
		fail(err.Error())
	}
	if !ev.IsEvent {
		fail("no event found in this message")
	}

	cals, err := Calendars()
	if err != nil {
		fail(err.Error())
	}

	// Per-account calendar: the aerc account's own From address picks the
	// calendar that address owns. :pipe sets no AERC_* environment, so the
	// bind passes it in as a {{.AccountFrom}} template argument. A hand-run
	// `aerc-cal < mail` has none, and falls back to the recipient headers.
	want := ""
	if m := reEmail.FindString(strings.ToLower(from)); m != "" {
		want = m
	} else {
		recipients := strings.ToLower(msg.To + " " + msg.DeliveredTo)
		for _, c := range cals {
			if c.Owner != "" && strings.Contains(recipients, c.Owner) {
				want = c.Owner
				break
			}
		}
	}
	calIdx := 0
	for i, c := range cals {
		if c.Owner == want {
			calIdx = i
			break
		}
	}

	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fail("no terminal to draw on: " + err.Error())
	}
	defer tty.Close()

	form := NewForm(ev, msg, cals, calIdx, here)
	res, err := tea.NewProgram(newModel(form),
		tea.WithAltScreen(), tea.WithInput(tty), tea.WithOutput(os.Stdout)).Run()
	if err != nil {
		fail(err.Error())
	}

	final := res.(model)
	if !final.created {
		return
	}
	when := final.form.Get(fDate)
	if !final.form.AllDay() {
		when += " " + final.form.Get(fStart)
	}
	fmt.Printf("\033[2J\033[H\n  %s %s\n    %s\n",
		stOK.Render("✓"), final.form.Get(fTitle),
		stMuted.Render(when+"  →  "+final.form.Calendar().Label))
	time.Sleep(1200 * time.Millisecond)
}

func model_() string {
	if v := os.Getenv("AERC_CAL_MODEL"); v != "" {
		return v
	}
	return "gemini-3.7-flash"
}

func localZone() string {
	if b, err := os.ReadFile("/etc/timezone"); err == nil {
		if s := strings.TrimSpace(string(b)); s != "" {
			return s
		}
	}
	if p, err := os.Readlink("/etc/localtime"); err == nil {
		if i := strings.Index(p, "zoneinfo/"); i >= 0 {
			return p[i+len("zoneinfo/"):]
		}
	}
	return "America/New_York"
}
