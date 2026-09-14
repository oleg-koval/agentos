package main

import (
	"agentos/core/internal/hardware"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func hardwareFixture() hardware.State {
	return hardware.State{
		Schema:  hardware.Schema,
		Role:    "physical",
		Overall: hardware.StatusWarning,
		Checks: []hardware.Check{
			{ID: "architecture", Status: hardware.StatusReady, Detail: "x86_64"},
			{ID: "firmware-support", Status: hardware.StatusUnavailable, Detail: "fwupd is not installed; enable on demand"},
		},
	}
}

func TestParseHardwareArgs(t *testing.T) {
	for _, args := range [][]string{nil, {"--json"}, {"firmware-enable"}, {"firmware-check"}, {"firmware-check", "--json"}, {"firmware-apply", "--confirm"}, {"firmware-apply", "--confirm", "--json"}} {
		if _, err := parseHardwareArgs(args); err != nil {
			t.Fatalf("args=%q: %v", args, err)
		}
	}
	for _, args := range [][]string{{"--apply"}, {"--json", "extra"}, {"firmware-apply"}, {"firmware-apply", "--json"}, {"firmware-enable", "--json"}, {"firmware-check", "extra"}} {
		if _, err := parseHardwareArgs(args); err == nil {
			t.Fatalf("args=%q accepted", args)
		}
	}
}

func TestParseHardwareArgsKeepsApplyConfirmationExplicit(t *testing.T) {
	options, err := parseHardwareArgs([]string{"firmware-apply", "--confirm", "--json"})
	if err != nil {
		t.Fatal(err)
	}
	if options.Operation != "firmware-apply" || !options.Confirmed || !options.JSON {
		t.Fatalf("options=%#v", options)
	}
}

func TestRenderHardwareJSON(t *testing.T) {
	encoded, err := renderHardware(hardwareFixture(), true)
	if err != nil {
		t.Fatal(err)
	}
	var state hardware.State
	if json.Unmarshal(encoded, &state) != nil || state.Schema != hardware.Schema || state.Overall != hardware.StatusWarning {
		t.Fatalf("encoded=%s", encoded)
	}
}

func TestRenderHardwareTextIncludesExplicitStatus(t *testing.T) {
	encoded, err := renderHardware(hardwareFixture(), false)
	if err != nil {
		t.Fatal(err)
	}
	text := string(encoded)
	for _, expected := range []string{"Hardware readiness: warning", "Machine role: physical", "architecture: ready", "firmware-support: unavailable", "enable on demand"} {
		if !strings.Contains(text, expected) {
			t.Fatalf("output missing %q:\n%s", expected, text)
		}
	}
}

func TestSaveFirmwareResultIsPrivateAndReloadable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "firmware-result.json")
	record := hardware.FirmwareResult{Status: hardware.FirmwareResultRebootRequired, AttemptedAt: "2026-09-07T12:00:00Z", RebootKnown: true, RebootRequired: true}
	if err := saveFirmwareResult(path, record); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var saved hardware.FirmwareResult
	if json.Unmarshal(data, &saved) != nil || saved.Schema != hardware.FirmwareResultSchema || saved.Status != hardware.FirmwareResultRebootRequired || !saved.RebootRequired {
		t.Fatalf("saved=%s", data)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode=%o want 600", info.Mode().Perm())
	}
}

func TestFirmwareApplyRequiresRootAfterExplicitConfirmation(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root guard requires an unprivileged test process")
	}
	err := hardwareCommand([]string{"firmware-apply", "--confirm"})
	if err == nil || !strings.Contains(err.Error(), "requires sudo") {
		t.Fatalf("err=%v", err)
	}
}
