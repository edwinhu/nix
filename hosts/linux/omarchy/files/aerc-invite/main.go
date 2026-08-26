// aerc-invite — the selected message becomes a Morgen booking link and a
// threaded reply draft. Bound to `i` in aerc, the sibling of `b` (aerc-cal).
//
// Same two invariants as aerc-cal:
//  1. stdin is the MESSAGE. aerc's :pipe hands the mail over fd 0, so the TUI
//     takes the keyboard from /dev/tty via tea.WithInput.
//  2. The extraction's JSON shape is FORCED by responseSchema, not requested.
//
// And one of its own: a booking LINK is a 1:1 instrument. The
// calendar-availability skill is explicit that two or more attendees means a
// poll, never a link or a hand-listed time, so this refuses that case outright
// rather than quietly offering the wrong thing.
package main

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

var (
	cAccent = lipgloss.Color("4")
	cPink   = lipgloss.Color("5")
	cOK     = lipgloss.Color("2")
	cBad    = lipgloss.Color("1")
	cMuted  = lipgloss.Color("8")
	cBase   = lipgloss.Color("0")

	stTitle   = lipgloss.NewStyle().Foreground(cPink).Bold(true)
	stPanel   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).Padding(1, 2)
	stLabel   = lipgloss.NewStyle().Foreground(lipgloss.Color("7"))
	stSel     = lipgloss.NewStyle().Foreground(cBase).Background(cAccent).Bold(true)
	stValue   = lipgloss.NewStyle().Foreground(cAccent)
	stKey     = lipgloss.NewStyle().Foreground(cPink).Bold(true)
	stKeyDesc = lipgloss.NewStyle().Foreground(cMuted)
	stOK      = lipgloss.NewStyle().Foreground(cOK).Bold(true)
	stBad     = lipgloss.NewStyle().Foreground(cBad).Bold(true)
	stMuted   = lipgloss.NewStyle().Foreground(cMuted)
)

type slotItem struct {
	Span
	on bool
}

type doneMsg struct {
	link string
	err  error
}

type model struct {
	slots   []slotItem
	cursor  int // 0..len(slots)-1 slots, then the fields
	fields  []textinput.Model
	focus   int // index into the whole tab order
	mail    Mail
	account string
	dur     time.Duration
	spin    spinner.Model
	working bool
	link    string
	status  string
	bad     bool
	w, h    int
	ready   bool
}

const (
	fTitle = iota
	fBody
	nFields
)

func (m model) nItems() int { return len(m.slots) + nFields }

func (m model) Init() tea.Cmd { return textinput.Blink }

func (m *model) syncFocus() {
	for i := range m.fields {
		m.fields[i].Blur()
	}
	if m.focus >= len(m.slots) {
		m.fields[m.focus-len(m.slots)].Focus()
	}
}

