package main

import (
	"agentos/core/internal/hardware"
	"agentos/core/internal/maintenance"
	"agentos/core/internal/recovery"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func resetRuntimeForTest(t *testing.T) string {
	t.Helper()
	maintenanceLaunches.Reset()
	dir := t.TempDir()
	mu.Lock()
	events = nil
	sessionsByID = map[string]*sessionRecord{}
	attentionDisposition = map[string]string{}
	eventPath = filepath.Join(dir, "events.jsonl")
	eventIndexPath = filepath.Join(dir, "events.index.json")
	eventIndex = nil
	sessionPath = filepath.Join(dir, "sessions.json")
	mu.Unlock()
	return dir
}

func TestLifecycleEventCreatesPersistentSession(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Status:"WAITING", Task:Task{Title:"Need approval"}, Source:"test"})
	ss := getRegistry()
	if len(ss) != 1 { t.Fatalf("sessions=%d want 1", len(ss)) }
	if ss[0].Status != "WAITING" || !ss[0].Attention { t.Fatalf("unexpected session: %#v", ss[0]) }
	if ss[0].Task.Title != "Need approval" { t.Fatalf("task=%q", ss[0].Task.Title) }
	if _, err := os.Stat(sessionPath); err != nil { t.Fatalf("session store not persisted: %v", err) }
	var stored sessionStore
	b, err := os.ReadFile(sessionPath)
	if err != nil || json.Unmarshal(b, &stored) != nil { t.Fatalf("invalid versioned session store: %v", err) }
	if stored.SchemaVersion != sessionStoreSchemaVersion { t.Fatalf("schema=%d want %d", stored.SchemaVersion, sessionStoreSchemaVersion) }
}

func TestLegacySessionStoreMigratesOnLoad(t *testing.T) {
	dir := resetRuntimeForTest(t)
	legacy := map[string]*sessionRecord{"s1": {Session: Session{ID: "s1", Agent: "codex", Status: "WAITING", Attention: true}}}
	b, err := json.Marshal(legacy)
	if err != nil { t.Fatal(err) }
	storeDir := filepath.Join(dir, ".local", "state", "agentos")
	if err := os.MkdirAll(storeDir, 0o700); err != nil { t.Fatal(err) }
	if err := os.WriteFile(filepath.Join(storeDir, "sessions.json"), b, 0o600); err != nil { t.Fatal(err) }
	initStore(dir)
	ss := getRegistry()
	if len(ss) != 1 || ss[0].ID != "s1" { t.Fatalf("migrated sessions=%#v", ss) }
	var stored sessionStore
	b, err = os.ReadFile(sessionPath)
	if err != nil || json.Unmarshal(b, &stored) != nil { t.Fatalf("migrated store is invalid: %v", err) }
	if stored.SchemaVersion != sessionStoreSchemaVersion { t.Fatalf("schema=%d want %d", stored.SchemaVersion, sessionStoreSchemaVersion) }
}

func TestToolAndArtifactAttachToSession(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"claude", Project:"repo", Status:"RUNNING", Session:"s1"})
	addTypedEvent(Event{Kind:"tool.started", Agent:"claude", Project:"repo", Session:"s1", Status:"TOOL", Tool:ToolCall{Name:"git",State:"running"}})
	addTypedEvent(Event{Kind:"artifact.created", Agent:"claude", Project:"repo", Session:"s1", Artifact:&Artifact{Kind:"diff",Path:"/tmp/a.diff"}})
	ss := getRegistry()
	if len(ss) != 1 { t.Fatalf("sessions=%d want 1", len(ss)) }
	if ss[0].Tool.Name != "git" { t.Fatalf("tool=%#v", ss[0].Tool) }
	if len(ss[0].Artifacts) != 1 || ss[0].Artifacts[0].Kind != "diff" { t.Fatalf("artifacts=%#v", ss[0].Artifacts) }
}

func TestStructuredAgentEventEnrichmentPersists(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"TOOL", Model:"gpt-5", Usage:&Usage{InputTokens:10, OutputTokens:4, TotalTokens:14}})
	addTypedEvent(Event{Kind:"approval.requested", Agent:"codex", Project:"repo", Session:"s1", Approval:&Approval{ID:"a1", Kind:"sudo", State:"pending", Reason:"install package"}})
	addTypedEvent(Event{Kind:"file.changed", Agent:"codex", Project:"repo", Session:"s1", FileChange:&FileChange{Path:"main.go", Operation:"modified", Before:"old", After:"new"}})
	ss := getRegistry()
	if len(ss) != 1 { t.Fatalf("sessions=%d want 1", len(ss)) }
	if ss[0].Model != "gpt-5" || ss[0].Usage.TotalTokens != 14 { t.Fatalf("runtime enrichment=%#v", ss[0]) }
	if len(ss[0].Approvals) != 1 || ss[0].Approvals[0].ID != "a1" { t.Fatalf("approvals=%#v", ss[0].Approvals) }
	if len(ss[0].ChangedFiles) != 1 || ss[0].ChangedFiles[0].Path != "main.go" || ss[0].ChangedFiles[0].Before != "old" || ss[0].ChangedFiles[0].After != "new" { t.Fatalf("changed files=%#v", ss[0].ChangedFiles) }
	if !ss[0].Attention || ss[0].Status != "WAITING" { t.Fatalf("approval should require attention: %#v", ss[0]) }
}

func TestStaleLifecycleEventCannotRegressSession(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{ID:"new", Time:"2026-08-24T10:01:00Z", Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Task:Task{Title:"Current approval"}})
	addTypedEvent(Event{ID:"old", Time:"2026-08-24T10:00:00Z", Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"RUNNING", Task:Task{Title:"Old task"}})

	ss := getRegistry()
	if len(ss) != 1 || ss[0].Status != "WAITING" || ss[0].Task.Title != "Current approval" || !ss[0].Attention {
		t.Fatalf("stale event regressed session: %#v", ss)
	}
	if len(getEvents()) != 2 { t.Fatalf("stale event was not retained in event history") }
}

