// morgen: which calendars can be written to, and writing one event.
package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

type Calendar struct {
	ID    string
	Name  string
	Owner string // the address that owns it -- how an aerc account picks one
	Label string
}

// Calendars lists the writable DEFAULT calendar of every connected account.
// isDefault is the filter that drops shared, holiday and birthday calendars
// without naming any of them.
func Calendars() ([]Calendar, error) {
	out, err := exec.Command("morgen", "calendar").Output()
	if err != nil {
		return nil, fmt.Errorf("morgen calendar: %w", err)
	}
	var cals []Calendar
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "{") {
			continue
		}
		var c struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			BaseID    string `json:"baseId"`
			IsDefault bool   `json:"isDefault"`
			OwnedBy   struct {
				Email string `json:"email"`
			} `json:"ownedBy"`
			MyRights struct {
				MayWriteAll bool `json:"mayWriteAll"`
				MayWriteOwn bool `json:"mayWriteOwn"`
			} `json:"myRights"`
		}
		if json.Unmarshal([]byte(line), &c) != nil {
			continue
		}
		if !c.IsDefault || !(c.MyRights.MayWriteAll || c.MyRights.MayWriteOwn) {
			continue
		}
		owner := c.OwnedBy.Email
		if owner == "" && strings.Contains(c.BaseID, "@") {
			owner = c.BaseID
		}
		label := c.Name
		if owner != "" {
			label = fmt.Sprintf("%s (%s)", c.Name, owner)
		}
		cals = append(cals, Calendar{ID: c.ID, Name: c.Name,
			Owner: strings.ToLower(owner), Label: label})
	}
	if len(cals) == 0 {
		return nil, fmt.Errorf("no writable default calendar -- run `morgen auth`")
	}
	return cals, nil
}

func (f Form) createArgs() []string {
	args := []string{"calendar", "create",
		"--calendar-id", f.Calendar().ID,
		"--title", f.Get(fTitle),
		"--timezone", f.Zone(),
	}
	if f.AllDay() {
		args = append(args, "--start", f.Get(fDate), "--all-day", "--duration", "P1D")
	} else {
		args = append(args,
			"--start", f.Get(fDate)+"T"+f.Get(fStart)+":00",
			"--end", f.Get(fDate)+"T"+f.Get(fEnd)+":00")
	}
	if v := f.Get(fLocation); v != "" {
		args = append(args, "--location", v)
	}
	if v := f.Attendees(); len(v) > 0 {
		args = append(args, "--attendees", strings.Join(v, ","))
	}
	if v := f.Get(fAlerts); v != "" {
		args = append(args, "--alert", v)
	}

	var parts []string
	if v := f.Get(fNotes); v != "" {
		parts = append(parts, v)
	}
	// A link the mail supplied still belongs in the notes when a physical room
	// took the location field.
	if f.conf != "" && f.conf != f.Get(fLocation) {
		parts = append(parts, "Join: "+f.conf)
	}
	if f.mail.From != "" {
		parts = append(parts, "From: "+f.mail.From)
	}
	if f.mail.Subject != "" {
		parts = append(parts, "Subject: "+f.mail.Subject)
	}
	return append(args, "--description", strings.Join(parts, "\n\n"))
}

func (f Form) Create() error {
	cmd := exec.Command("morgen", f.createArgs()...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("%s", clip(lastLine(msg), 300))
	}
	return nil
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}