func (m model) chosen() []Span {
	var out []Span
	for _, s := range m.slots {
		if s.on {
			out = append(out, s.Span)
		}
	}
	return out
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.ready = true
		return m, nil
	case doneMsg:
		m.working = false
		if msg.err != nil {
			m.bad, m.status = true, msg.err.Error()
			return m, nil
		}
		m.link = msg.link
		return m, tea.Quit
	case spinner.TickMsg:
		var c tea.Cmd
		m.spin, c = m.spin.Update(msg)
		return m, c
	case tea.KeyMsg:
		if m.working {
			return m, nil
		}
		switch msg.String() {
		case "ctrl+c", "esc":
			return m, tea.Quit
		case "tab", "down":
			m.focus = (m.focus + 1) % m.nItems()
			m.syncFocus()
			return m, nil
		case "shift+tab", "up":
			m.focus = (m.focus - 1 + m.nItems()) % m.nItems()
			m.syncFocus()
			return m, nil
		case " ":
			if m.focus < len(m.slots) {
				m.slots[m.focus].on = !m.slots[m.focus].on
				m.status, m.bad = "", false
				return m, nil
			}
		case "a":
			if m.focus < len(m.slots) {
				all := true
				for _, s := range m.slots {
					all = all && s.on
				}
				for i := range m.slots {
					m.slots[i].on = !all
				}
				return m, nil
			}
		case "ctrl+s":
			sel := m.chosen()
			if len(sel) == 0 {
				m.bad, m.status = true, "no slots selected — space toggles one, a toggles all"
				return m, nil
			}
			title := strings.TrimSpace(m.fields[fTitle].Value())
			if title == "" {
				m.bad, m.status = true, "title is empty"
				return m, nil
			}
			m.working, m.bad, m.status = true, false, ""
			mm := m
			return m, tea.Batch(m.spin.Tick, func() tea.Msg {
				link, err := Mint(title, mm.dur, sel, "")
				if err != nil {
					return doneMsg{err: err}
				}
				body := strings.TrimSpace(mm.fields[fBody].Value())
				if err := Draft(mm.account, mm.mail.Raw, "<p>"+body+"</p>", link); err != nil {
					return doneMsg{link: link, err: fmt.Errorf("link minted (%s) but the draft failed: %v", link, err)}
				}
				return doneMsg{link: link}
			})
		}
		if m.focus >= len(m.slots) {
			i := m.focus - len(m.slots)
			var c tea.Cmd
			m.fields[i], c = m.fields[i].Update(msg)
			m.status, m.bad = "", false
			return m, c
		}
	}
	return m, nil
}