func TestApprovalAttentionRecognizesTerminalDecisions(t *testing.T) {
	if !approvalNeedsAttention(&Approval{State:"pending"}) { t.Fatal("pending approval should need attention") }
	for _, state := range []string{"approved", "denied", "resolved", "cancelled"} {
		if approvalNeedsAttention(&Approval{State:state}) { t.Fatalf("%s approval should be resolved", state) }
	}
}

func TestResolvedApprovalClearsApprovalAttention(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"RUNNING"})
	addTypedEvent(Event{Kind:"approval.requested", Agent:"codex", Project:"repo", Session:"s1", Approval:&Approval{ID:"a1", State:"pending"}})
	addTypedEvent(Event{Kind:"approval.resolved", Agent:"codex", Project:"repo", Session:"s1", Approval:&Approval{ID:"a1", State:"approved"}})

	ss := getRegistry()
	if len(ss) != 1 || ss[0].Status != "RUNNING" || ss[0].Attention || ss[0].WaitingForApproval {
		t.Fatalf("resolved approval remained actionable: %#v", ss)
	}
}

func TestResolvedApprovalDoesNotClearExplicitWaitingState(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"RUNNING"})
	addTypedEvent(Event{Kind:"approval.requested", Agent:"codex", Project:"repo", Session:"s1", Approval:&Approval{ID:"a1", State:"pending"}})
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING"})
	addTypedEvent(Event{Kind:"approval.resolved", Agent:"codex", Project:"repo", Session:"s1", Approval:&Approval{ID:"a1", State:"approved"}})

	ss := getRegistry()
	if len(ss) != 1 || ss[0].Status != "WAITING" || !ss[0].Attention {
		t.Fatalf("explicit waiting state was cleared: %#v", ss)
	}
}

func TestAgentCatalogSeparatesIdentityFromSessions(t *testing.T) {
	got := agentCatalog([]Session{
		{ID:"codex:repo", Agent:"codex", Status:"RUNNING"},
		{ID:"codex:other", Agent:"codex", Status:"WAITING"},
		{ID:"claude:repo", Agent:"claude", Status:"DONE"},
	})
	if len(got) != 4 { t.Fatalf("agents=%d want 4", len(got)) }
	if got[0].ID != "codex" || got[0].Adapter != "codex" || got[0].SessionCount != 2 { t.Fatalf("codex identity=%#v", got[0]) }
	if got[1].ID != "claude" || got[1].Adapter != "claude-code" || got[1].SessionCount != 1 { t.Fatalf("claude identity=%#v", got[1]) }
}

func TestEnvironmentForVirtualization(t *testing.T) {
	if got := environmentForVirtualization("none"); got != "physical" {
		t.Fatalf("bare-metal environment=%q", got)
	}
	for _, virtualization := range []string{"kvm", "qemu", "docker"} {
		if got := environmentForVirtualization(virtualization); got != "vps" {
			t.Fatalf("%s environment=%q", virtualization, got)
		}
	}
}

func TestSystemSettingsCatalogIsStable(t *testing.T) {
	settings := systemInfo().Settings
	want := []string{"system-settings", "wifi-settings", "bluetooth-settings", "mouse-settings"}
	if len(settings) != len(want) {
		t.Fatalf("settings=%d want %d", len(settings), len(want))
	}
	for i, id := range want {
		if settings[i].ID != id || settings[i].Name == "" {
			t.Fatalf("settings[%d]=%#v", i, settings[i])
		}
	}
}

func TestHardwareReadinessIsExposedInState(t *testing.T) {
	original, originalRecovery := collectHardwareReadiness, collectRecoveryReadiness
	t.Cleanup(func() { collectHardwareReadiness, collectRecoveryReadiness = original, originalRecovery })
	collectHardwareReadiness = func() hardware.State {
		return hardware.State{Schema: hardware.Schema, Role: "physical", Overall: hardware.StatusWarning, Checks: []hardware.Check{{ID: "firmware-support", Status: hardware.StatusUnavailable}}, Firmware: hardware.FirmwareState{Status: hardware.StatusUnavailable}}
	}
	collectRecoveryReadiness = func() recovery.State { return recovery.State{Schema: recovery.Schema, Status: recovery.StatusReady, CurrentRoot: "@", NextBoot: recovery.NextBootNormal, Points: []recovery.RecoveryPoint{{ID: "pre-pacman-20260907-100000", BootSafe: true}}} }
	got := state(t.TempDir())
	if got.Hardware.Schema != hardware.Schema || got.Hardware.Role != "physical" || got.Hardware.Overall != hardware.StatusWarning {
		t.Fatalf("hardware=%#v", got.Hardware)
	}
	if !got.Maintenance.Hardware.Available || got.Maintenance.Hardware.Status != maintenance.StatusReady {
		t.Fatalf("maintenance hardware=%#v", got.Maintenance.Hardware)
	}
	if got.Recovery.Schema != recovery.Schema || !got.Maintenance.Recovery.Available || !maintenanceActionByID(t, got.Maintenance, "recovery-stage").Available {
		t.Fatalf("recovery=%#v maintenance=%#v", got.Recovery, got.Maintenance.Recovery)
	}
	if !maintenanceActionByID(t, got.Maintenance, "firmware-enable").Available || maintenanceActionByID(t, got.Maintenance, "firmware-check").Available || maintenanceActionByID(t, got.Maintenance, "firmware-apply").Available {
		t.Fatalf("firmware actions=%#v", got.Maintenance.Actions)
	}
}

func maintenanceActionByID(t *testing.T, state maintenance.State, id string) maintenance.Action { t.Helper();for _,action:=range state.Actions{if action.ID==id{return action}};t.Fatalf("action %q missing",id);return maintenance.Action{} }

func TestFirmwareActionsRequirePhysicalInstalledSupport(t *testing.T){physical:=hardware.State{Role:"physical",Firmware:hardware.FirmwareState{Status:hardware.StatusReady,Installed:true}};state:=maintenanceStateWithHardware(physical);if maintenanceActionByID(t,state,"firmware-enable").Available||!maintenanceActionByID(t,state,"firmware-check").Available||!maintenanceActionByID(t,state,"firmware-apply").Available{t.Fatalf("physical actions=%#v",state.Actions)};vps:=hardware.State{Role:"vps",Firmware:hardware.FirmwareState{Status:hardware.StatusUnsupported}};state=maintenanceStateWithHardware(vps);for _,id:=range []string{"firmware-enable","firmware-check","firmware-apply"}{if maintenanceActionByID(t,state,id).Available{t.Fatalf("VPS action %q available",id)}}}

