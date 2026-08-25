// Gemini extraction. The JSON shape is FORCED by responseSchema +
// responseMimeType, which constrain decoding -- not asked for in the prompt.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const bodyLimit = 6000

type Event struct {
	IsEvent         bool     `json:"is_event"`
	Title           string   `json:"title"`
	StartDate       string   `json:"start_date"`
	StartTime       string   `json:"start_time"`
	EndTime         string   `json:"end_time"`
	AllDay          bool     `json:"all_day"`
	Timezone        string   `json:"timezone"`
	Location        string   `json:"location"`
	ConferencingURL string   `json:"conferencing_url"`
	Attendees       []string `json:"attendees"`
	Notes           string   `json:"notes"`
}

var schema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"is_event":         map[string]any{"type": "boolean"},
		"title":            map[string]any{"type": "string"},
		"start_date":       map[string]any{"type": "string"},
		"start_time":       map[string]any{"type": "string"},
		"end_time":         map[string]any{"type": "string"},
		"all_day":          map[string]any{"type": "boolean"},
		"timezone":         map[string]any{"type": "string"},
		"location":         map[string]any{"type": "string"},
		"conferencing_url": map[string]any{"type": "string"},
		"attendees":        map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
		"notes":            map[string]any{"type": "string"},
	},
	"required": []string{"is_event", "title", "start_date", "start_time", "end_time",
		"all_day", "timezone", "location", "conferencing_url", "attendees", "notes"},
}

const promptTmpl = `Extract a single calendar event from this email. Today is %s (%s); the reader's timezone is %s. The reader is %s.

Rules:
- is_event: false if the mail proposes no datable meeting, deadline or appointment.
- Resolve relative dates ("next Tuesday", "tomorrow") against the mail's own Date header, which is when the sender wrote them -- not against today. Only fall back to today's date when the mail carries no Date header.
- start_date is YYYY-MM-DD. start_time/end_time are 24h HH:MM, or "" when all_day.
- If only a start is given, leave end_time "" (the caller defaults to 15 minutes). Only set end_time when the mail states an end or a duration.
- timezone: an IANA name ONLY if the mail explicitly states a zone, or a city whose zone differs from the reader's. Otherwise "%s".
- location: a physical location only. Leave "" for a virtual meeting.
- conferencing_url: a Zoom/Meet/Teams URL that appears IN the mail. Never invent one.
- attendees: email addresses of real human participants named in the mail. Exclude the reader, no-reply/automated senders and mailing lists.
- title: how the reader would name it on their own calendar. No "Re:"/"Fwd:".
- notes: one or two sentences of context. No greetings.

--- HEADERS
%s
--- BODY
%s
`

// apiKey: the environment first, then the agenix file the login shell would
// have read -- aerc is often started from a graphical session that never
// sourced it.
func apiKey() string {
	for _, k := range []string{"GOOGLE_API_KEY", "GEMINI_API_KEY"} {
		if v := strings.TrimSpace(os.Getenv(k)); v != "" {
			return v
		}
	}
	path := os.Getenv("GEMINI_API_KEY_FILE")
	if path == "" {
		rt := os.Getenv("XDG_RUNTIME_DIR")
		if rt == "" {
			rt = fmt.Sprintf("/run/user/%d", os.Getuid())
		}
		path = filepath.Join(rt, "agenix", "gemini-api-key")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func Extract(m Mail, tz, me, model string) (Event, error) {
	key := apiKey()
	if key == "" {
		return Event{}, fmt.Errorf("no Gemini API key (GOOGLE_API_KEY / agenix gemini-api-key)")
	}

	body := m.Body
	if len(body) > bodyLimit {
		body = body[:bodyLimit]
	}
	hdrs := m.headerBlock()
	if m.DeliveredTo != "" {
		hdrs += "\nDelivered-To: " + m.DeliveredTo
	}
	now := time.Now()
	prompt := fmt.Sprintf(promptTmpl, now.Format("2006-01-02"), now.Format("Monday"),
		tz, me, tz, hdrs, body)

	payload, _ := json.Marshal(map[string]any{
		"contents": []any{map[string]any{"parts": []any{map[string]any{"text": prompt}}}},
		"generationConfig": map[string]any{
			"responseMimeType": "application/json",
			"responseSchema":   schema,
			"temperature":      0,
			"thinkingConfig":   map[string]any{"thinkingLevel": "low"},
		},
	})

	url := "https://generativelanguage.googleapis.com/v1beta/models/" + model + ":generateContent"
	req, err := http.NewRequest("POST", url, bytes.NewReader(payload))
	if err != nil {
		return Event{}, err
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-goog-api-key", key)

	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return Event{}, fmt.Errorf("%s: %w", model, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return Event{}, fmt.Errorf("%s: HTTP %d %s", model, resp.StatusCode, clip(string(raw), 300))
	}

	var envelope struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil ||
		len(envelope.Candidates) == 0 || len(envelope.Candidates[0].Content.Parts) == 0 {
		return Event{}, fmt.Errorf("%s returned no usable JSON: %s", model, clip(string(raw), 300))
	}
	var ev Event
	if err := json.Unmarshal([]byte(envelope.Candidates[0].Content.Parts[0].Text), &ev); err != nil {
		return Event{}, fmt.Errorf("%s: %w", model, err)
	}
	return ev, nil
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
