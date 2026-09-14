package main

import (
	"agentos/core/internal/maintenance"
	"sync"
	"time"
)

const maintenanceLaunchVisibility = 30 * time.Second

type maintenanceLaunchTracker struct {
	mu       sync.Mutex
	now      func() time.Time
	launched map[string]time.Time
}

func newMaintenanceLaunchTracker(now func() time.Time) *maintenanceLaunchTracker {
	return &maintenanceLaunchTracker{now: now, launched: map[string]time.Time{}}
}

func maintenanceOperationForAction(action string) string {
	switch action {
	case "update-check", "update-apply":
		return "update"
	case "migration-apply-user":
		return "migrations"
	case "firmware-enable", "firmware-check", "firmware-apply":
		return "hardware"
	case "recovery-stage", "recovery-cancel":
		return "recovery"
	default:
		return ""
	}
}

func (tracker *maintenanceLaunchTracker) Record(action string) {
	operation := maintenanceOperationForAction(action)
	if operation == "" {
		return
	}
	tracker.mu.Lock()
	tracker.launched[operation] = tracker.now()
	tracker.mu.Unlock()
}

func (tracker *maintenanceLaunchTracker) Apply(state maintenance.State) maintenance.State {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	now := tracker.now()
	for operation, launchedAt := range tracker.launched {
		age := now.Sub(launchedAt)
		if age < 0 || age > maintenanceLaunchVisibility {
			delete(tracker.launched, operation)
			continue
		}
		var target *maintenance.Operation
		switch operation {
		case "update":
			target = &state.Update
		case "migrations":
			target = &state.Migrations
		case "hardware":
			target = &state.Hardware
		case "recovery":
			target = &state.Recovery
		}
		if target != nil && target.Available {
			target.Status = maintenance.StatusLaunched
		}
	}
	return state
}

func (tracker *maintenanceLaunchTracker) Reset() {
	tracker.mu.Lock()
	tracker.launched = map[string]time.Time{}
	tracker.mu.Unlock()
}

var maintenanceLaunches = newMaintenanceLaunchTracker(time.Now)