func TestHardwareReadinessCacheBoundsFirmwarePolling(t *testing.T){originalCollect,originalNow:=collectHardwareSystem,hardwareReadinessNow;t.Cleanup(func(){collectHardwareSystem=originalCollect;hardwareReadinessNow=originalNow;hardwareReadinessCache=hardwareReadinessCacheEntry{}});calls:=0;now:=time.Date(2026,9,7,12,0,0,0,time.UTC);collectHardwareSystem=func()hardware.State{calls++;return hardware.State{Schema:hardware.Schema,Role:"physical"}};hardwareReadinessNow=func()time.Time{return now};hardwareReadinessCache=hardwareReadinessCacheEntry{};cachedHardwareReadiness();cachedHardwareReadiness();if calls!=1{t.Fatalf("calls=%d want 1",calls)};now=now.Add(31*time.Second);cachedHardwareReadiness();if calls!=2{t.Fatalf("calls=%d want 2 after expiry",calls)}}

func TestRecoveryReadinessCacheBoundsBundleVerification(t *testing.T){originalCollect,originalNow:=collectRecoverySystem,recoveryReadinessNow;t.Cleanup(func(){collectRecoverySystem=originalCollect;recoveryReadinessNow=originalNow;recoveryReadinessCache=recoveryReadinessCacheEntry{}});calls:=0;now:=time.Date(2026,9,7,12,0,0,0,time.UTC);collectRecoverySystem=func()recovery.State{calls++;return recovery.State{Schema:recovery.Schema,Status:recovery.StatusReady}};recoveryReadinessNow=func()time.Time{return now};recoveryReadinessCache=recoveryReadinessCacheEntry{};cachedRecoveryReadiness();cachedRecoveryReadiness();if calls!=1{t.Fatalf("calls=%d want 1",calls)};now=now.Add(31*time.Second);cachedRecoveryReadiness();if calls!=2{t.Fatalf("calls=%d want 2 after expiry",calls)}}

func TestDeveloperToolDefinitionsAreStable(t *testing.T) {
	if len(developerToolDefinitions) != 4 {
		t.Fatalf("developer tools=%d want 4", len(developerToolDefinitions))
	}
	for _, tool := range developerToolDefinitions {
		if tool.ID == "" || tool.Name == "" || tool.Command == "" {
			t.Fatalf("invalid developer tool definition=%#v", tool)
		}
	}
}

func TestStateCollectionsEncodeAsArrays(t *testing.T) {
	assertArray := func(t *testing.T, object map[string]any, field string) []any {
		t.Helper()
		value, ok := object[field].([]any)
		if !ok {
			t.Fatalf("%s=%#v want JSON array", field, object[field])
		}
		return value
	}

	empty, err := json.Marshal(stableStateCollections(State{}))
	if err != nil { t.Fatal(err) }
	var emptyState map[string]any
	if err := json.Unmarshal(empty, &emptyState); err != nil { t.Fatal(err) }
	for _, field := range []string{"projects", "agents", "sessions", "attention", "resources", "models", "developer_tools", "events"} {
		assertArray(t, emptyState, field)
	}
	assertArray(t, emptyState["health"].(map[string]any), "alerts")
	assertArray(t, emptyState["system"].(map[string]any), "settings")
	assertArray(t, emptyState["recovery"].(map[string]any), "points")

	withProjects, err := json.Marshal(stableStateCollections(State{Projects: []Project{
		{Name: "plain-folder"},
		{Name: "git-repository", Commits: []Commit{{SHA: "abc123", Subject: "keep me"}}},
	}}))
	if err != nil { t.Fatal(err) }
	var projectState map[string]any
	if err := json.Unmarshal(withProjects, &projectState); err != nil { t.Fatal(err) }
	projects := assertArray(t, projectState, "projects")
	if commits := assertArray(t, projects[0].(map[string]any), "commits"); len(commits) != 0 {
		t.Fatalf("plain-folder commits=%#v want empty array", commits)
	}
	commits := assertArray(t, projects[1].(map[string]any), "commits")
	if len(commits) != 1 || commits[0].(map[string]any)["SHA"] != "abc123" {
		t.Fatalf("non-empty commits changed: %#v", commits)
	}
}

func TestTerminalSessionExpiry(t *testing.T) {
	resetRuntimeForTest(t)
	old := time.Now().Add(-20*time.Minute).Format(time.RFC3339)
	mu.Lock()
	sessionsByID["codex:repo"]=&sessionRecord{Session:Session{ID:"codex:repo",Agent:"codex",Project:"repo",Status:"DONE",UpdatedAt:old}}
	mu.Unlock()
	if got:=getRegistry();len(got)!=0{t.Fatalf("expired DONE session still visible: %#v",got)}
}

func TestReconciliationAssignsOneLiveProcessToOneSession(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"RUNNING"})
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s2", Status:"RUNNING"})

	result := reconcileRegistryWithLive([]Session{{ID:"codex:101", PID:101, Agent:"codex", Project:"repo"}})
	if !result.used[0] { t.Fatal("live process was not bound") }
	bound := 0
	for _, session := range getRegistry() {
		if session.PID == 101 { bound++ }
	}
	if bound != 1 { t.Fatalf("live process bound to %d sessions, want 1", bound) }
}

func TestAgentStartSessionBindsLiveProcessByProject(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Status:"STARTING", Text:"starting codex"})

	result := reconcileRegistryWithLive([]Session{{ID:"codex:4242", PID:4242, Agent:"codex", Project:"repo", Status:"RUNNING"}})
	bound, ok := result.bindings["codex:repo"]
	if !ok || bound.PID != 4242 {
		t.Fatalf("agent-start session binding=%#v want pid 4242", result.bindings)
	}
	ss := getRegistry()
	if len(ss) != 1 || ss[0].ID != "codex:repo" || ss[0].PID != 4242 {
		t.Fatalf("agent-start registry=%#v", ss)
	}
}

