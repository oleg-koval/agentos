package main

import (
	"agentos/core/internal/maintenance"
	"errors"
	"testing"
	"time"
)

func TestMaintenanceLaunchTrackerExposesThenExpiresLaunch(t *testing.T) {
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	tracker := newMaintenanceLaunchTracker(func() time.Time { return now })
	state := maintenance.NewState(maintenance.Availability{Update: true, Hardware: true})

	tracker.Record("update-apply")
	launched := tracker.Apply(state)
	if launched.Update.Status != maintenance.StatusLaunched {
		t.Fatalf("update status=%q want launched", launched.Update.Status)
	}
	if launched.Hardware.Status != maintenance.StatusReady {
		t.Fatalf("unrelated hardware status=%q", launched.Hardware.Status)
	}

	now = now.Add(maintenanceLaunchVisibility + time.Second)
	expired := tracker.Apply(state)
	if expired.Update.Status != maintenance.StatusReady {
		t.Fatalf("expired update status=%q want ready", expired.Update.Status)
	}
}

func TestMaintenanceLaunchTrackerIgnoresNonMaintenanceActions(t *testing.T) {
	tracker := newMaintenanceLaunchTracker(time.Now)
	state := maintenance.NewState(maintenance.Availability{Update: true})
	tracker.Record("support")
	if got := tracker.Apply(state).Update.Status; got != maintenance.StatusReady {
		t.Fatalf("update status=%q want ready", got)
	}
}

func TestMaintenanceActionRecordsOnlySuccessfulLaunch(t *testing.T) {
	originalGUI := maintenanceGUI
	maintenanceLaunches.Reset()
	t.Cleanup(func() {
		maintenanceGUI = originalGUI
		maintenanceLaunches.Reset()
	})
	state := maintenance.NewState(maintenance.Availability{Update: true})

	maintenanceGUI = func(string, ...string) error { return errors.New("launch failed") }
	if err := launchMaintenanceAction(Action{Name: "update-check"}); err == nil {
		t.Fatal("failed terminal launch should be reported")
	}
	if got := maintenanceLaunches.Apply(state).Update.Status; got != maintenance.StatusReady {
		t.Fatalf("failed launch status=%q want ready", got)
	}

	maintenanceGUI = func(string, ...string) error { return nil }
	if err := launchMaintenanceAction(Action{Name: "update-check"}); err != nil {
		t.Fatal(err)
	}
	if got := maintenanceLaunches.Apply(state).Update.Status; got != maintenance.StatusLaunched {
		t.Fatalf("successful launch status=%q want launched", got)
	}
}
