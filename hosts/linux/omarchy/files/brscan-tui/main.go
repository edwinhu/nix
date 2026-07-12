// brscan-tui — full-screen scan dashboard for the Brother DS-740D, styled after
// bluetui (rounded-border panels, selected-row highlight, keybind bar). Colors
// use the ANSI 16-color palette so they follow the terminal theme (Catppuccin
// here) automatically — switch omarchy themes and this follows, no hardcoding.
// Shells out to the brscan / brscan-pdf wrappers (put on PATH by nix).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ANSI palette indices — resolved by the terminal's theme (Catppuccin Mocha).
var (
	cAccent = lipgloss.Color("4") // blue
	cPink   = lipgloss.Color("5") // mauve/pink
	cOK     = lipgloss.Color("2") // green
	cBad    = lipgloss.Color("1") // red
	cMuted  = lipgloss.Color("8") // overlay / bright-black
	cBase   = lipgloss.Color("0") // base

	stTitle    = lipgloss.NewStyle().Foreground(cPink).Bold(true)
	stPanel    = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cMuted).Padding(0, 1)
	stLabel    = lipgloss.NewStyle().Foreground(lipgloss.Color("7"))
	stValue    = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	stSelLabel = lipgloss.NewStyle().Foreground(cBase).Background(cAccent).Bold(true)
	stSelValue = lipgloss.NewStyle().Foreground(cBase).Background(cAccent).Bold(true)
	stKey      = lipgloss.NewStyle().Foreground(cPink).Bold(true)
	stKeyDesc  = lipgloss.NewStyle().Foreground(cMuted)
	stOK       = lipgloss.NewStyle().Foreground(cOK).Bold(true)
	stBad      = lipgloss.NewStyle().Foreground(cBad).Bold(true)
)

type setting struct {
	label   string
	labels  []string // shown
	values  []string // passed to scanimage
	idx     int
}

func (s *setting) val() string   { return s.values[s.idx] }
func (s *setting) shown() string { return s.labels[s.idx] }
func (s *setting) next()         { s.idx = (s.idx + 1) % len(s.values) }
func (s *setting) prev()         { s.idx = (s.idx - 1 + len(s.values)) % len(s.values) }

type scanDoneMsg struct{ err string }

type model struct {
	dev      string
	settings []setting
	out      textinput.Model
	cursor   int // 0..len(settings)-1 = settings; len(settings) = output field
	spin     spinner.Model
	scanning bool
	result   string
	failed   bool
	quit     bool
}

func (m model) outRow() int { return len(m.settings) }

func initialModel() model {
	dev := findDevice()
	home, _ := os.UserHomeDir()
	ti := textinput.New()
	ti.SetValue(fmt.Sprintf("%s/scan-%s.pdf", home, time.Now().Format("20060102-150405")))
	ti.Prompt = ""
	ti.CharLimit = 200
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(cAccent)
	return model{
		dev: dev,
		out: ti,
		spin: sp,
		settings: []setting{
			{label: "Mode",
				labels: []string{"Color", "Gray", "Black & White", "Gray (diffusion)"},
				values: []string{"24bit Color[Fast]", "True Gray", "Black & White", "Gray[Error Diffusion]"}},
			{label: "Resolution",
				labels: []string{"150 dpi", "200 dpi", "300 dpi", "400 dpi", "600 dpi", "1200 dpi"},
				values: []string{"150", "200", "300", "400", "600", "1200"}, idx: 2},
			{label: "Sides",
				labels: []string{"Duplex (both sides)", "Single-sided"},
				values: []string{"duplex", "single"}},
			{label: "Format",
				labels: []string{"PDF", "PNG", "JPEG", "TIFF"},
				values: []string{"pdf", "png", "jpeg", "tiff"}},
		},
	}
}