func TestFreshAgentStartWinsWhenLiveProjectIsUnknown(t *testing.T) {
	resetRuntimeForTest(t)
	now := time.Now().UTC()
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Status:"WAITING", Time:now.Add(-time.Hour).Format(time.RFC3339)})
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Status:"STARTING", Time:now.Format(time.RFC3339)})

	result := reconcileRegistryWithLive([]Session{{ID:"codex:4242", PID:4242, Agent:"codex", Project:"workspace", Status:"RUNNING"}})
	bound, ok := result.bindings["codex:repo"]
	if !ok || bound.PID != 4242 {
		t.Fatalf("fresh agent-start binding=%#v want codex:repo at pid 4242", result.bindings)
	}
	if stale := result.bindings["codex:workspace"]; stale.PID != 0 {
		t.Fatalf("stale session claimed live process: %#v", stale)
	}
}

func TestFreshAgentStartDoesNotStealKnownProjectProcess(t *testing.T) {
	resetRuntimeForTest(t)
	now := time.Now().UTC()
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Status:"STARTING", Time:now.Format(time.RFC3339)})

	result := reconcileRegistryWithLive([]Session{{ID:"codex:4242", PID:4242, Agent:"codex", Project:"other", Status:"RUNNING"}})
	if _, ok := result.bindings["codex:repo"]; ok {
		t.Fatalf("fresh start stole known project process: %#v", result.bindings)
	}
}

func TestFreshAgentStartClearsPreviousProcessBinding(t *testing.T) {
	resetRuntimeForTest(t)
	now := time.Now().UTC()
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"RUNNING", Time:now.Add(-time.Minute).Format(time.RFC3339)})
	mu.Lock()
	sessionsByID["s1"].PID = 101
	mu.Unlock()

	start := now.Format(time.RFC3339)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"STARTING", Time:start})
	ss := getRegistry()
	if len(ss) != 1 || ss[0].PID != 0 || ss[0].StartedAt != start {
		t.Fatalf("fresh start retained old process binding: %#v", ss)
	}
}

func TestAgentStartEventRecordsLaunchedProcess(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"STARTING", PID:4242})
	ss:=getRegistry()
	if len(ss)!=1||ss[0].PID!=4242{t.Fatalf("launch PID was not recorded: %#v",ss)}
}

func TestRecordLaunchedAgentEmitsRunning(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Status:"STARTING", Text:"starting codex"})
	recordLaunchedAgent("codex", "repo", 4242)
	ss:=getRegistry()
	if len(ss)!=1||ss[0].Status!=string(StateRunning)||ss[0].PID!=4242{t.Fatalf("launched agent=%#v",ss)}
}

func TestReconciliationExpiresStaleWaitingSessionWithoutPID(t *testing.T) {
	resetRuntimeForTest(t)
	now:=time.Date(2026,8,30,12,0,0,0,time.UTC)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Time:now.Add(-25*time.Hour).Format(time.RFC3339), Text:"old prompt"})
	reconcileRegistryWithLiveAt(nil, now)
	ss:=getRegistry()
	if len(ss)!=1||ss[0].Status!=string(StateDone)||ss[0].Attention{t.Fatalf("stale waiting session=%#v",ss)}
	seen:=false
	for _,e:=range getEvents(){if e.Session=="s1"&&e.Status==string(StateDone)&&e.Source=="process-reconciler"{seen=true}}
	if !seen{t.Fatal("stale waiting session did not produce a terminal reconciliation event")}
}

func TestReconciliationDoesNotReuseReplacementProcess(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"RUNNING"})
	mu.Lock()
	sessionsByID["s1"].PID = 101
	mu.Unlock()

	result := reconcileRegistryWithLive([]Session{{ID:"codex:202", PID:202, Agent:"codex", Project:"repo"}})
	if result.used[0] { t.Fatal("replacement process was attached to the exited session") }
	ss := getRegistry()
	if len(ss) != 1 || ss[0].Status != "DONE" || ss[0].PID != 0 {
		t.Fatalf("replacement reconciliation = %#v", ss)
	}
}

func TestAttentionDeduplicates(t *testing.T) {
	ss:=[]Session{{ID:"s",Agent:"codex",Project:"repo",Status:"WAITING",Attention:true,Task:Task{Title:"Approve"}}}
	ps:=[]Project{{Name:"repo",GitHub:GitHubState{CI:&CIState{Status:"completed",Conclusion:"failure"}}}}
	h:=Health{}
	got:=attentionItems(ps,ss,h)
	if len(got)!=2{t.Fatalf("attention=%d want 2: %#v",len(got),got)}
}

func TestAcknowledgedAttentionIsSuppressed(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{ID:"wait-1", Time:"2026-08-24T10:00:00Z", Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Task:Task{Title:"Approve"}})
	items:=attentionItems(nil,getRegistry(),Health{})
	if len(items)!=1||items[0].ID==""{t.Fatalf("attention=%#v",items)}
	if err:=recordAttentionDisposition(items[0].ID,"acknowledged");err!=nil{t.Fatal(err)}
	if got:=attentionItems(nil,getRegistry(),Health{});len(got)!=0{t.Fatalf("acknowledged attention remained visible: %#v",got)}
}

func TestChangedAttentionReopensWithNewID(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{ID:"wait-1", Time:"2026-08-24T10:00:00Z", Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Task:Task{Title:"Approve first"}})
	first:=attentionItems(nil,getRegistry(),Health{})
	if len(first)!=1{t.Fatalf("first attention=%#v",first)}
	if err:=recordAttentionDisposition(first[0].ID,"dismissed");err!=nil{t.Fatal(err)}
	addTypedEvent(Event{ID:"wait-2", Time:"2026-08-24T10:01:00Z", Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Task:Task{Title:"Approve second"}})
	got:=attentionItems(nil,getRegistry(),Health{})
	if len(got)!=1||got[0].ID==first[0].ID{t.Fatalf("changed attention did not reopen: %#v",got)}
}

