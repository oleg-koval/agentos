package main

import (
	"agentos/core/internal/hardware"
	"agentos/core/internal/recovery"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func recoveryFixture() recovery.State {
	return recovery.State{
		Schema:      recovery.Schema,
		Status:      recovery.StatusReady,
		CurrentRoot: "@",
		NextBoot:    recovery.NextBootNormal,
		Points: []recovery.RecoveryPoint{
			{ID: "pre-pacman-20260907-100000", BootSafe: true, Created: "2026-09-07T10:00:00Z"},
			{ID: "pre-pacman-20260907-090000", BootSafe: false, Created: "2026-09-07T09:00:00Z"},
		},
	}
}

func TestParseRecoveryArgsRequiresExplicitConfirmation(t *testing.T) {
	for _, args := range [][]string{nil, {"--json"}, {"stage", "pre-pacman-20260907-100000", "--confirm"}, {"stage", "pre-pacman-20260907-100000", "--confirm", "--json"}, {"cancel", "--confirm"}, {"cancel", "--confirm", "--json"}} {
		if _, err := parseRecoveryArgs(args); err != nil {
			t.Fatalf("args=%q: %v", args, err)
		}
	}
	for _, args := range [][]string{{"stage"}, {"stage", "../../etc", "--confirm"}, {"stage", "pre-pacman-20260907-100000"}, {"cancel"}, {"cleanup", "--confirm"}} {
		if _, err := parseRecoveryArgs(args); err == nil {
			t.Fatalf("args=%q accepted", args)
		}
	}
}

func TestRenderRecoveryJSONUsesStableSchema(t *testing.T) {
	encoded, err := renderRecovery(recoveryFixture(), true)
	if err != nil {
		t.Fatal(err)
	}
	var state recovery.State
	if json.Unmarshal(encoded, &state) != nil || state.Schema != recovery.Schema || len(state.Points) != 2 {
		t.Fatalf("encoded=%s", encoded)
	}
}

func TestRecoveryStageAllowsOnlyCollectedBootSafePoint(t *testing.T) {
	originalCollect, originalEUID, originalRun := collectRecoveryState, recoveryEUID, runRecoveryMutation
	t.Cleanup(func() {
		collectRecoveryState, recoveryEUID, runRecoveryMutation = originalCollect, originalEUID, originalRun
	})
	collectRecoveryState = recoveryFixture
	recoveryEUID = func() int { return 0 }
	var calls [][]string
	runRecoveryMutation = func(args ...string) error {
		calls = append(calls, append([]string(nil), args...))
		return nil
	}
	if err := recoveryCommand([]string{"stage", "pre-pacman-20260907-100000", "--confirm", "--json"}); err != nil {
		t.Fatal(err)
	}
	if want := [][]string{{"stage", "pre-pacman-20260907-100000"}}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("calls=%q want %q", calls, want)
	}
	if err := recoveryCommand([]string{"stage", "pre-pacman-20260907-090000", "--confirm"}); err == nil || !strings.Contains(err.Error(), "boot-safe") {
		t.Fatalf("root-only err=%v", err)
	}
}

func TestRecoveryCancelRequiresStagedStateAndRoot(t *testing.T) {
	originalCollect, originalEUID, originalRun := collectRecoveryState, recoveryEUID, runRecoveryMutation
	t.Cleanup(func() {
		collectRecoveryState, recoveryEUID, runRecoveryMutation = originalCollect, originalEUID, originalRun
	})
	state := recoveryFixture()
	collectRecoveryState = func() recovery.State { return state }
	recoveryEUID = func() int { return 0 }
	runRecoveryMutation = func(args ...string) error { return nil }
	if err := recoveryCommand([]string{"cancel", "--confirm"}); err == nil || !strings.Contains(err.Error(), "no rollback") {
		t.Fatalf("unstaged err=%v", err)
	}
	state.Staged = &recovery.Staged{SourceID: "pre-pacman-20260907-100000", TargetSubvolume: "@rollback-20260907-110000"}
	recoveryEUID = func() int { return 1000 }
	if err := recoveryCommand([]string{"cancel", "--confirm"}); err == nil || !strings.Contains(err.Error(), "requires sudo") {
		t.Fatalf("root err=%v", err)
	}
}

func TestMaintenanceRecoveryActionsReflectStructuredState(t *testing.T) {
	originalHardware, originalRecovery := collectHardwareState, collectRecoveryState
	t.Cleanup(func() { collectHardwareState, collectRecoveryState = originalHardware, originalRecovery })
	collectHardwareState = func() hardware.State { return hardware.State{Role: "physical"} }
	state := recoveryFixture()
	collectRecoveryState = func() recovery.State { return state }
	maintenance := maintenanceState()
	if !maintenance.Recovery.Available || !maintenance.Actions[6].Available || maintenance.Actions[7].Available {
		t.Fatalf("maintenance=%#v", maintenance)
	}
	state.Staged = &recovery.Staged{SourceID: state.Points[0].ID, TargetSubvolume: "@rollback-20260907-110000"}
	maintenance = maintenanceState()
	if maintenance.Actions[6].Available || !maintenance.Actions[7].Available {
		t.Fatalf("maintenance=%#v", maintenance)
	}
}
