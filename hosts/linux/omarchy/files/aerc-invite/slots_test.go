package main

import (
	"testing"
	"time"
	_ "time/tzdata"
)

func TestTeachingIsExactMatch(t *testing.T) {
	cases := map[string]bool{
		"Securities Regulation":                       true,
		"securities regulation":                       true,  // case-insensitive
		"Securities Regulation Exam Feedback - Rohan": false, // the 1:1, NOT a class
		"Corporations":                                true,
		"Daphnie - Busy":                              false,
		"Thursday Faculty Lunch 8/27":                 false,
	}
	for title, want := range cases {
		if got := isTeaching(title, "", nil); got != want {
			t.Errorf("isTeaching(%q) = %v, want %v", title, got, want)
		}
	}
}

func TestTagBeatsTitle(t *testing.T) {
	// An untitled-as-a-course event still counts when tagged.
	if !isTeaching("Sec Reg makeup session", "<p>room change</p> #teaching", nil) {
		t.Error("#teaching in the description should mark it as teaching")
	}
	// And the tag never fires on the lookalike 1:1 unless it is actually there.
	if isTeaching("Securities Regulation Exam Feedback - Rohan", "<p>30 min</p>", nil) {
		t.Error("untagged 1:1 must not be teaching")
	}
}

func TestCategoryIsAuthoritative(t *testing.T) {
	// The category marks a class whose title matches nothing.
	if !isTeaching("Makeup session", "", map[string]bool{"Teaching": true}) {
		t.Error("Teaching category should mark it")
	}
	// A category set to false is not a marker.
	if isTeaching("Makeup session", "", map[string]bool{"Teaching": false}) {
		t.Error("categories:{Teaching:false} must not mark it")
	}
	// The lookalike 1:1 carries no category and must stay unmarked... except the
	// title list still catches the exact course name, which is intended.
	if isTeaching("Securities Regulation Exam Feedback - Rohan", "", map[string]bool{"Meeting": true}) {
		t.Error("a non-Teaching category must not mark it")
	}
}

func TestPrepBufferOnlyBeforeAClass(t *testing.T) {
	loc, _ := time.LoadLocation("America/New_York")
	base := time.Date(2026, 9, 14, 0, 0, 0, 0, loc) // a Monday
	class := time.Date(2026, 9, 14, 13, 0, 0, 0, loc)
	win := Span{time.Date(2026, 9, 14, 10, 0, 0, 0, loc), time.Date(2026, 9, 14, 16, 0, 0, 0, loc)}
	_ = base
	// class 13:00-14:20 with the buffer blocks 12:00 onward
	busy := []Span{{class.Add(-prepBuffer), class.Add(80 * time.Minute)}}
	got := subtract(win, busy, 30*time.Minute)
	if len(got) != 2 || !got[0].End.Equal(class.Add(-prepBuffer)) {
		t.Fatalf("buffer not applied: %v", got)
	}
	if got[0].End.Hour() != 12 {
		t.Errorf("free should stop at 12:00, stopped %v", got[0].End)
	}
}