func TestAttentionDispositionSurvivesNonSemanticEnrichment(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{ID:"wait-1", Time:"2026-08-24T10:00:00Z", Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Task:Task{Title:"Approve"}})
	items:=attentionItems(nil,getRegistry(),Health{})
	if len(items)!=1{t.Fatalf("first attention=%#v",items)}
	if err:=recordAttentionDisposition(items[0].ID,"dismissed");err!=nil{t.Fatal(err)}
	addTypedEvent(Event{ID:"metadata-1", Time:"2026-08-24T10:01:00Z", Kind:"session.enriched", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Model:"gpt-5"})
	if got:=attentionItems(nil,getRegistry(),Health{});len(got)!=0{t.Fatalf("enrichment reopened dismissed attention: %#v",got)}
}

func TestAttentionDispositionPersistsAndActionUsesIt(t *testing.T) {
	dir:=resetRuntimeForTest(t)
	addTypedEvent(Event{ID:"wait-1", Time:"2026-08-24T10:00:00Z", Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Task:Task{Title:"Approve"}})
	items:=attentionItems(nil,getRegistry(),Health{})
	if len(items)!=1{t.Fatalf("attention=%#v",items)}
	if err:=doAction("",Action{Name:"attention-dismiss",AttentionID:items[0].ID});err!=nil{t.Fatal(err)}
	var stored sessionStore
	b,err:=os.ReadFile(sessionPath)
	if err!=nil||json.Unmarshal(b,&stored)!=nil{t.Fatalf("invalid persisted store: %v",err)}
	if stored.Attention[items[0].ID]!="dismissed"{t.Fatalf("persisted attention=%#v",stored.Attention)}
	if got:=attentionItems(nil,getRegistry(),Health{});len(got)!=0{t.Fatalf("dismissed attention remained visible: %#v",got)}
	mu.Lock();events=nil;sessionsByID=map[string]*sessionRecord{};mu.Unlock()
	initStore(dir)
	if got:=attentionItems(nil,getRegistry(),Health{});len(got)!=0{t.Fatalf("dismissed attention returned after reload: %#v",got)}
}

func TestAttentionDispositionRequiresKnownKindAndID(t *testing.T) {
	resetRuntimeForTest(t)
	if err:=recordAttentionDisposition("","dismissed");err==nil{t.Fatal("missing attention ID should fail")}
	if err:=recordAttentionDisposition("attention-1","ignored");err==nil{t.Fatal("unknown disposition should fail")}
}

func TestAgentStopClosesEventBackedSessionWithoutPID(t *testing.T) {
	resetRuntimeForTest(t)
	addTypedEvent(Event{Kind:"agent.lifecycle", Agent:"codex", Project:"repo", Session:"s1", Status:"WAITING", Task:Task{Title:"Direct lifecycle test"}})
	if err:=doAction("",Action{Name:"agent-stop",Agent:"codex",Project:"repo",Session:"s1"});err!=nil{t.Fatal(err)}
	ss:=getRegistry()
	if len(ss)!=1||ss[0].Status!=string(StateDone)||ss[0].Attention{t.Fatalf("closed event-backed session=%#v",ss)}
}

func TestAttentionEventRequiresID(t *testing.T) {
	resetRuntimeForTest(t)
	req:=httptest.NewRequest(http.MethodPost,"/v1/events",strings.NewReader(`{"kind":"attention.dismissed"}`))
	recorder:=httptest.NewRecorder()
	eventHandler(recorder,req)
	if recorder.Code!=http.StatusBadRequest{t.Fatalf("status=%d want %d",recorder.Code,http.StatusBadRequest)}
}

func TestIndexedLogHistoryBeyondRecentWindow(t *testing.T) {
	resetRuntimeForTest(t)
	for i:=0; i<325; i++ { addTypedEvent(Event{ID:fmt.Sprintf("history-%03d",i), Kind:"history", Text:fmt.Sprintf("event %03d",i)}) }
	req:=httptest.NewRequest(http.MethodGet,"/v1/logs?kind=history&limit=1&offset=324",nil)
	recorder:=httptest.NewRecorder()
	logsHandler(recorder,req)
	if recorder.Code!=http.StatusOK{t.Fatalf("status=%d body=%s",recorder.Code,recorder.Body.String())}
	var response logResponse
	if err:=json.Unmarshal(recorder.Body.Bytes(),&response);err!=nil{t.Fatal(err)}
	if response.Total!=325||len(response.Logs)!=1||response.Logs[0].ID!="history-000"{t.Fatalf("indexed history=%#v",response)}
	if _,err:=os.Stat(eventIndexPath);err!=nil{t.Fatalf("event index not persisted: %v",err)}
}

func TestAPIErrorEnvelopeAndMethodContract(t *testing.T) {
	resetRuntimeForTest(t)
	recorder:=httptest.NewRecorder()
	eventHandler(recorder,httptest.NewRequest(http.MethodPost,"/v1/events",strings.NewReader("{")))
	if recorder.Code!=http.StatusBadRequest||!strings.HasPrefix(recorder.Header().Get("Content-Type"),"application/json"){t.Fatalf("event error response=%d %q",recorder.Code,recorder.Body.String())}
	var eventError apiErrorResponse
	if err:=json.Unmarshal(recorder.Body.Bytes(),&eventError);err!=nil||eventError.Error.Code!="INVALID_JSON"{t.Fatalf("event error=%#v err=%v",eventError,err)}
	recorder=httptest.NewRecorder()
	logsHandler(recorder,httptest.NewRequest(http.MethodPost,"/v1/logs",nil))
	if recorder.Code!=http.StatusMethodNotAllowed||recorder.Header().Get("Allow")!=http.MethodGet{t.Fatalf("logs method response=%d allow=%q",recorder.Code,recorder.Header().Get("Allow"))}
	recorder=httptest.NewRecorder()
	logsHandler(recorder,httptest.NewRequest(http.MethodGet,"/v1/logs?limit=bad",nil))
	var paginationError apiErrorResponse
	if recorder.Code!=http.StatusBadRequest||json.NewDecoder(recorder.Body).Decode(&paginationError)!=nil||paginationError.Error.Code!="INVALID_PAGINATION"{t.Fatalf("pagination error=%#v",paginationError)}
	recorder=httptest.NewRecorder()
	actionHandler("")(recorder,httptest.NewRequest(http.MethodPost,"/v1/action",strings.NewReader("{")))
	var actionError apiErrorResponse
	if recorder.Code!=http.StatusBadRequest||json.NewDecoder(recorder.Body).Decode(&actionError)!=nil||actionError.Error.Code!="INVALID_JSON"{t.Fatalf("action error=%#v",actionError)}
	recorder=httptest.NewRecorder()
	actionHandler("")(recorder,httptest.NewRequest(http.MethodGet,"/v1/action",nil))
	if recorder.Code!=http.StatusMethodNotAllowed||recorder.Header().Get("Allow")!=http.MethodPost{t.Fatalf("action method response=%d allow=%q",recorder.Code,recorder.Header().Get("Allow"))}
}

