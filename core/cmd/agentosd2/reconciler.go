package main

import (
	"os"
	"sort"
	"strings"
	"time"
)

type reconciliationResult struct {
	bindings map[string]Session
	used     []bool
}

const agentStartBindingGrace = 2 * time.Minute
const staleWaitingSessionAge = 24 * time.Hour

func isFreshAgentStart(r *sessionRecord, now time.Time) bool {
	if r.Status != string(StateStarting) || r.PID > 1 || r.UpdatedAt == "" {
		return false
	}
	t, err := time.Parse(time.RFC3339, r.UpdatedAt)
	if err != nil {
		return false
	}
	age := now.Sub(t)
	return age >= 0 && age <= agentStartBindingGrace
}

func isStaleWaitingSession(r *sessionRecord, now time.Time) bool {
	if r.Status != string(StateWaiting) || r.PID > 1 || r.UpdatedAt == "" {
		return false
	}
	t, err := time.Parse(time.RFC3339Nano, r.UpdatedAt)
	return err == nil && now.Sub(t) > staleWaitingSessionAge
}

// reconcileRegistryWithProcesses keeps PID/CWD/runtime as observational data on
// authoritative sessions. Lifecycle events remain the source of truth. When a
// session previously tied to a PID loses that process, emit a terminal event
// exactly once instead of silently dropping the session.
func reconcileRegistryWithProcesses(home string) {
	reconcileRegistryWithLive(liveSessions(home))
}

func reconcileRegistryWithLive(live []Session) reconciliationResult {
	return reconcileRegistryWithLiveAt(live, time.Now())
}

func reconcileRegistryWithLiveAt(live []Session, now time.Time) reconciliationResult {
	result := reconciliationResult{bindings: map[string]Session{}, used: make([]bool, len(live))}
	exited := []Event{}

	mu.Lock()
	records := make([]*sessionRecord, 0, len(sessionsByID))
	for _, r := range sessionsByID {
		records = append(records, r)
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].UpdatedAt != records[j].UpdatedAt {
			return records[i].UpdatedAt > records[j].UpdatedAt
		}
		return records[i].ID < records[j].ID
	})

	for _, r := range records {
		if terminal(r.Status) {
			continue
		}
		if isStaleWaitingSession(r, now) {
			exited = append(exited, Event{Kind: "agent.lifecycle", Agent: r.Agent, Project: r.Project, Session: r.ID, Status: string(StateDone), Text: "stale WAITING session expired", Source: "process-reconciler"})
			r.PID = 0
			continue
		}
		best := -1
		for i, l := range live {
			if result.used[i] || l.Agent != r.Agent {
				continue
			}
			if r.PID > 1 {
				if l.PID != r.PID {
					continue
				}
			} else if r.Project != "" && r.Project != "workspace" && l.Project != r.Project && !(isFreshAgentStart(r, now) && l.Project == "workspace") {
				continue
			}
			best = i
			break
		}
		if best >= 0 {
			l := live[best]
			result.used[best] = true
			result.bindings[r.ID] = l
			r.PID, r.CWD, r.Seconds, r.Elapsed = l.PID, l.CWD, l.Seconds, l.Elapsed
			continue
		}
		if r.PID > 1 {
			exited = append(exited, Event{Kind: "agent.lifecycle", Agent: r.Agent, Project: r.Project, Session: r.ID, Status: string(StateDone), Text: "agent process exited", Source: "process-reconciler"})
			r.PID = 0
		}
	}
	persistSessionsLocked()
	mu.Unlock()

	for _, e := range exited {
		addTypedEvent(e)
	}
	return result
}

func init() {
	// Unit tests mutate the package-level registry deliberately. Do not let the
	// background production reconciler race those deterministic fixtures.
	if len(os.Args) > 0 && strings.HasSuffix(os.Args[0], ".test") { return }
	go func() {
		time.Sleep(2 * time.Second)
		home, _ := os.UserHomeDir()
		for {
			reconcileRegistryWithProcesses(home)
			time.Sleep(5 * time.Second)
		}
	}()
}
