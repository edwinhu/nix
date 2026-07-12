// brscan-tui — full-screen scan form for the Brother DS-740D (charmbracelet/huh).
// All options visible at once; arrow between fields, toggle/select inline, then
// scan. Shells out to the `brscan` / `brscan-pdf` wrappers (put on PATH by the
// nix makeWrapper in default.nix).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/huh/spinner"
	"github.com/charmbracelet/lipgloss"
)

var (
	red   = lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
	green = lipgloss.NewStyle().Foreground(lipgloss.Color("82"))
)

func findDevice() string {
	out, _ := exec.Command("brscan", "-L").CombinedOutput()
	return regexp.MustCompile(`brother5:[^' ]+`).FindString(string(out))
}

func main() {
	dev := findDevice()
	if dev == "" {
		fmt.Println(red.Render("✗ DS-740D not found — wake it (unplug/replug) and retry."))
		os.Exit(1)
	}

	home, _ := os.UserHomeDir()
	mode := "24bit Color[Fast]"
	res := "300"
	sides := "duplex"
	format := "pdf"
	output := fmt.Sprintf("%s/scan-%s.pdf", home, time.Now().Format("20060102-150405"))
	scan := true

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewNote().Title("Brother DS-740D — Scan"),
			huh.NewSelect[string]().Title("Mode").Value(&mode).Options(
				huh.NewOption("Color", "24bit Color[Fast]"),
				huh.NewOption("Gray", "True Gray"),
				huh.NewOption("Black & White", "Black & White"),
				huh.NewOption("Gray (error diffusion)", "Gray[Error Diffusion]"),
			),
			huh.NewSelect[string]().Title("Resolution (dpi)").Value(&res).
				Options(huh.NewOptions("150", "200", "300", "400", "600", "1200")...),
			huh.NewSelect[string]().Title("Sides").Value(&sides).Options(
				huh.NewOption("Duplex (both sides)", "duplex"),
				huh.NewOption("Single-sided", "single"),
			),
			huh.NewSelect[string]().Title("Format").Value(&format).Options(
				huh.NewOption("PDF", "pdf"),
				huh.NewOption("PNG", "png"),
				huh.NewOption("JPEG", "jpeg"),
				huh.NewOption("TIFF", "tiff"),
			),
			huh.NewInput().Title("Save as").Value(&output),
			huh.NewConfirm().Title("Ready?").Affirmative("Scan").Negative("Cancel").Value(&scan),
		),
	).WithTheme(huh.ThemeCharm())

	if err := form.Run(); err != nil || !scan {
		os.Exit(1)
	}

	var scanErr error
	_ = spinner.New().Title("Scanning… (feed the pages)").Action(func() {
		scanErr = runScan(dev, mode, res, sides, format, &output)
	}).Run()

	if scanErr != nil {
		fmt.Println(red.Render("✗ " + scanErr.Error()))
		os.Exit(1)
	}
	fmt.Println(green.Render("✓ Saved: " + output))
}

func runScan(dev, mode, res, sides, format string, output *string) error {
	src := "Automatic Document Feeder(left aligned)"
	if sides == "duplex" {
		src = "Automatic Document Feeder(left aligned,Duplex)"
	}
	if format == "pdf" {
		cmd := exec.Command("brscan-pdf", *output)
		cmd.Env = append(os.Environ(), "SCAN_MODE="+mode, "SCAN_DPI="+res)
		if sides == "duplex" {
			cmd.Env = append(cmd.Env, "SCAN_DUPLEX=1")
		}
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("%s", strings.TrimSpace(string(out)))
		}
		return nil
	}
	cmd := exec.Command("brscan", "-d", dev, "--source", src, "--mode", mode,
		"--resolution", res, "--format="+format, "-o", *output)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return nil
}