func TestStateJSONAddsMaintenanceWithoutChangingUpdates(t *testing.T){value:=stableStateCollections(State{Updates:UpdateState{Channel:"stable",Version:"1.2.3",ArchPending:4,LastUpdate:"yesterday"},Maintenance:maintenanceState()});encoded,err:=json.Marshal(value);if err!=nil{t.Fatal(err)};var object map[string]any;if err:=json.Unmarshal(encoded,&object);err!=nil{t.Fatal(err)};updates:=object["updates"].(map[string]any);if updates["channel"]!="stable"||updates["version"]!="1.2.3"||updates["arch_pending"]!=float64(4){t.Fatalf("legacy updates changed: %#v",updates)};contract:=object["maintenance"].(map[string]any);if contract["schema"]!="agentos.maintenance/v1"{t.Fatalf("maintenance=%#v",contract)};if _,ok:=contract["actions"].([]any);!ok{t.Fatalf("maintenance actions=%#v want array",contract["actions"])}}

func TestUpdatesMergeLatestCheckWithDurableApplyResult(t *testing.T){dir:=t.TempDir();checkPath:=filepath.Join(dir,"check.json");resultPath:=filepath.Join(dir,"result.json");channelPath:=filepath.Join(dir,"channel");versionPath:=filepath.Join(dir,"version");lastPath:=filepath.Join(dir,"last-update");os.WriteFile(channelPath,[]byte("stable\n"),0o600);os.WriteFile(versionPath,[]byte("1.0\n"),0o600);os.WriteFile(lastPath,[]byte("yesterday\n"),0o600);os.WriteFile(resultPath,[]byte(`{"schema":"agentos.update/v1","status":"reboot-required","channel":"stable","current_version":"1.0","target_version":"1.0","checked_at":"2026-09-07T08:00:00Z","last_success_at":"2026-09-07T08:05:00Z","snapshot_id":"pre-pacman-1","migration_status":"succeeded","reboot_required":true,"arch_pending":1}`),0o600);os.WriteFile(checkPath,[]byte(`{"schema":"agentos.update/v1","status":"available","channel":"stable","current_version":"1.0","target_version":"1.1","checked_at":"2026-09-07T09:00:00Z","arch_pending":2}`),0o600);t.Setenv("AGENTOS_UPDATE_CHECK_STATE",checkPath);t.Setenv("AGENTOS_UPDATE_RESULT_STATE",resultPath);t.Setenv("AGENTOS_CHANNEL_FILE",channelPath);t.Setenv("AGENTOS_VERSION_FILE",versionPath);t.Setenv("AGENTOS_LAST_UPDATE_FILE",lastPath);state:=updates(dir);if state.Status!="available"||state.TargetVersion!="1.1"||state.ArchPending!=2||state.LastSuccessAt!="2026-09-07T08:05:00Z"||state.SnapshotID!="pre-pacman-1"||!state.RebootRequired||state.LastUpdate!="yesterday"{t.Fatalf("updates=%#v",state)}}

func TestUpdatesClearRebootRequirementAfterBootChanges(t *testing.T){dir:=t.TempDir();resultPath:=filepath.Join(dir,"result.json");bootPath:=filepath.Join(dir,"boot-id");os.WriteFile(resultPath,[]byte(`{"schema":"agentos.update/v1","status":"reboot-required","channel":"stable","current_version":"1.0","checked_at":"2026-09-07T08:00:00Z","reboot_required":true,"boot_id":"boot-a","arch_pending":1}`),0o600);os.WriteFile(bootPath,[]byte("boot-b\n"),0o600);t.Setenv("AGENTOS_UPDATE_RESULT_STATE",resultPath);t.Setenv("AGENTOS_UPDATE_CHECK_STATE",filepath.Join(dir,"missing-check.json"));t.Setenv("AGENTOS_BOOT_ID_FILE",bootPath);state:=updates(dir);if state.RebootRequired||state.Status!="succeeded"{t.Fatalf("updates=%#v",state)}}

func TestMaintenanceStateReflectsDurableUpdateOutcome(t *testing.T){state:=maintenanceState(UpdateState{Status:"available",CurrentVersion:"1.0",TargetVersion:"1.1",ArchPending:2});if state.Update.Status!=maintenance.StatusReady||state.Update.Pending!=3{t.Fatalf("available update=%#v",state.Update)};state=maintenanceState(UpdateState{Status:"apply-failed"});if state.Update.Status!=maintenance.StatusFailed{t.Fatalf("failed update=%#v",state.Update)};state=maintenanceState(UpdateState{Status:"reboot-required",RebootRequired:true});if state.Update.Status!=maintenance.StatusRebootRequired||!state.Update.RequiresReboot{t.Fatalf("reboot update=%#v",state.Update)}}

func TestMaintenanceActionLaunchUsesFixedCommand(t *testing.T){original:=maintenanceGUI;t.Cleanup(func(){maintenanceGUI=original});var name string;var args []string;maintenanceGUI=func(gotName string,gotArgs ...string)error{name=gotName;args=append([]string(nil),gotArgs...);return nil};if err:=doAction("",Action{Name:"update-apply"});err!=nil{t.Fatal(err)};want:=[]string{"-e","zsh","-lc","agentos update --apply; echo; read -k1 '?Press any key to close'"};if name!="kitty"||strings.Join(args,"\x00")!=strings.Join(want,"\x00"){t.Fatalf("launch=%q %q want kitty %q",name,args,want)}}