func (m model) Init() tea.Cmd { return textinput.Blink }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if m.scanning {
			return m, nil
		}
		switch msg.String() {
		case "ctrl+c", "q", "esc":
			m.quit = true
			return m, tea.Quit
		case "up", "k":
			if m.cursor == m.outRow() { m.out.Blur() }
			if m.cursor > 0 { m.cursor-- }
			if m.cursor == m.outRow() { m.out.Focus() }
			return m, nil
		case "down", "j":
			if m.cursor == m.outRow() { m.out.Blur() }
			if m.cursor < m.outRow() { m.cursor++ }
			if m.cursor == m.outRow() { return m, m.out.Focus() }
			return m, nil
		case "left", "h":
			if m.cursor < len(m.settings) { m.settings[m.cursor].prev() }
			return m, nil
		case "right", "l":
			if m.cursor < len(m.settings) { m.settings[m.cursor].next() }
			return m, nil
		case "s":
			if m.dev == "" { return m, nil }
			m.scanning = true
			return m, tea.Batch(m.spin.Tick, m.runScan())
		}
		if m.cursor == m.outRow() {
			var cmd tea.Cmd
			m.out, cmd = m.out.Update(msg)
			return m, cmd
		}
	case scanDoneMsg:
		m.scanning = false
		if msg.err != "" {
			m.failed, m.result = true, msg.err
		} else {
			m.failed, m.result = false, "Saved: "+m.out.Value()
		}
		return m, nil
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m model) runScan() tea.Cmd {
	dev := m.dev
	mode := m.settings[0].val()
	res := m.settings[1].val()
	sides := m.settings[2].val()
	format := m.settings[3].val()
	out := m.out.Value()
	return func() tea.Msg {
		src := "Automatic Document Feeder(left aligned)"
		if sides == "duplex" {
			src = "Automatic Document Feeder(left aligned,Duplex)"
		}
		var cmd *exec.Cmd
		if format == "pdf" {
			cmd = exec.Command("brscan-pdf", out)
			cmd.Env = append(os.Environ(), "SCAN_MODE="+mode, "SCAN_DPI="+res)
			if sides == "duplex" {
				cmd.Env = append(cmd.Env, "SCAN_DUPLEX=1")
			}
		} else {
			cmd = exec.Command("brscan", "-d", dev, "--source", src, "--mode", mode,
				"--resolution", res, "--format="+format, "-o", out)
		}
		if b, err := cmd.CombinedOutput(); err != nil {
			return scanDoneMsg{err: lastLine(string(b))}
		}
		return scanDoneMsg{}
	}
}

func (m model) View() string {
	var b strings.Builder
	// header
	status := stOK.Render("● connected")
	if m.dev == "" {
		status = stBad.Render("● not found")
	}
	b.WriteString("  " + stTitle.Render("󰚫  Brother DS-740D") + "   " + status + "\n\n")

	// settings panel
	var rows []string
	for i, s := range m.settings {
		label := stLabel.Render(fmt.Sprintf(" %-12s", s.label))
		value := stValue.Render("‹ " + s.shown() + " ›")
		if i == m.cursor {
			label = stSelLabel.Render(fmt.Sprintf(" %-12s", s.label))
			value = stSelValue.Render("‹ " + s.shown() + " ›")
		}
		rows = append(rows, label+"  "+value)
	}
	// output row
	olabel := stLabel.Render(" Save as")
	if m.cursor == m.outRow() {
		olabel = stSelLabel.Render(" Save as     ")
	}
	rows = append(rows, olabel+"  "+stValue.Render(m.out.View()))
	panel := stPanel.Width(60).Render(strings.Join(rows, "\n"))
	b.WriteString(panel + "\n")

	// status line / result
	switch {
	case m.scanning:
		b.WriteString("\n  " + m.spin.View() + stValue.Render(" Scanning… feed the pages") + "\n")
	case m.result != "" && m.failed:
		b.WriteString("\n  " + stBad.Render("✗ "+m.result) + "\n")
	case m.result != "":
		b.WriteString("\n  " + stOK.Render("✓ "+m.result) + "\n")
	default:
		b.WriteString("\n")
	}

	// keybar
	key := func(k, d string) string { return stKey.Render(k) + " " + stKeyDesc.Render(d) }
	bar := strings.Join([]string{
		key("↑/↓", "move"), key("←/→", "change"), key("s", "scan"), key("q", "quit"),
	}, stKeyDesc.Render("  •  "))
	b.WriteString("\n  " + bar + "\n")
	return b.String()
}

func findDevice() string {
	out, _ := exec.Command("brscan", "-L").CombinedOutput()
	return regexp.MustCompile(`brother5:[^' ]+`).FindString(string(out))
}

func lastLine(s string) string {
	f := strings.Fields(strings.TrimSpace(s))
	_ = f
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

func main() {
	if _, err := tea.NewProgram(initialModel()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
