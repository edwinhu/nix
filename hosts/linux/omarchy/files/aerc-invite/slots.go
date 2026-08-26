// Offerable slots: morgen's free/busy, narrowed by the rules the
// calendar-availability skill states and `morgen calendar free` does not know.
//
// morgen returns UTC and applies no working hours, so a quiet night comes back
// as one 15h30m block. Everything below runs in LOCAL time.
package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// The skill's rules, in one place so they are auditable against it.
const (
	dayStartHour = 10 // "Default window 10 AM-4 PM"
	dayEndHour   = 16
	prepBuffer   = time.Hour // "the hour BEFORE any teaching commitment is ALSO blocked"
)

// Calendars that are not mine to offer. From the user's CLAUDE.md.
var excludedCalendars = []string{"Family", "Natalie", "rjj6@nyu.edu", "holiday", "birthday"}

// Teaching commitments earn a prep buffer. The marker is the `Teaching`
// Outlook CATEGORY, set on every class session (78 backfilled 2026-08-26).
// It is a dedicated field, so nothing else can collide with it, and it
// separates the class from a student meeting whose title merely contains the
// course name.
//
// morgen DOES return categories -- it omits the key when the array is empty,
// which is what made it look absent before any were set.
//
// The tag and the title list stay as fallbacks: Gmail has no categories at
// all, so a personal-calendar commitment can only be matched that way.
const teachingCategory = "Teaching"

const teachingListPath = ".config/aerc/teaching-titles"

var defaultTeaching = []string{"Securities Regulation", "Corporations"}

var teachingTag = regexp.MustCompile(`(?i)#teaching\b`)

func teachingTitles() map[string]bool {
	out := map[string]bool{}
	for _, t := range defaultTeaching {
		out[strings.ToLower(t)] = true
	}
	b, err := os.ReadFile(filepath.Join(os.Getenv("HOME"), teachingListPath))
	if err != nil {
		return out
	}
	out = map[string]bool{}
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		out[strings.ToLower(l)] = true
	}
	return out
}

func isTeaching(title, description string, categories map[string]bool) bool {
	for c, on := range categories {
		if on && strings.EqualFold(c, teachingCategory) {
			return true
		}
	}
	if teachingTag.MatchString(description) {
		return true
	}
	return teachingTitles()[strings.ToLower(strings.TrimSpace(title))]
}

// Scheduling frames, not real events -- they can be booked over.
var routineRe = regexp.MustCompile(`#morgen-routine`)

type Span struct{ Start, End time.Time }

type mEvent struct {
	Title           string `json:"title"`
	Start           string `json:"start"`
	Duration        string `json:"duration"`
	TimeZone        string `json:"timeZone"`
	ShowWithoutTime bool   `json:"showWithoutTime"`
	Description     string `json:"description"`
	// JMAP-style SET, not an array: morgen returns {"Teaching": true}.
	Categories     map[string]bool `json:"categories"`
	CalendarName   string          `json:"calendarName"`
	FreeBusyStatus string          `json:"freeBusyStatus"`
}

func excluded(cal string) bool {
	for _, x := range excludedCalendars {
		if strings.Contains(strings.ToLower(cal), strings.ToLower(x)) {
			return true
		}
	}
	return false
}

// busySpans returns everything that blocks a booking, prep buffers included.
func busySpans(from, to time.Time, loc *time.Location) ([]Span, error) {
	out, err := exec.Command("morgen", "calendar", "events",
		"--start", from.Format("2006-01-02"),
		"--end", to.AddDate(0, 0, 1).Format("2006-01-02"), "--json").Output()
	if err != nil {
		return nil, err
	}
	var evs []mEvent
	if err := json.Unmarshal(out, &evs); err != nil {
		return nil, err
	}
	var spans []Span
	for _, e := range evs {
		if e.ShowWithoutTime || excluded(e.CalendarName) || routineRe.MatchString(e.Description) {
			continue
		}
		if strings.EqualFold(e.FreeBusyStatus, "free") {
			continue // marked free by the organiser; not a conflict
		}
		st, err := time.ParseInLocation("2006-01-02T15:04:05", e.Start, loc)
		if err != nil {
			continue
		}
		d := parseDuration(e.Duration)
		s := Span{st, st.Add(d)}
		if isTeaching(e.Title, e.Description, e.Categories) {
			s.Start = s.Start.Add(-prepBuffer) // prep time is not offerable
		}
		spans = append(spans, s)
	}
	return spans, nil
}

// parseDuration handles the ISO-8601 subset morgen emits (PT1H15M, P1D).
func parseDuration(s string) time.Duration {
	m := regexp.MustCompile(`P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?`).FindStringSubmatch(s)
	if m == nil {
		return time.Hour
	}
	d := time.Duration(0)
	for i, unit := range []time.Duration{24 * time.Hour, time.Hour, time.Minute} {
		if m[i+1] != "" {
			n := 0
			for _, c := range m[i+1] {
				n = n*10 + int(c-'0')
			}
			d += time.Duration(n) * unit
		}
	}
	if d == 0 {
		d = time.Hour
	}
	return d
}

// Offerable walks each weekday's window and subtracts every busy span.
func Offerable(days int, dur time.Duration, loc *time.Location, now time.Time) ([]Span, error) {
	from := now
	to := now.AddDate(0, 0, days)
	busy, err := busySpans(from, to, loc)
	if err != nil {
		return nil, err
	}
	var free []Span
	for d := 0; d <= days; d++ {
		day := now.AddDate(0, 0, d)
		if day.Weekday() == time.Saturday || day.Weekday() == time.Sunday {
			continue
		}
		start := time.Date(day.Year(), day.Month(), day.Day(), dayStartHour, 0, 0, 0, loc)
		end := time.Date(day.Year(), day.Month(), day.Day(), dayEndHour, 0, 0, 0, loc)
		if start.Before(now) {
			start = now.Add(30 * time.Minute).Round(30 * time.Minute)
		}
		free = append(free, subtract(Span{start, end}, busy, dur)...)
	}
	return free, nil
}

// subtract removes busy spans from one window, keeping remainders >= dur.
func subtract(win Span, busy []Span, dur time.Duration) []Span {
	segs := []Span{win}
	for _, b := range busy {
		var next []Span
		for _, s := range segs {
			if b.End.Before(s.Start) || b.Start.After(s.End) {
				next = append(next, s)
				continue
			}
			if b.Start.After(s.Start) {
				next = append(next, Span{s.Start, b.Start})
			}
			if b.End.Before(s.End) {
				next = append(next, Span{b.End, s.End})
			}
		}
		segs = next
	}
	var out []Span
	for _, s := range segs {
		if s.End.Sub(s.Start) >= dur {
			out = append(out, s)
		}
	}
	return out
}