func TestSupportActionLaunchUsesFixedLocalCommand(t *testing.T){original:=maintenanceGUI;t.Cleanup(func(){maintenanceGUI=original});var name string;var args []string;maintenanceGUI=func(gotName string,gotArgs ...string)error{name=gotName;args=append([]string(nil),gotArgs...);return nil};if err:=doAction("",Action{Name:"support"});err!=nil{t.Fatal(err)};want:=[]string{"-e","zsh","-lc","agentos support; echo; echo 'Review the local report before sharing it.'; echo; read -k1 '?Press any key to close'"};if name!="kitty"||strings.Join(args,"\x00")!=strings.Join(want,"\x00"){t.Fatalf("launch=%q %q want kitty %q",name,args,want)}}

func TestFirmwareActionLaunchesUseFixedCommands(t *testing.T){tests:=map[string]string{"firmware-enable":"agentos hardware firmware-enable; echo; read -k1 '?Press any key to close'","firmware-check":"agentos hardware firmware-check; echo; read -k1 '?Press any key to close'","firmware-apply":"read -q '?Apply available firmware updates? [y/N] ' || { echo; exit 1; }; echo; sudo agentos hardware firmware-apply --confirm; echo; read -k1 '?Press any key to close'"};for action,wantCommand:=range tests{t.Run(action,func(t *testing.T){originalGUI,originalHardware:=maintenanceGUI,collectHardwareReadiness;t.Cleanup(func(){maintenanceGUI,collectHardwareReadiness=originalGUI,originalHardware});installed:=action!="firmware-enable";collectHardwareReadiness=func()hardware.State{return hardware.State{Role:"physical",Firmware:hardware.FirmwareState{Installed:installed}}};var name string;var args []string;maintenanceGUI=func(gotName string,gotArgs ...string)error{name=gotName;args=append([]string(nil),gotArgs...);return nil};if err:=doAction("",Action{Name:action});err!=nil{t.Fatal(err)};want:=[]string{"-e","zsh","-lc",wantCommand};if name!="kitty"||strings.Join(args,"\x00")!=strings.Join(want,"\x00"){t.Fatalf("launch=%q %q want kitty %q",name,args,want)}})}}

func TestFirmwareActionsFailClosedWhenUnavailable(t *testing.T){originalGUI,originalHardware:=maintenanceGUI,collectHardwareReadiness;t.Cleanup(func(){maintenanceGUI,collectHardwareReadiness=originalGUI,originalHardware});launched:=false;maintenanceGUI=func(string,...string)error{launched=true;return nil};tests:=[]struct{name string;state hardware.State}{{"firmware-enable",hardware.State{Role:"vps"}},{"firmware-check",hardware.State{Role:"physical",Firmware:hardware.FirmwareState{Installed:false}}},{"firmware-apply",hardware.State{Role:"physical",Firmware:hardware.FirmwareState{Installed:false}}}};for _,tt:=range tests{t.Run(tt.name,func(t *testing.T){launched=false;collectHardwareReadiness=func()hardware.State{return tt.state};err:=doAction("",Action{Name:tt.name});var requestError *actionRequestError;if !errors.As(err,&requestError)||requestError.Code!="ACTION_UNAVAILABLE"{t.Fatalf("error=%v want ACTION_UNAVAILABLE",err)};if launched{t.Fatal("unavailable firmware action launched")}})}}

func TestMaintenanceStateReflectsRecoveryAvailability(t *testing.T){h:=hardware.State{Role:"physical"};r:=recovery.State{Schema:recovery.Schema,Status:recovery.StatusReady,CurrentRoot:"@",NextBoot:recovery.NextBootNormal,Points:[]recovery.RecoveryPoint{{ID:"pre-pacman-20260907-100000",BootSafe:true}}};state:=maintenanceStateWithSystem(h,r);if !state.Recovery.Available||!state.Actions[6].Available||state.Actions[7].Available{t.Fatalf("available recovery=%#v",state)};r.Staged=&recovery.Staged{SourceID:r.Points[0].ID,TargetSubvolume:"@rollback-20260907-110000"};state=maintenanceStateWithSystem(h,r);if state.Actions[6].Available||!state.Actions[7].Available{t.Fatalf("staged recovery=%#v",state)}}

func TestRecoveryActionLaunchesUseValidatedPointID(t *testing.T){originalGUI,originalRecovery:=maintenanceGUI,collectRecoverySystem;t.Cleanup(func(){maintenanceGUI,collectRecoverySystem=originalGUI,originalRecovery});id:="pre-pacman-20260907-100000";collectRecoverySystem=func()recovery.State{return recovery.State{Schema:recovery.Schema,Status:recovery.StatusReady,CurrentRoot:"@",NextBoot:recovery.NextBootNormal,Points:[]recovery.RecoveryPoint{{ID:id,BootSafe:true}}}};var name string;var args []string;maintenanceGUI=func(gotName string,gotArgs ...string)error{name=gotName;args=append([]string(nil),gotArgs...);return nil};if err:=doAction("",Action{Name:"recovery-stage",RecoveryPointID:id});err!=nil{t.Fatal(err)};wantCommand:="read -q '?Stage one-shot rollback for the next boot? [y/N] ' || { echo; exit 1; }; echo; sudo agentos recovery stage "+id+" --confirm; echo; read -k1 '?Press any key to close'";want:=[]string{"-e","zsh","-lc",wantCommand};if name!="kitty"||strings.Join(args,"\x00")!=strings.Join(want,"\x00"){t.Fatalf("launch=%q %q want kitty %q",name,args,want)}}

func TestRecoveryActionsFailClosed(t *testing.T){original:=collectRecoverySystem;t.Cleanup(func(){collectRecoverySystem=original});collectRecoverySystem=func()recovery.State{return recovery.State{Schema:recovery.Schema,Status:recovery.StatusReady,Points:[]recovery.RecoveryPoint{{ID:"pre-pacman-20260907-100000",BootSafe:false}}}};for _,action:=range []Action{{Name:"recovery-stage",RecoveryPointID:"../../etc"},{Name:"recovery-stage",RecoveryPointID:"pre-pacman-20260907-100000"},{Name:"recovery-cancel"}}{if err:=doAction("",action);err==nil{t.Fatalf("action accepted: %#v",action)}}}

