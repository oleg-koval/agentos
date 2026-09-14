package maintenance

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestNewStateExposesStableOperationsAndActions(t *testing.T) {
	state := NewState(Availability{Update: true})

	if state.Schema != Schema {
		t.Fatalf("schema=%q want %q", state.Schema, Schema)
	}
	if state.Update.Status != StatusReady || !state.Update.Available {
		t.Fatalf("update=%#v want ready and available", state.Update)
	}
	for name, operation := range map[string]Operation{
		"migrations": state.Migrations,
		"hardware":   state.Hardware,
		"recovery":   state.Recovery,
	} {
		if operation.Status != StatusUnavailable || operation.Available {
			t.Fatalf("%s=%#v want unavailable", name, operation)
		}
	}

	wantIDs := []string{
		"update-check",
		"update-apply",
		"migration-apply-user",
		"firmware-enable",
		"firmware-check",
		"firmware-apply",
		"recovery-stage",
		"recovery-cancel",
	}
	gotIDs := make([]string, 0, len(state.Actions))
	for _, action := range state.Actions {
		gotIDs = append(gotIDs, action.ID)
		if action.Parameters == nil {
			t.Fatalf("action %q parameters must encode as an array", action.ID)
		}
	}
	if !reflect.DeepEqual(gotIDs, wantIDs) {
		t.Fatalf("action IDs=%v want %v", gotIDs, wantIDs)
	}
	if !state.Actions[1].Available || !state.Actions[1].RequiresAuth {
		t.Fatalf("update apply metadata=%#v", state.Actions[1])
	}
	if state.Actions[6].Available || !state.Actions[6].RequiresAuth ||
		!reflect.DeepEqual(state.Actions[6].Parameters, []string{"recovery_point_id"}) {
		t.Fatalf("recovery stage metadata=%#v", state.Actions[6])
	}

	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := json.Unmarshal(encoded, &object); err != nil {
		t.Fatal(err)
	}
	if _, ok := object["actions"].([]any); !ok {
		t.Fatalf("actions=%#v want JSON array", object["actions"])
	}
}

func TestMaintenanceStatusValuesAreStable(t *testing.T) {
	for _, status := range []Status{
		StatusUnavailable,
		StatusReady,
		StatusLaunched,
		StatusSucceeded,
		StatusFailed,
		StatusRebootRequired,
	} {
		if !ValidStatus(status) {
			t.Fatalf("status %q should be valid", status)
		}
	}
	if ValidStatus("running-away") {
		t.Fatal("unknown status should fail closed")
	}
}

func TestRecoveryActionsHaveIndependentAvailability(t *testing.T) {
	state := NewState(Availability{Recovery: true, RecoveryStage: true})
	if !state.Recovery.Available {
		t.Fatalf("recovery=%#v", state.Recovery)
	}
	if !state.Actions[6].Available || state.Actions[7].Available {
		t.Fatalf("actions=%#v", state.Actions[6:8])
	}
	state = NewState(Availability{Recovery: true, RecoveryCancel: true})
	if state.Actions[6].Available || !state.Actions[7].Available {
		t.Fatalf("actions=%#v", state.Actions[6:8])
	}
}
