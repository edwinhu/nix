// The form's data: fields, normalizing and validation. Kept apart from the
// view so what gets written to the calendar is readable on its own.
package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
)

type fieldID int

const (
	fTitle fieldID = iota
	fDate
	fStart
	fEnd
	fZone
	fLocation
	fAttendees
	fCalendar // a cycler, not a text input
	fAlerts
	fNotes
	fieldCount
)

type field struct {
	id          fieldID
	label       string
	placeholder string
	cycle       bool
}

var fields = []field{
	{fTitle, "Title", "", false},
	{fDate, "Date", "YYYY-MM-DD", false},
	{fStart, "Start", "HH:MM (blank = all day)", false},
	{fEnd, "End", "HH:MM", false},
	{fZone, "Zone", "", false},
	{fLocation, "Location", "none", false},
	{fAttendees, "Attendees", "comma-separated", false},
	{fCalendar, "Calendar", "", true},
	{fAlerts, "Alerts", "10m", false},
	{fNotes, "Notes", "", false},
}

type Form struct {
	inputs []textinput.Model
	cals   []Calendar
	calIdx int
	here   string // the reader's own timezone
	conf   string // conferencing url the mail supplied, if any
	mail   Mail
}

func NewForm(ev Event, m Mail, cals []Calendar, calIdx int, here string) Form {
	f := Form{inputs: make([]textinput.Model, fieldCount),
		cals: cals, calIdx: calIdx, here: here, conf: strings.TrimSpace(ev.ConferencingURL), mail: m}

	start := NormalizeTime(ev.StartTime)
	end := NormalizeTime(ev.EndTime)
	if start != "" && end == "" {
		end = PlusDefault(start)
	}
	zone := strings.TrimSpace(ev.Timezone)
	if zone == "" {
		zone = here
	}
	title := strings.TrimSpace(ev.Title)
	if title == "" {
		title = m.Subject
	}
	date := strings.TrimSpace(ev.StartDate)
	if date == "" {
		date = time.Now().Format("2006-01-02")
	}
	// The personal Zoom is the default room: a meeting with no room of its own
	// gets it, and a link the mail supplied always wins.
	location := strings.TrimSpace(ev.Location)
	if location == "" {
		location = f.conf
	}
	if location == "" {
		location = defaultZoom
	}

	values := map[fieldID]string{
		fTitle: title, fDate: date, fStart: start, fEnd: end, fZone: zone,
		fLocation: location, fAttendees: strings.Join(keepAddrs(ev.Attendees), ", "),
		fAlerts: "10m", fNotes: strings.TrimSpace(ev.Notes),
	}
	for _, fl := range fields {
		if fl.cycle {
			continue
		}
		ti := textinput.New()
		ti.Prompt = ""
		ti.CharLimit = 500
		ti.Placeholder = fl.placeholder
		ti.SetValue(values[fl.id])
		f.inputs[fl.id] = ti
	}
	return f
}

func (f Form) Get(id fieldID) string { return strings.TrimSpace(f.inputs[id].Value()) }
func (f Form) Calendar() Calendar    { return f.cals[f.calIdx] }
func (f Form) AllDay() bool          { return f.Get(fStart) == "" }
func (f Form) Zone() string {
	if z := f.Get(fZone); z != "" {
		return z
	}
	return f.here
}

func (f Form) Attendees() []string {
	return keepAddrs(strings.Split(f.Get(fAttendees), ","))
}

func keepAddrs(in []string) []string {
	var out []string
	for _, a := range in {
		if a = strings.TrimSpace(a); a != "" {
			out = append(out, a)
		}
	}
	return out
}

// Validate reports the first reason the form cannot be written, or "".
func (f Form) Validate() string {
	if f.Get(fTitle) == "" {
		return "Title is empty"
	}
	if _, err := time.Parse("2006-01-02", f.Get(fDate)); err != nil {
		return fmt.Sprintf("Date %q is not YYYY-MM-DD", f.Get(fDate))
	}
	if !f.AllDay() {
		start, err := time.Parse("15:04", f.Get(fStart))
		if err != nil {
			return fmt.Sprintf("Start %q is not HH:MM", f.Get(fStart))
		}
		end, err := time.Parse("15:04", f.Get(fEnd))
		if err != nil {
			return fmt.Sprintf("End %q is not HH:MM", f.Get(fEnd))
		}
		if !end.After(start) {
			return "End is not after Start"
		}
	}
	if _, err := time.LoadLocation(f.Zone()); err != nil {
		return fmt.Sprintf("Unknown timezone %q", f.Zone())
	}
	for _, a := range f.Attendees() {
		if !strings.Contains(a, "@") {
			return "Not an email address: " + a
		}
	}
	return ""
}

// LocalHint renders the start in the reader's own zone when the event is in a
// different one -- the case where a bare "2pm" is quietly the wrong 2pm.
func (f Form) LocalHint() string {
	if f.AllDay() || f.Zone() == f.here {
		return ""
	}
	loc, err := time.LoadLocation(f.Zone())
	if err != nil {
		return ""
	}
	here, err := time.LoadLocation(f.here)
	if err != nil {
		return ""
	}
	t, err := time.ParseInLocation("2006-01-02 15:04", f.Get(fDate)+" "+f.Get(fStart), loc)
	if err != nil {
		return ""
	}
	local := t.In(here)
	return fmt.Sprintf("%s %s your time",
		local.Format("Mon 3:04 PM"), shortZone(f.here))
}

func shortZone(tz string) string {
	parts := strings.Split(tz, "/")
	return strings.ReplaceAll(parts[len(parts)-1], "_", " ")
}

var (
	reAmPm  = regexp.MustCompile(`^(\d{1,2})[:.]?(\d{2})?\s*([ap])\.?m?\.?$`)
	re24    = regexp.MustCompile(`^(\d{1,2})[:.]?(\d{2})$`)
	reHour  = regexp.MustCompile(`^(\d{1,2})$`)
	reEmail = regexp.MustCompile(`[\w.+-]+@[\w.-]+`)
)

// NormalizeTime turns "2pm", "2:30 PM", "1430" and "14" into "14:30" form.
// Anything it does not recognise is handed back untouched so Validate can
// complain about it with the user's own text.
func NormalizeTime(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if m := reAmPm.FindStringSubmatch(strings.ToLower(v)); m != nil {
		h, _ := strconv.Atoi(m[1])
		min := m[2]
		if min == "" {
			min = "00"
		}
		if m[3] == "p" && h != 12 {
			h += 12
		}
		if m[3] == "a" && h == 12 {
			h = 0
		}
		return fmt.Sprintf("%02d:%s", h, min)
	}
	if m := re24.FindStringSubmatch(v); m != nil {
		h, _ := strconv.Atoi(m[1])
		return fmt.Sprintf("%02d:%s", h, m[2])
	}
	if m := reHour.FindStringSubmatch(v); m != nil {
		h, _ := strconv.Atoi(m[1])
		return fmt.Sprintf("%02d:00", h)
	}
	return v
}

// defaultDuration: what a start with no stated end becomes. Short on purpose --
// an hour blocks far more of the day than most mail actually asks for.
const defaultDuration = 15 * time.Minute

func PlusDefault(hhmm string) string {
	t, err := time.Parse("15:04", hhmm)
	if err != nil {
		return hhmm
	}
	return t.Add(defaultDuration).Format("15:04")
}