func (m model) View() string {
	if !m.ready {
		return ""
	}
	w := m.w - 6
	if w < 50 || w > 92 {
		w = 82
	}
	var rows []string
	rows = append(rows, stTitle.Render("Booking link")+"  "+
		stMuted.Render("for "+clip(m.mail.From, 46)))
	rows = append(rows, "")

	day := ""
	for i, s := range m.slots {
		d := s.Start.Format("Mon Jan 2")
		if d != day {
			day = d
			rows = append(rows, stMuted.Render("  "+d))
		}
		box := "☐"
		if s.on {
			box = "☑"
		}
		line := fmt.Sprintf("  %s  %s – %s", box,
			s.Start.Format("15:04"), s.End.Format("15:04"))
		if i == m.focus {
			line = stSel.Render(line + strings.Repeat(" ", max(0, 26-len(line))))
		} else {
			line = stValue.Render(line)
		}
		rows = append(rows, line)
	}
	rows = append(rows, "")
	for i, f := range m.fields {
		lab := []string{"Title", "Note"}[i]
		st := stLabel
		if m.focus == len(m.slots)+i {
			st = stSel
		}
		rows = append(rows, st.Render(fmt.Sprintf(" %-6s", lab))+"  "+
			ansi.Truncate(stValue.Render(f.View()), w-14, "…"))
	}

	var status string
	switch {
	case m.working:
		status = m.spin.View() + stValue.Render(" minting the link and drafting…")
	case m.bad && m.status != "":
		status = stBad.Render("✗ " + m.status)
	default:
		status = stMuted.Render(fmt.Sprintf("→ %d slot(s) · %d min · draft saved to %s Drafts",
			len(m.chosen()), int(m.dur.Minutes()), m.account))
	}
	key := func(k, d string) string { return stKey.Render(k) + " " + stKeyDesc.Render(d) }
	bar := strings.Join([]string{
		key("space", "toggle"), key("a", "all"), key("tab", "move"),
		key("ctrl+s", "mint + draft"), key("esc", "cancel"),
	}, stKeyDesc.Render("  •  "))

	return lipgloss.JoinVertical(lipgloss.Left,
		stPanel.Width(w).Render(strings.Join(rows, "\n")), "", " "+status, "", " "+bar)
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func fail(msg string) {
	fmt.Printf("\033[2J\033[H\n  %s\n\n  %s\n", stBad.Render("✗ "+msg), stMuted.Render("press enter"))
	if tty, err := os.OpenFile("/dev/tty", os.O_RDONLY, 0); err == nil {
		tty.Read(make([]byte, 1))
		tty.Close()
	}
	os.Exit(1)
}

func main() {
	var from string
	args := os.Args[1:]
	for i, a := range args {
		if a == "--from" && i+1 < len(args) {
			from = args[i+1]
		}
	}
	raw, err := io.ReadAll(os.Stdin)
	if err != nil || len(strings.TrimSpace(string(raw))) == 0 {
		fail("no message on stdin")
	}
	msg, err := ParseMail(raw)
	if err != nil {
		fail("could not parse the message: " + err.Error())
	}
	msg.Raw = string(raw)

	account := "personal"
	if strings.Contains(strings.ToLower(from), "law.virginia.edu") {
		account = "work"
	}

	model_ := os.Getenv("AERC_INVITE_MODEL")
	if model_ == "" {
		model_ = "gemini-3.7-flash"
	}
	fmt.Printf("\033[2J\033[H\n  %s\n", stMuted.Render("reading with "+model_+"…"))
	ask, err := Extract(msg, model_)
	if err != nil {
		fail(err.Error())
	}
	if !ask.IsSchedulingRequest {
		fail("this message is not asking to meet")
	}
	if len(ask.OtherHumans) > 0 {
		fail(fmt.Sprintf("%d other people on this thread (%s) — a booking link is 1:1 only.\n  Two or more attendees means a POLL: morgen open-invite is the wrong tool.\n  Use the calendar-availability skill.",
			len(ask.OtherHumans), strings.Join(ask.OtherHumans, ", ")))
	}

	loc, err := time.LoadLocation(localZone())
	if err != nil {
		loc = time.Local
	}
	dur := time.Duration(ask.DurationMinutes) * time.Minute
	if dur < 15*time.Minute {
		dur = 30 * time.Minute
	}
	days := ask.WithinDays
	if days < 1 || days > 30 {
		days = 10
	}
	spans, err := Offerable(days, dur, loc, time.Now().In(loc))
	if err != nil {
		fail("could not read the calendar: " + err.Error())
	}
	if len(spans) == 0 {
		fail(fmt.Sprintf("no offerable %d-minute slots in the next %d days", int(dur.Minutes()), days))
	}

	items := make([]slotItem, len(spans))
	for i, s := range spans {
		items[i] = slotItem{Span: s, on: true}
	}
	name := ask.PersonName
	if name == "" {
		name = firstWord(msg.From)
	}
	mk := func(v string, w int) textinput.Model {
		t := textinput.New()
		t.Prompt, t.CharLimit, t.Width = "", 300, w
		t.SetValue(v)
		return t
	}
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(cAccent)

	m := model{
		slots:   items,
		fields:  []textinput.Model{mk("Edwin Hu / "+name, 60), mk("Happy to talk — grab whichever of these works:", 60)},
		mail:    msg,
		account: account,
		dur:     dur,
		spin:    sp,
	}
	m.syncFocus()

	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fail("no terminal to draw on: " + err.Error())
	}
	defer tty.Close()
	res, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithInput(tty), tea.WithOutput(os.Stdout)).Run()
	if err != nil {
		fail(err.Error())
	}
	final := res.(model)
	if final.link == "" {
		return
	}
	fmt.Printf("\033[2J\033[H\n  %s %s\n    %s\n",
		stOK.Render("✓"), final.link,
		stMuted.Render("reply draft saved to "+final.account+" Drafts — S then y in aerc to send"))
	time.Sleep(1600 * time.Millisecond)
}

func firstWord(s string) string {
	s = strings.TrimSpace(strings.Split(s, "<")[0])
	if s == "" {
		return "you"
	}
	return strings.Fields(s)[0]
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

var _ = strconv.Itoa
