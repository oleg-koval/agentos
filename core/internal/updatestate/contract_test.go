package updatestate

import (
	"encoding/json"
	"testing"
)

func TestRecordJSONUsesStableSchemaAndStatuses(t *testing.T) {
	record := Record{Schema: Schema, Status: StatusAvailable, Channel: "stable", CurrentVersion: "1.0", TargetVersion: "1.1", ArchPending: 2}
	data, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	var decoded Record
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Schema != Schema || decoded.Status != StatusAvailable || decoded.TargetVersion != "1.1" {
		t.Fatalf("record=%#v", decoded)
	}
	for _, status := range []Status{StatusNotChecked, StatusChecking, StatusUpToDate, StatusAvailable, StatusCheckFailed, StatusApplyFailed, StatusSucceeded, StatusRebootRequired} {
		if !ValidStatus(status) {
			t.Fatalf("status %q should be valid", status)
		}
	}
}
