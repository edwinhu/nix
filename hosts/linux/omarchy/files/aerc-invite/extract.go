// What is this correspondent asking for? Same forced-JSON contract as
// aerc-cal: responseSchema + responseMimeType, not a prompt asking for JSON.
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

type Ask struct {
	IsSchedulingRequest bool     `json:"is_scheduling_request"`
	PersonName          string   `json:"person_name"`
	DurationMinutes     int      `json:"duration_minutes"`
	WithinDays          int      `json:"within_days"`
	Topic               string   `json:"topic"`
	OtherHumans         []string `json:"other_humans"`
}

var askSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"is_scheduling_request": map[string]any{"type": "boolean"},
		"person_name":           map[string]any{"type": "string"},
		"duration_minutes":      map[string]any{"type": "integer"},
		"within_days":           map[string]any{"type": "integer"},
		"topic":                 map[string]any{"type": "string"},
		"other_humans":          map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
	},
	"required": []string{"is_scheduling_request", "person_name", "duration_minutes",
		"within_days", "topic", "other_humans"},
}

const askPrompt = `This email is being replied to with a booking link. Extract what the sender is asking for.

- is_scheduling_request: true if they want to meet, talk, or find a time. False for anything else.
- person_name: the sender's first name, for the meeting title. "" if unclear.
- duration_minutes: what they asked for; 30 if unstated. Round to 15/30/45/60.
- within_days: how far out to offer. "this week" 7, "next week" 14, unstated 10.
- topic: 3-6 words for the calendar title.
- other_humans: email addresses of OTHER real people on the thread besides the sender and the reader. Exclude no-reply and lists. This decides whether a 1:1 link is even appropriate.

--- HEADERS
%s
--- BODY
%s
`

func apiKey() string {
	for _, k := range []string{"GOOGLE_API_KEY", "GEMINI_API_KEY"} {
		if v := strings.TrimSpace(os.Getenv(k)); v != "" {
			return v
		}
	}
	rt := os.Getenv("XDG_RUNTIME_DIR")
	if rt == "" {
		rt = fmt.Sprintf("/run/user/%d", os.Getuid())
	}
	b, err := os.ReadFile(filepath.Join(rt, "agenix", "gemini-api-key"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func Extract(m Mail, model string) (Ask, error) {
	key := apiKey()
	if key == "" {
		return Ask{}, fmt.Errorf("no Gemini API key")
	}
	body := m.Body
	if len(body) > 6000 {
		body = body[:6000]
	}
	payload, _ := json.Marshal(map[string]any{
		"contents": []any{map[string]any{"parts": []any{map[string]any{
			"text": fmt.Sprintf(askPrompt, m.headerBlock(), body)}}}},
		"generationConfig": map[string]any{
			"responseMimeType": "application/json",
			"responseSchema":   askSchema,
			"temperature":      0,
			"thinkingConfig":   map[string]any{"thinkingLevel": "low"},
		},
	})
	req, _ := http.NewRequest("POST",
		"https://generativelanguage.googleapis.com/v1beta/models/"+model+":generateContent",
		bytes.NewReader(payload))
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-goog-api-key", key)
	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return Ask{}, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return Ask{}, fmt.Errorf("%s: HTTP %d %s", model, resp.StatusCode, clip(string(raw), 200))
	}
	var env struct {
		Candidates []struct {
			Content struct {
				Parts []struct{ Text string } `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
	}
	if json.Unmarshal(raw, &env) != nil || len(env.Candidates) == 0 || len(env.Candidates[0].Content.Parts) == 0 {
		return Ask{}, fmt.Errorf("no usable JSON from %s", model)
	}
	var a Ask
	if err := json.Unmarshal([]byte(env.Candidates[0].Content.Parts[0].Text), &a); err != nil {
		return Ask{}, err
	}
	return a, nil
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