func TestUpdateCenterLaunchUsesFixedNativeView(t *testing.T){original:=maintenanceGUI;t.Cleanup(func(){maintenanceGUI=original});var name string;var args []string;maintenanceGUI=func(gotName string,gotArgs ...string)error{name=gotName;args=append([]string(nil),gotArgs...);return nil};if err:=doAction("",Action{Name:"update-center-open"});err!=nil{t.Fatal(err)};want:=[]string{"--view","system"};if name!="agentos-native-workspace"||strings.Join(args,"\x00")!=strings.Join(want,"\x00"){t.Fatalf("launch=%q %q want agentos-native-workspace %q",name,args,want)}}

func TestMaintenanceStateReportsUserMigrations(t *testing.T){original:=readUserMigrationStatus;t.Cleanup(func(){readUserMigrationStatus=original});readUserMigrationStatus=func()([]byte,error){return []byte(`{"schema":"agentos.migrations/v1","scopes":[{"scope":"user","migrations":[{"id":"20260906-001-old","status":"applied"},{"id":"20260906-002-next","status":"pending"},{"id":"20260906-003-failed","status":"failed"}]}]}`),nil};state:=maintenanceState();if !state.Migrations.Available||state.Migrations.Status!=maintenance.StatusFailed||state.Migrations.Pending!=1||state.Migrations.Failed!=1{t.Fatalf("migrations=%#v",state.Migrations)};if state.Migrations.Revision==""{t.Fatal("migration revision should identify the current queue")};var action maintenance.Action;for _,candidate:=range state.Actions{if candidate.ID=="migration-apply-user"{action=candidate}};if !action.Available{t.Fatalf("migration action=%#v",action)}}

func TestMaintenanceStateFailsClosedOnMalformedMigrationStatus(t *testing.T){original:=readUserMigrationStatus;t.Cleanup(func(){readUserMigrationStatus=original});readUserMigrationStatus=func()([]byte,error){return []byte(`{"schema":"wrong","scopes":[]}`),nil};state:=maintenanceState();if state.Migrations.Available||state.Migrations.Status!=maintenance.StatusUnavailable{t.Fatalf("migrations=%#v want unavailable",state.Migrations)}}

func TestMigrationAttentionIsDeterministicUntilQueueChanges(t *testing.T){state:=maintenance.NewState(maintenance.Availability{Migrations:true});state.Migrations.Status=maintenance.StatusReady;state.Migrations.Pending=2;state.Migrations.Revision="queue-a";first:=migrationAttention(state);second:=migrationAttention(state);if len(first)!=1||len(second)!=1||first[0].ID!=second[0].ID||first[0].Kind!="migration"{t.Fatalf("attention=%#v %#v",first,second)};state.Migrations.Revision="queue-b";changed:=migrationAttention(state);if len(changed)!=1||changed[0].ID==first[0].ID{t.Fatalf("changed attention=%#v",changed)}}

func TestUserMigrationActionLaunchUsesFixedCommand(t *testing.T){original:=maintenanceGUI;t.Cleanup(func(){maintenanceGUI=original});var name string;var args []string;maintenanceGUI=func(gotName string,gotArgs ...string)error{name=gotName;args=append([]string(nil),gotArgs...);return nil};if err:=doAction("",Action{Name:"migration-apply-user"});err!=nil{t.Fatal(err)};want:=[]string{"-e","zsh","-lc","agentos migrate apply --scope user; echo; read -k1 '?Press any key to close'"};if name!="kitty"||strings.Join(args,"\x00")!=strings.Join(want,"\x00"){t.Fatalf("launch=%q %q want kitty %q",name,args,want)}}

func TestActionHandlerRejectsUnknownAndUnexpectedParameters(t *testing.T){tests:=[]struct{name,payload,code string}{{"unknown JSON field",`{"name":"update-apply","command":"arbitrary"}`,"INVALID_JSON"},{"unexpected known field",`{"name":"update-apply","project":"repo"}`,"VALIDATION_ERROR"},{"unsupported action",`{"name":"arbitrary-command"}`,"VALIDATION_ERROR"},{"trailing JSON",`{"name":"update-apply"}{}`,"INVALID_JSON"}};for _,tt:=range tests{t.Run(tt.name,func(t *testing.T){recorder:=httptest.NewRecorder();actionHandler("")(recorder,httptest.NewRequest(http.MethodPost,"/v1/action",strings.NewReader(tt.payload)));var response apiErrorResponse;if recorder.Code!=http.StatusBadRequest||json.NewDecoder(recorder.Body).Decode(&response)!=nil||response.Error.Code!=tt.code{t.Fatalf("response=%d %#v",recorder.Code,response)}})}}

func TestActionHandlerRedactsLaunchErrors(t *testing.T){original:=maintenanceGUI;t.Cleanup(func(){maintenanceGUI=original});maintenanceGUI=func(string,...string)error{return errors.New("sensitive subprocess output")};recorder:=httptest.NewRecorder();actionHandler("")(recorder,httptest.NewRequest(http.MethodPost,"/v1/action",strings.NewReader(`{"name":"update-check"}`)));if recorder.Code!=http.StatusBadRequest{t.Fatalf("status=%d",recorder.Code)};if strings.Contains(recorder.Body.String(),"sensitive subprocess output"){t.Fatalf("response leaked command error: %s",recorder.Body.String())}}

func TestValidLifecycle(t *testing.T){for _,s:=range []string{"STARTING","RUNNING","THINKING","TOOL","WAITING","BLOCKED","BACKGROUND","DONE","FAILED","waiting"}{if !validLifecycle(s){t.Fatalf("%s should be valid",s)}};if validLifecycle("SLEEPING"){t.Fatal("SLEEPING should not be valid")}}
func TestGithubRepo(t *testing.T){if got:=githubRepo("git@github.com:example/agentos.git");got!="example/agentos"{t.Fatalf("got %q",got)}}
