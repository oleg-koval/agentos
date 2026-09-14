package main

import (
	"agentos/core/internal/hardware"
	"agentos/core/internal/maintenance"
	"agentos/core/internal/recovery"
	"agentos/core/internal/updatestate"
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type LifecycleState string

const (
	StateStarting   LifecycleState = "STARTING"
	StateRunning    LifecycleState = "RUNNING"
	StateThinking   LifecycleState = "THINKING"
	StateTool       LifecycleState = "TOOL"
	StateWaiting    LifecycleState = "WAITING"
	StateBlocked    LifecycleState = "BLOCKED"
	StateBackground LifecycleState = "BACKGROUND"
	StateDone       LifecycleState = "DONE"
	StateFailed     LifecycleState = "FAILED"
)

type Commit struct{ SHA, Subject, Age string }
type PullRequest struct {
	Number int `json:"number"`
	Title string `json:"title"`
	URL string `json:"url"`
	Draft bool `json:"draft"`
	ReviewDecision string `json:"review_decision"`
	MergeState string `json:"merge_state"`
}
type CIState struct {
	Name string `json:"name"`
	Status string `json:"status"`
	Conclusion string `json:"conclusion"`
	URL string `json:"url"`
	Event string `json:"event"`
	CreatedAt string `json:"created_at"`
}
type GitHubState struct {
	Available bool `json:"available"`
	Repo string `json:"repo"`
	PR *PullRequest `json:"pr,omitempty"`
	CI *CIState `json:"ci,omitempty"`
	Error string `json:"error,omitempty"`
}
type Project struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Branch string `json:"branch"`
	Dirty bool `json:"dirty"`
	DirtyCount int `json:"dirty_count"`
	Ahead int `json:"ahead"`
	Behind int `json:"behind"`
	Upstream string `json:"upstream"`
	LastActivity string `json:"last_activity"`
	Worktrees int `json:"worktrees"`
	Commits []Commit `json:"commits"`
	GitHub GitHubState `json:"github"`
}
type Task struct {
	ID string `json:"id,omitempty"`
	Title string `json:"title,omitempty"`
	State string `json:"state,omitempty"`
}
type ToolCall struct {
	Name string `json:"name,omitempty"`
	State string `json:"state,omitempty"`
}
type Artifact struct {
	Kind string `json:"kind,omitempty"`
	Path string `json:"path,omitempty"`
	URL string `json:"url,omitempty"`
}
type Usage struct {
	InputTokens int `json:"input_tokens,omitempty"`
	OutputTokens int `json:"output_tokens,omitempty"`
	TotalTokens int `json:"total_tokens,omitempty"`
}
type Approval struct {
	ID string `json:"id,omitempty"`
	Kind string `json:"kind,omitempty"`
	State string `json:"state,omitempty"`
	Reason string `json:"reason,omitempty"`
}
type FileChange struct {
	Path string `json:"path,omitempty"`
	Operation string `json:"operation,omitempty"`
	Before string `json:"before,omitempty"`
	After string `json:"after,omitempty"`
}
type Session struct {
	ID string `json:"id"`
	Agent string `json:"agent"`
	PID int `json:"pid"`
	Elapsed string `json:"elapsed"`
	Seconds int `json:"seconds"`
	Project string `json:"project"`
	CWD string `json:"cwd"`
	Status string `json:"status"`
	Attention bool `json:"attention"`
	WaitingForApproval bool `json:"waiting_for_approval,omitempty"`
	StatusSource string `json:"status_source"`
	Task Task `json:"task,omitempty"`
	Tool ToolCall `json:"tool,omitempty"`
	Artifacts []Artifact `json:"artifacts,omitempty"`
	Model string `json:"model,omitempty"`
	Usage Usage `json:"usage,omitempty"`
	Approvals []Approval `json:"approvals,omitempty"`
	ChangedFiles []FileChange `json:"changed_files,omitempty"`
	AttentionRevision string `json:"attention_revision,omitempty"`
	StartedAt string `json:"started_at,omitempty"`
	UpdatedAt string `json:"updated_at,omitempty"`
}
type Agent struct {
	ID string `json:"id"`
	Name string `json:"name"`
	Adapter string `json:"adapter"`
	Command string `json:"command"`
	Enabled bool `json:"enabled"`
	SessionCount int `json:"session_count"`
}
type sessionRecord struct {
	Session
	LastEvent string `json:"last_event,omitempty"`
}
const sessionStoreSchemaVersion = 1
type sessionStore struct {
	SchemaVersion int `json:"schema_version"`
	Sessions map[string]*sessionRecord `json:"sessions"`
	Attention map[string]string `json:"attention,omitempty"`
}
type Resource struct { Name string `json:"name"`; PID int `json:"pid"`; MB int `json:"mb"` }
type Model struct { Name string `json:"name"`; Size string `json:"size"`; Processor string `json:"processor"` }
type Alert struct { Level string `json:"level"`; Text string `json:"text"` }
type Health struct {
	Status string `json:"status"`
	FailedUnits int `json:"failed_units"`
	MemoryPct int `json:"memory_pct"`
	SwapPct int `json:"swap_pct"`
	DiskPct int `json:"disk_pct"`
	CPUtemp string `json:"cpu_temp"`
	Tailscale string `json:"tailscale"`
	SSH bool `json:"ssh"`
	KRDP bool `json:"krdp"`
	Ollama bool `json:"ollama"`
	NetworkManager bool `json:"network_manager"`
	Wifi string `json:"wifi"`
	Bluetooth bool `json:"bluetooth"`
	BtrfsErrors int `json:"btrfs_errors"`
	Alerts []Alert `json:"alerts"`
}
type UpdateState struct { Channel string `json:"channel"`; Version string `json:"version"`; ArchPending int `json:"arch_pending"`; LastUpdate string `json:"last_update"`; Status string `json:"status"`; CurrentVersion string `json:"current_version"`; TargetVersion string `json:"target_version,omitempty"`; CheckedAt string `json:"checked_at,omitempty"`; LastSuccessAt string `json:"last_success_at,omitempty"`; LastFailure string `json:"last_failure,omitempty"`; SnapshotID string `json:"snapshot_id,omitempty"`; MigrationStatus string `json:"migration_status,omitempty"`; RebootRequired bool `json:"reboot_required"` }
type SystemSetting struct { ID string `json:"id"`; Name string `json:"name"`; Available bool `json:"available"` }
type SystemInfo struct { Environment string `json:"environment"`; Virtualization string `json:"virtualization"`; Hostname string `json:"hostname"`; Settings []SystemSetting `json:"settings"` }
type DeveloperTool struct { ID string `json:"id"`; Name string `json:"name"`; Command string `json:"command"`; Installed bool `json:"installed"` }
type Event struct {
	ID string `json:"id,omitempty"`
	Time string `json:"time,omitempty"`
	Kind string `json:"kind"`
	Text string `json:"text,omitempty"`
	Agent string `json:"agent,omitempty"`
	PID int `json:"pid,omitempty"`
	Session string `json:"session,omitempty"`
	Project string `json:"project,omitempty"`
	Status string `json:"status,omitempty"`
	Task Task `json:"task,omitempty"`
	Tool ToolCall `json:"tool,omitempty"`
	Artifact *Artifact `json:"artifact,omitempty"`
	Model string `json:"model,omitempty"`
	Usage *Usage `json:"usage,omitempty"`
	Approval *Approval `json:"approval,omitempty"`
	FileChange *FileChange `json:"file_change,omitempty"`
	AttentionID string `json:"attention_id,omitempty"`
	Source string `json:"source,omitempty"`
}
type AttentionItem struct { ID string `json:"id"`; Level string `json:"level"`; Kind string `json:"kind"`; Agent string `json:"agent,omitempty"`; Project string `json:"project,omitempty"`; Session string `json:"session,omitempty"`; Text string `json:"text"` }
type State struct {
	Host string `json:"host"`
	Uptime string `json:"uptime"`
	Load string `json:"load"`
	Projects []Project `json:"projects"`
	Agents []Agent `json:"agents"`
	Sessions []Session `json:"sessions"`
	Attention []AttentionItem `json:"attention"`
	Health Health `json:"health"`
	Resources []Resource `json:"resources"`
	Models []Model `json:"models"`
	Updates UpdateState `json:"updates"`
	Maintenance maintenance.State `json:"maintenance"`
	Hardware hardware.State `json:"hardware"`
	Recovery recovery.State `json:"recovery"`
	System SystemInfo `json:"system"`
	DeveloperTools []DeveloperTool `json:"developer_tools"`
	Events []Event `json:"events"`
	Timestamp string `json:"timestamp"`
}
type Action struct { Name string `json:"name"`; Project string `json:"project,omitempty"`; Agent string `json:"agent,omitempty"`; PID int `json:"pid,omitempty"`; Session string `json:"session,omitempty"`; AttentionID string `json:"attention_id,omitempty"`; RecoveryPointID string `json:"recovery_point_id,omitempty"` }
type githubCacheEntry struct { At time.Time; State GitHubState }
type eventIndexEntry struct { ID string `json:"id"`; Time string `json:"time"`; Kind string `json:"kind"`; Text string `json:"text,omitempty"`; Agent string `json:"agent,omitempty"`; Session string `json:"session,omitempty"`; Project string `json:"project,omitempty"`; Offset int64 `json:"offset"`; Length int64 `json:"length"` }
type eventIndexStore struct { SchemaVersion int `json:"schema_version"`; Entries []eventIndexEntry `json:"entries"` }
type logResponse struct { Logs []Event `json:"logs"`; Total int `json:"total"`; Limit int `json:"limit"`; Offset int `json:"offset"` }
type apiErrorResponse struct { Error apiError `json:"error"` }
type apiError struct { Code string `json:"code"`; Message string `json:"message"` }

var mu sync.Mutex
var events []Event
var sessionsByID = map[string]*sessionRecord{}
var attentionDisposition = map[string]string{}
var eventPath, eventIndexPath, sessionPath string
var eventIndex []eventIndexEntry
var githubMu sync.Mutex
var githubCache = map[string]githubCacheEntry{}

const eventIndexSchemaVersion = 1

func writeAPIError(w http.ResponseWriter, status int, code, message string) { w.Header().Set("Content-Type","application/json"); w.WriteHeader(status); _=json.NewEncoder(w).Encode(apiErrorResponse{Error:apiError{Code:code,Message:message}}) }
func allowMethod(w http.ResponseWriter, r *http.Request, method, allow string) bool { if r.Method==method { return true }; w.Header().Set("Allow",allow); writeAPIError(w,http.StatusMethodNotAllowed,"METHOD_NOT_ALLOWED","method not allowed"); return false }

func validLifecycle(s string) bool {
	switch LifecycleState(strings.ToUpper(s)) {
	case StateStarting, StateRunning, StateThinking, StateTool, StateWaiting, StateBlocked, StateBackground, StateDone, StateFailed:
		return true
	default:
		return false
	}
}
func attentionFor(status string) bool { return status == string(StateWaiting) || status == string(StateBlocked) || status == string(StateFailed) }
func terminal(status string) bool { return status == string(StateDone) || status == string(StateFailed) }
func eventPrecedesSession(eventTime, updatedAt string) bool {
	if eventTime == "" || updatedAt == "" { return false }
	eventAt, eventErr := time.Parse(time.RFC3339, eventTime)
	sessionAt, sessionErr := time.Parse(time.RFC3339, updatedAt)
	return eventErr == nil && sessionErr == nil && eventAt.Before(sessionAt)
}
func approvalNeedsAttention(a *Approval) bool {
	if a == nil { return false }
	switch strings.ToLower(a.State) {
	case "approved", "denied", "resolved", "cancelled", "canceled":
		return false
	default:
		return true
	}
}
func approvalsNeedAttention(approvals []Approval) bool {
	latest := map[string]Approval{}
	for _, approval := range approvals {
		if approval.ID == "" {
			if approvalNeedsAttention(&approval) { return true }
			continue
		}
		latest[approval.ID] = approval
	}
	for _, approval := range latest {
		if approvalNeedsAttention(&approval) { return true }
	}
	return false
}
func attentionDispositionForKind(kind string) string {
	switch kind {
	case "attention.acknowledged": return "acknowledged"
	case "attention.dismissed": return "dismissed"
	default: return ""
	}
}
func attentionID(prefix string, parts ...string) string { digest:=sha256.Sum256([]byte(strings.Join(parts,"\x00"))); return prefix+":"+hex.EncodeToString(digest[:]) }
func approvalFingerprint(approvals []Approval) string { parts:=make([]string,0,len(approvals)*4);for _,a:=range approvals{parts=append(parts,a.ID,a.Kind,a.State,a.Reason)};return strings.Join(parts,"\x00") }
func agentAttentionID(s Session) string { return attentionID("agent",s.ID,s.Agent,s.Project,s.Status,s.Task.ID,s.Task.Title,approvalFingerprint(s.Approvals),s.AttentionRevision) }
func attentionSuppressed(id string) bool { mu.Lock();defer mu.Unlock();_,ok:=attentionDisposition[id];return ok }
func recordAttentionDisposition(id,disposition string) error { id=strings.TrimSpace(id);if id==""{return fmt.Errorf("attention ID required")};if disposition!="acknowledged"&&disposition!="dismissed"{return fmt.Errorf("unsupported attention disposition")};addTypedEvent(Event{Kind:"attention."+disposition,AttentionID:id,Text:"attention "+disposition,Source:"action"});return nil }
func nowRFC() string { return time.Now().Format(time.RFC3339) }

func initStore(home string) {
	dir := filepath.Join(home, ".local", "state", "agentos")
	_ = os.MkdirAll(dir, 0o700)
	eventPath = filepath.Join(dir, "events.jsonl")
	eventIndexPath = filepath.Join(dir, "events.index.json")
	sessionPath = filepath.Join(dir, "sessions.json")
	events = nil
	eventIndex = nil
	sessionsByID = map[string]*sessionRecord{}
	attentionDisposition = map[string]string{}
	if b, err := os.ReadFile(sessionPath); err == nil {
		var stored sessionStore
		if json.Unmarshal(b, &stored) == nil && stored.SchemaVersion == sessionStoreSchemaVersion && stored.Sessions != nil {
			sessionsByID = stored.Sessions
			if stored.Attention != nil { attentionDisposition = stored.Attention }
		} else {
			var legacy map[string]*sessionRecord
			if json.Unmarshal(b, &legacy) == nil && legacy != nil { sessionsByID = legacy }
		}
	}
	f, err := os.Open(eventPath)
	if err == nil {
		loaded := make([]Event, 0, 300)
		offset := int64(0)
		r := bufio.NewReader(f)
		for {
			line, readErr := r.ReadString('\n')
			if len(line) > 0 {
				var e Event
				if json.Unmarshal([]byte(line), &e) == nil {
					eventIndex = append(eventIndex, eventIndexEntry{ID:e.ID, Time:e.Time, Kind:e.Kind, Text:e.Text, Agent:e.Agent, Session:e.Session, Project:e.Project, Offset:offset, Length:int64(len(line))})
					loaded = append(loaded, e)
					if len(loaded) > 300 { loaded = loaded[len(loaded)-300:] }
				}
				offset += int64(len(line))
			}
			if readErr == io.EOF { break }
			if readErr != nil { break }
		}
		_ = f.Close()
		for _, e := range loaded { applyEventLocked(e, false) }
		for i := len(loaded)-1; i >= 0; i-- { events = append(events, loaded[i]) }
	}
	persistEventIndexLocked()
	persistSessionsLocked()
}
func persistSessionsLocked() {
	if sessionPath == "" { return }
	b, err := json.MarshalIndent(sessionStore{SchemaVersion: sessionStoreSchemaVersion, Sessions: sessionsByID, Attention: attentionDisposition}, "", "  ")
	if err != nil { return }
	tmp := sessionPath + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil { _ = os.Rename(tmp, sessionPath) }
}
func persistEventLocked(e Event) {
	f, err := os.OpenFile(eventPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil { return }
	defer f.Close()
	b, err := json.Marshal(e); if err != nil { return }
	data := append(b, '\n')
	offset, err := f.Seek(0, io.SeekEnd); if err != nil { return }
	n, err := f.Write(data); if err != nil || n != len(data) { return }
	eventIndex = append(eventIndex, eventIndexEntry{ID:e.ID, Time:e.Time, Kind:e.Kind, Text:e.Text, Agent:e.Agent, Session:e.Session, Project:e.Project, Offset:offset, Length:int64(len(data))})
	persistEventIndexLocked()
}
func persistEventIndexLocked() {
	if eventIndexPath == "" { return }
	b, err := json.MarshalIndent(eventIndexStore{SchemaVersion:eventIndexSchemaVersion, Entries:eventIndex}, "", "  ")
	if err != nil { return }
	tmp := eventIndexPath + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil { _ = os.Rename(tmp, eventIndexPath) }
}
func sessionIDForEvent(e Event) string {
	if e.Session != "" { return e.Session }
	// Reuse the newest active semantic session for this agent/project.
	var newest *sessionRecord
	for _, r := range sessionsByID {
		if r.Agent != e.Agent || r.Project != e.Project || terminal(r.Status) { continue }
		if newest == nil || r.UpdatedAt > newest.UpdatedAt { newest = r }
	}
	if newest != nil { return newest.ID }
	project := e.Project; if project == "" { project = "workspace" }
	if e.Agent != "" { return e.Agent + ":" + project }
	return "event:" + e.ID
}
func applyEventLocked(e Event, persist bool) {
	if e.Status != "" { e.Status = strings.ToUpper(e.Status) }
	if disposition:=attentionDispositionForKind(e.Kind);disposition!=""&&e.AttentionID!=""{attentionDisposition[e.AttentionID]=disposition}
	if e.Agent != "" && (e.Status != "" || e.Task.Title != "" || e.Tool.Name != "" || e.Artifact != nil || e.Model != "" || e.Usage != nil || e.Approval != nil || e.FileChange != nil || strings.HasPrefix(e.Kind, "approval.")) {
		id := sessionIDForEvent(e)
		r := sessionsByID[id]
		if r == nil { r = &sessionRecord{Session: Session{ID:id, Agent:e.Agent, Project:e.Project, Status:string(StateStarting), StatusSource:"agent-event", StartedAt:e.Time}}; sessionsByID[id] = r }
		if eventPrecedesSession(e.Time, r.UpdatedAt) { return }
		wasAttention, previousStatus, previousTask, previousApprovals := r.Attention, r.Status, r.Task, append([]Approval(nil), r.Approvals...)
		if e.Kind == "agent.lifecycle" && e.Status == string(StateStarting) { r.PID, r.CWD, r.Seconds, r.Elapsed = 0, "", 0, ""; r.StartedAt = e.Time }
		if e.PID > 1 { r.PID = e.PID }
		if e.Agent != "" { r.Agent = e.Agent }
		if e.Project != "" { r.Project = e.Project }
		if e.Status != "" { r.Status = e.Status; r.WaitingForApproval = false }
		if e.Task.Title != "" || e.Task.ID != "" { r.Task = e.Task }
		if e.Tool.Name != "" { r.Tool = e.Tool; if e.Status == "" { r.Status = string(StateTool) } }
		if e.Artifact != nil { r.Artifacts = append(r.Artifacts, *e.Artifact); if len(r.Artifacts) > 20 { r.Artifacts = r.Artifacts[len(r.Artifacts)-20:] } }
		if e.Model != "" { r.Model = e.Model }
		if e.Usage != nil { r.Usage = *e.Usage }
		if e.Approval != nil { r.Approvals = append(r.Approvals, *e.Approval); if len(r.Approvals) > 20 { r.Approvals = r.Approvals[len(r.Approvals)-20:] }; if e.Status == "" && approvalNeedsAttention(e.Approval) { r.Status = string(StateWaiting); r.WaitingForApproval = true }; if e.Status == "" && !approvalsNeedAttention(r.Approvals) && r.WaitingForApproval { r.Status = string(StateRunning); r.WaitingForApproval = false } }
		if e.FileChange != nil { r.ChangedFiles = append(r.ChangedFiles, *e.FileChange); if len(r.ChangedFiles) > 50 { r.ChangedFiles = r.ChangedFiles[len(r.ChangedFiles)-50:] } }
		if e.Approval != nil || strings.HasPrefix(e.Kind, "approval.") { if r.Status == "" { r.Status = string(StateWaiting) } }
		r.Attention = attentionFor(r.Status) || approvalsNeedAttention(r.Approvals)
		if r.Attention && (!wasAttention || previousStatus != r.Status || previousTask != r.Task || approvalFingerprint(previousApprovals) != approvalFingerprint(r.Approvals)) { r.AttentionRevision = e.ID }
		r.StatusSource = "agent-event"
		if r.StartedAt == "" { r.StartedAt = e.Time }
		r.UpdatedAt = e.Time
		r.LastEvent = e.ID
	}
	if persist { persistSessionsLocked() }
}
func addTypedEvent(e Event) {
	if e.Time == "" { e.Time = nowRFC() }
	if e.ID == "" { e.ID = fmt.Sprintf("%d", time.Now().UnixNano()) }
	if e.Source == "" { e.Source = "agentosd" }
	if e.Status != "" { e.Status = strings.ToUpper(e.Status) }
	mu.Lock(); defer mu.Unlock()
	applyEventLocked(e, true)
	events = append([]Event{e}, events...); if len(events) > 300 { events = events[:300] }
	persistEventLocked(e)
}
func addEvent(kind, text string) { addTypedEvent(Event{Kind:kind, Text:text}) }
func getEvents() []Event { mu.Lock(); defer mu.Unlock(); out:=make([]Event,len(events)); copy(out,events); return out }
func parseLogInt(raw string, fallback, maximum int) (int, error) {
	if raw == "" { return fallback, nil }
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 || n > maximum { return 0, fmt.Errorf("invalid log pagination") }
	return n, nil
}
func logMatches(e eventIndexEntry, q url.Values) bool {
	if value:=q.Get("kind"); value!="" && e.Kind!=value { return false }
	if value:=q.Get("agent"); value!="" && e.Agent!=value { return false }
	if value:=q.Get("session"); value!="" && e.Session!=value { return false }
	if value:=q.Get("project"); value!="" && e.Project!=value { return false }
	if value:=strings.ToLower(q.Get("q")); value!="" && !strings.Contains(strings.ToLower(e.Kind+" "+e.Text), value) { return false }
	return true
}
func indexedLogs(q url.Values) (logResponse, error) {
	limit, err := parseLogInt(q.Get("limit"), 100, 500); if err != nil { return logResponse{}, err }
	offset, err := parseLogInt(q.Get("offset"), 0, 1_000_000_000); if err != nil { return logResponse{}, err }
	mu.Lock(); entries:=append([]eventIndexEntry(nil),eventIndex...); path:=eventPath; mu.Unlock()
	response:=logResponse{Logs:[]Event{},Limit:limit,Offset:offset}
	f, err := os.Open(path); if err != nil { if os.IsNotExist(err) { return response,nil }; return response,err }
	defer f.Close()
	matched:=0
	for i:=len(entries)-1;i>=0;i-- {
		entry:=entries[i];if !logMatches(entry,q){continue};response.Total++;if matched<offset{matched++;continue};if len(response.Logs)>=limit{continue};matched++
		data:=make([]byte,entry.Length);if _,err:=f.Seek(entry.Offset,io.SeekStart);err!=nil{return logResponse{},err};if _,err:=io.ReadFull(f,data);err!=nil{return logResponse{},err};var e Event;if err:=json.Unmarshal(data,&e);err!=nil{return logResponse{},err};response.Logs=append(response.Logs,e)
	}
	return response,nil
}
func logsHandler(w http.ResponseWriter,r *http.Request){if !allowMethod(w,r,http.MethodGet,http.MethodGet){return};response,err:=indexedLogs(r.URL.Query());if err!=nil{writeAPIError(w,http.StatusBadRequest,"INVALID_PAGINATION",err.Error());return};w.Header().Set("Content-Type","application/json");_=json.NewEncoder(w).Encode(response)}
func getRegistry() []Session {
	mu.Lock(); defer mu.Unlock()
	out := make([]Session,0,len(sessionsByID)); now:=time.Now()
	for _, r := range sessionsByID {
		t, _ := time.Parse(time.RFC3339, r.UpdatedAt)
		if r.Status == string(StateDone) && !t.IsZero() && now.Sub(t) > 15*time.Minute { continue }
		if r.Status == string(StateFailed) && !t.IsZero() && now.Sub(t) > 24*time.Hour { continue }
		out = append(out, r.Session)
	}
	return out
}

var agentDefinitions = []Agent{
	{ID:"codex", Name:"Codex", Adapter:"codex", Command:"codex"},
	{ID:"claude", Name:"Claude Code", Adapter:"claude-code", Command:"claude"},
	{ID:"hermes", Name:"Hermes", Adapter:"hermes", Command:"hermes"},
	{ID:"herdr", Name:"Herdr", Adapter:"herdr", Command:"herdr"},
}

func agentCatalog(ss []Session) []Agent {
	counts := map[string]int{}
	for _, s := range ss { counts[s.Agent]++ }
	out := make([]Agent, 0, len(agentDefinitions))
	for _, definition := range agentDefinitions {
		agent := definition
		_, err := exec.LookPath(agent.Command)
		agent.Enabled = err == nil
		agent.SessionCount = counts[agent.ID]
		out = append(out, agent)
	}
	return out
}

func run(name string,args ...string) string { cmd:=exec.Command(name,args...); b,err:=cmd.Output(); if err!=nil{return ""}; return strings.TrimSpace(string(b)) }
func shell(s string) string { return run("sh","-lc",s) }
func atoi(s string) int { n,_:=strconv.Atoi(strings.TrimSpace(s)); return n }
func readFile(p string) string { b,_:=os.ReadFile(p); return string(b) }
func hostName() string { if h,_:=os.Hostname();h!=""{return h}; if h:=strings.TrimSpace(readFile("/etc/hostname"));h!=""{return h}; return "unknown" }
func duration(sec int) string { d:=time.Duration(sec)*time.Second; if d>=time.Hour{return fmt.Sprintf("%dh%02dm",int(d.Hours()),int(d.Minutes())%60)}; if d>=time.Minute{return fmt.Sprintf("%dm",int(d.Minutes()))}; return fmt.Sprintf("%ds",sec) }

func environmentForVirtualization(virtualization string) string {
	if virtualization != "" && virtualization != "none" {
		return "vps"
	}
	return "physical"
}

func systemInfo() SystemInfo {
	virtualization := run("systemd-detect-virt")
	if virtualization == "" {
		virtualization = "none"
	}
	settings := make([]SystemSetting, 0, len(systemSettingDefinitions))
	for _, definition := range systemSettingDefinitions {
		setting := definition.SystemSetting
		_, err := exec.LookPath(definition.Command)
		setting.Available = err == nil
		settings = append(settings, setting)
	}
	return SystemInfo{Environment: environmentForVirtualization(virtualization), Virtualization: virtualization, Hostname: hostName(), Settings: settings}
}

type systemSettingDefinition struct { SystemSetting; Command string }

var systemSettingDefinitions = []systemSettingDefinition{
	{SystemSetting: SystemSetting{ID: "system-settings", Name: "All settings"}, Command: "systemsettings"},
	{SystemSetting: SystemSetting{ID: "wifi-settings", Name: "Wi-Fi"}, Command: "kcmshell6"},
	{SystemSetting: SystemSetting{ID: "bluetooth-settings", Name: "Bluetooth"}, Command: "kcmshell6"},
	{SystemSetting: SystemSetting{ID: "mouse-settings", Name: "Mouse"}, Command: "kcmshell6"},
}

var developerToolDefinitions = []DeveloperTool{
	{ID: "opencode", Name: "OpenCode", Command: "opencode"},
	{ID: "cursor", Name: "Cursor", Command: "cursor"},
	{ID: "vscode", Name: "VS Code", Command: "code"},
	{ID: "webstorm", Name: "WebStorm", Command: "webstorm"},
}

type hardwareReadinessCacheEntry struct{State hardware.State;ExpiresAt time.Time}
var hardwareReadinessMu sync.Mutex
var hardwareReadinessCache hardwareReadinessCacheEntry
var hardwareReadinessNow=time.Now
var collectHardwareSystem=hardware.CollectSystem
func cachedHardwareReadiness()hardware.State{hardwareReadinessMu.Lock();defer hardwareReadinessMu.Unlock();now:=hardwareReadinessNow();if !hardwareReadinessCache.ExpiresAt.IsZero()&&now.Before(hardwareReadinessCache.ExpiresAt){return hardwareReadinessCache.State};state:=collectHardwareSystem();hardwareReadinessCache=hardwareReadinessCacheEntry{State:state,ExpiresAt:now.Add(30*time.Second)};return state}
var collectHardwareReadiness = cachedHardwareReadiness

type recoveryReadinessCacheEntry struct{State recovery.State;ExpiresAt time.Time}
var recoveryReadinessMu sync.Mutex
var recoveryReadinessCache recoveryReadinessCacheEntry
var recoveryReadinessNow=time.Now
var collectRecoverySystem=recovery.CollectSystem
func cachedRecoveryReadiness()recovery.State{recoveryReadinessMu.Lock();defer recoveryReadinessMu.Unlock();now:=recoveryReadinessNow();if !recoveryReadinessCache.ExpiresAt.IsZero()&&now.Before(recoveryReadinessCache.ExpiresAt){return recoveryReadinessCache.State};state:=collectRecoverySystem();recoveryReadinessCache=recoveryReadinessCacheEntry{State:state,ExpiresAt:now.Add(30*time.Second)};return state}
var collectRecoveryReadiness=cachedRecoveryReadiness

func developerTools() []DeveloperTool {
	out := make([]DeveloperTool, 0, len(developerToolDefinitions))
	for _, definition := range developerToolDefinitions {
		tool := definition
		_, err := exec.LookPath(tool.Command)
		tool.Installed = err == nil
		out = append(out, tool)
	}
	return out
}

func githubRepo(remote string) string {
	remote=strings.TrimSuffix(strings.TrimSpace(remote),".git")
	if strings.HasPrefix(remote,"git@github.com:"){return strings.TrimPrefix(remote,"git@github.com:")}
	for _,p:=range []string{"https://github.com/","http://github.com/","ssh://git@github.com/"}{if strings.HasPrefix(remote,p){return strings.TrimPrefix(remote,p)}}
	return ""
}
func ghJSON(args []string,dst any) error { ctx,cancel:=context.WithTimeout(context.Background(),3*time.Second);defer cancel();cmd:=exec.CommandContext(ctx,"gh",args...);cmd.Env=append(os.Environ(),"GH_PROMPT_DISABLED=1","GIT_TERMINAL_PROMPT=0");b,err:=cmd.Output();if ctx.Err()!=nil{return fmt.Errorf("github query timed out")};if err!=nil{return err};return json.Unmarshal(b,dst) }
func githubState(p,branch string) GitHubState {
	repo:=githubRepo(run("git","-C",p,"remote","get-url","origin"));if repo==""{return GitHubState{Available:false}}
	key:=repo+"@"+branch;githubMu.Lock();if e,ok:=githubCache[key];ok&&time.Since(e.At)<30*time.Second{githubMu.Unlock();return e.State};githubMu.Unlock()
	st:=GitHubState{Available:true,Repo:repo};if _,err:=exec.LookPath("gh");err!=nil{st.Available=false;st.Error="gh unavailable";return st}
	var prs []struct{Number int `json:"number"`;Title string `json:"title"`;URL string `json:"url"`;Draft bool `json:"isDraft"`;ReviewDecision string `json:"reviewDecision"`;MergeState string `json:"mergeStateStatus"`}
	if err:=ghJSON([]string{"pr","list","--repo",repo,"--head",branch,"--state","open","--limit","1","--json","number,title,url,isDraft,reviewDecision,mergeStateStatus"},&prs);err==nil&&len(prs)>0{x:=prs[0];st.PR=&PullRequest{Number:x.Number,Title:x.Title,URL:x.URL,Draft:x.Draft,ReviewDecision:x.ReviewDecision,MergeState:x.MergeState}}
	var runs []struct{Name string `json:"name"`;Status string `json:"status"`;Conclusion string `json:"conclusion"`;URL string `json:"url"`;Event string `json:"event"`;CreatedAt string `json:"createdAt"`}
	if err:=ghJSON([]string{"run","list","--repo",repo,"--branch",branch,"--limit","1","--json","name,status,conclusion,url,event,createdAt"},&runs);err==nil&&len(runs)>0{x:=runs[0];st.CI=&CIState{Name:x.Name,Status:x.Status,Conclusion:x.Conclusion,URL:x.URL,Event:x.Event,CreatedAt:x.CreatedAt}}
	githubMu.Lock();githubCache[key]=githubCacheEntry{At:time.Now(),State:st};githubMu.Unlock();return st
}
func projectInfo(p string) Project {
	name:=filepath.Base(p);branch:=run("git","-C",p,"branch","--show-current");if branch==""{return Project{Name:name,Path:p,Branch:"folder"}}
	dirtyRaw:=run("git","-C",p,"status","--porcelain");dirtyCount:=0;if dirtyRaw!=""{dirtyCount=len(strings.Split(dirtyRaw,"\n"))}
	upstream:=run("git","-C",p,"rev-parse","--abbrev-ref","--symbolic-full-name","@{u}");ahead,behind:=0,0;if upstream!=""{f:=strings.Fields(run("git","-C",p,"rev-list","--left-right","--count","HEAD...@{u}"));if len(f)>=2{ahead=atoi(f[0]);behind=atoi(f[1])}}
	wt:=0;for _,line:=range strings.Split(run("git","-C",p,"worktree","list","--porcelain"),"\n"){if strings.HasPrefix(line,"worktree "){wt++}};if wt>0{wt--}
	commits:=[]Commit{};raw:=run("git","-C",p,"log","-5","--pretty=format:%h%x09%s%x09%cr");for _,line:=range strings.Split(raw,"\n"){f:=strings.SplitN(line,"\t",3);if len(f)==3{commits=append(commits,Commit{f[0],f[1],f[2]})}}
	return Project{Name:name,Path:p,Branch:branch,Dirty:dirtyCount>0,DirtyCount:dirtyCount,Ahead:ahead,Behind:behind,Upstream:upstream,LastActivity:run("git","-C",p,"log","-1","--format=%cr"),Worktrees:wt,Commits:commits,GitHub:githubState(p,branch)}
}
func projects(home string) []Project { root:=filepath.Join(home,"src");es,err:=os.ReadDir(root);if err!=nil{return nil};out:=[]Project{};for _,e:=range es{if e.IsDir(){out=append(out,projectInfo(filepath.Join(root,e.Name())))}};sort.Slice(out,func(i,j int)bool{return strings.ToLower(out[i].Name)<strings.ToLower(out[j].Name)});return out }
func sessionProject(home,cwd string) string { src:=filepath.Join(home,"src")+string(os.PathSeparator);if strings.HasPrefix(cwd,src){rest:=strings.TrimPrefix(cwd,src);if i:=strings.IndexRune(rest,os.PathSeparator);i>=0{return rest[:i]};return rest};return "workspace" }
func processState(pid int) string { raw:=run("ps","-o","stat=","-p",strconv.Itoa(pid));if raw==""{return ""};return string(raw[0]) }
func inferredStatus(agent string,pid int)(string,bool){st:=processState(pid);if strings.ContainsAny(st,"TZ")||st=="D"{return string(StateBlocked),true};if agent=="hermes"||agent=="herdr"{return string(StateBackground),false};if st=="S"||st=="I"{return string(StateWaiting),true};return string(StateRunning),false}
func liveSessions(home string) []Session {
	raw:=shell(`ps -eo pid=,etimes=,comm=`);out:=[]Session{}
	for _,line:=range strings.Split(raw,"\n"){f:=strings.Fields(line);if len(f)<3{continue};agent:=filepath.Base(f[2]);if agent!="claude"&&agent!="codex"&&agent!="hermes"&&agent!="herdr"{continue};pid,sec:=atoi(f[0]),atoi(f[1]);cwd,_:=os.Readlink(fmt.Sprintf("/proc/%d/cwd",pid));project:=sessionProject(home,cwd);status,attention:=inferredStatus(agent,pid);out=append(out,Session{ID:fmt.Sprintf("%s:%d",agent,pid),Agent:agent,PID:pid,Elapsed:duration(sec),Seconds:sec,Project:project,CWD:cwd,Status:status,Attention:attention,StatusSource:"process-inferred"})}
	return out
}
// process-exit lifecycle reconciliation is implemented in reconciler.go.
func mergedSessions(home string) []Session {
	live:=liveSessions(home);reconciled:=reconcileRegistryWithLive(live);reg:=getRegistry();out:=make([]Session,0,len(live)+len(reg))
	for _,r:=range reg{
		if l,ok:=reconciled.bindings[r.ID];ok{r.PID=l.PID;r.CWD=l.CWD;r.Seconds=l.Seconds;r.Elapsed=l.Elapsed}
		if r.Elapsed==""&&r.StartedAt!=""{if t,err:=time.Parse(time.RFC3339,r.StartedAt);err==nil{r.Seconds=int(time.Since(t).Seconds());if r.Seconds<0{r.Seconds=0};r.Elapsed=duration(r.Seconds)}}
		out=append(out,r)
	}
	for i,l:=range live{if !reconciled.used[i]{out=append(out,l)}}
	sort.SliceStable(out,func(i,j int)bool{return out[i].UpdatedAt>out[j].UpdatedAt})
	return out
}

func health() Health {
	mem:=atoi(shell(`free | awk '/^Mem:/ {printf "%d", $3*100/$2}'`));swap:=atoi(shell(`free | awk '/^Swap:/ {if($2>0) printf "%d", $3*100/$2; else print 0}'`));disk:=atoi(shell(`df --output=pcent / | tail -1 | tr -dc '0-9'`));failed:=atoi(shell(`systemctl --failed --no-legend 2>/dev/null | wc -l`));temp:=shell(`for f in /sys/class/hwmon/hwmon*/temp*_input; do [ -r "$f" ] && cat "$f"; done 2>/dev/null | sort -nr | head -1 | awk '{printf "%.0f°C",$1/1000}'`)
	ts:=run("tailscale","ip","-4");ssh:=run("systemctl","is-active","sshd")=="active";krdp:=shell(`systemctl --user is-active app-org.kde.krdpserver.service 2>/dev/null`)=="active";ollama:=run("systemctl","is-active","ollama")=="active";networkManager:=run("systemctl","is-active","NetworkManager")=="active";wifi:=run("nmcli","radio","wifi");if wifi==""{wifi="unavailable"};bluetooth:=run("systemctl","is-active","bluetooth")=="active";btrfs:=atoi(shell(`sudo -n btrfs device stats / 2>/dev/null | awk '{s+=$NF} END{print s+0}'`));alerts:=[]Alert{}
	if failed>0{alerts=append(alerts,Alert{"critical",fmt.Sprintf("%d failed systemd units",failed)})};if disk>=90{alerts=append(alerts,Alert{"critical",fmt.Sprintf("Root disk %d%% full",disk)})}else if disk>=80{alerts=append(alerts,Alert{"warning",fmt.Sprintf("Root disk %d%% full",disk)})};if mem>=90{alerts=append(alerts,Alert{"warning",fmt.Sprintf("Memory pressure %d%%",mem)})};if ts==""{alerts=append(alerts,Alert{"critical","Tailscale offline"})};if !ssh{alerts=append(alerts,Alert{"critical","SSH offline"})};if !krdp{alerts=append(alerts,Alert{"warning","KRDP inactive"})};if btrfs>0{alerts=append(alerts,Alert{"critical",fmt.Sprintf("Btrfs errors %d",btrfs)})}
	status:="healthy";for _,a:=range alerts{if a.Level=="critical"{status="critical";break};status="warning"};return Health{Status:status,FailedUnits:failed,MemoryPct:mem,SwapPct:swap,DiskPct:disk,CPUtemp:temp,Tailscale:ts,SSH:ssh,KRDP:krdp,Ollama:ollama,NetworkManager:networkManager,Wifi:wifi,Bluetooth:bluetooth,BtrfsErrors:btrfs,Alerts:alerts}
}
func resources() []Resource { raw:=shell(`ps -eo pid=,comm=,rss= --sort=-rss | head -n 9`);out:=[]Resource{};for _,line:=range strings.Split(raw,"\n"){f:=strings.Fields(line);if len(f)>=3{out=append(out,Resource{Name:f[1],PID:atoi(f[0]),MB:atoi(f[2])/1024})}};return out }
func models() []Model { raw:=run("ollama","ps");if raw==""{return nil};lines:=strings.Split(raw,"\n");out:=[]Model{};for i,line:=range lines{if i==0||strings.TrimSpace(line)==""{continue};f:=strings.Fields(line);if len(f)>=4{out=append(out,Model{Name:f[0],Size:f[2],Processor:f[len(f)-1]})}};return out }
func daemonEnv(name,fallback string)string{if value:=os.Getenv(name);value!=""{return value};return fallback}
func readDaemonUpdateRecord(path string)(updatestate.Record,bool){data,err:=os.ReadFile(path);if err!=nil{return updatestate.Record{},false};var record updatestate.Record;if json.Unmarshal(data,&record)!=nil||record.Schema!=updatestate.Schema||!updatestate.ValidStatus(record.Status){return updatestate.Record{},false};return record,true}
func updates(home string) UpdateState { channelFile:=daemonEnv("AGENTOS_CHANNEL_FILE","/etc/agentos/channel");versionFile:=daemonEnv("AGENTOS_VERSION_FILE","/etc/agentos/version");lastUpdateFile:=daemonEnv("AGENTOS_LAST_UPDATE_FILE","/var/lib/agentos/last-update");ch:=strings.TrimSpace(readFile(channelFile));if ch==""{ch="stable"};v:=strings.TrimSpace(readFile(versionFile));if v==""{v="dev"};state:=UpdateState{Channel:ch,Version:v,CurrentVersion:v,Status:string(updatestate.StatusNotChecked),LastUpdate:strings.TrimSpace(readFile(lastUpdateFile))};result,resultOK:=readDaemonUpdateRecord(daemonEnv("AGENTOS_UPDATE_RESULT_STATE","/var/lib/agentos/update-result.json"));currentBootID:=strings.TrimSpace(readFile(daemonEnv("AGENTOS_BOOT_ID_FILE","/proc/sys/kernel/random/boot_id")));if resultOK&&result.RebootRequired&&result.BootID!=""&&currentBootID!=""&&result.BootID!=currentBootID{result.RebootRequired=false;if result.Status==updatestate.StatusRebootRequired{result.Status=updatestate.StatusSucceeded}};checkPath:=daemonEnv("AGENTOS_UPDATE_CHECK_STATE",filepath.Join(home,".local","state","agentos","update-check.json"));check,checkOK:=readDaemonUpdateRecord(checkPath);latest:=result;if !resultOK||(checkOK&&check.CheckedAt>result.CheckedAt){latest=check};if resultOK{state.LastSuccessAt=result.LastSuccessAt;state.LastFailure=result.LastFailure;state.SnapshotID=result.SnapshotID;state.MigrationStatus=result.MigrationStatus;state.RebootRequired=result.RebootRequired};if resultOK||checkOK{state.Status=string(latest.Status);state.CurrentVersion=valueOrDaemon(latest.CurrentVersion,v);state.Version=state.CurrentVersion;state.TargetVersion=latest.TargetVersion;state.CheckedAt=latest.CheckedAt;state.ArchPending=latest.ArchPending;if latest.LastFailure!=""{state.LastFailure=latest.LastFailure}};return state }
func valueOrDaemon(value,fallback string)string{if value!=""{return value};return fallback}
type migrationStatusDocument struct { Schema string `json:"schema"`; Scopes []struct { Scope string `json:"scope"`; Migrations []struct { ID string `json:"id"`; Status string `json:"status"` } `json:"migrations"` } `json:"scopes"` }
var readUserMigrationStatus=func()([]byte,error){return exec.Command("/usr/bin/agentos","migrate","status","--scope","user","--json").Output()}
func userMigrationOperation()(maintenance.Operation,bool){operation:=maintenance.Operation{Status:maintenance.StatusUnavailable};raw,err:=readUserMigrationStatus();if err!=nil{return operation,false};var report migrationStatusDocument;if json.Unmarshal(raw,&report)!=nil||report.Schema!="agentos.migrations/v1"||len(report.Scopes)!=1||report.Scopes[0].Scope!="user"{return operation,false};parts:=make([]string,0,len(report.Scopes[0].Migrations));for _,migration:=range report.Scopes[0].Migrations{if migration.ID==""{return operation,false};switch migration.Status{case "applied":case "pending":operation.Pending++;case "failed":operation.Failed++;default:return maintenance.Operation{Status:maintenance.StatusUnavailable},false};parts=append(parts,migration.ID+":"+migration.Status)};digest:=sha256.Sum256([]byte(strings.Join(parts,"\x00")));operation.Available=true;operation.Revision=hex.EncodeToString(digest[:]);operation.Status=maintenance.StatusSucceeded;if operation.Pending>0{operation.Status=maintenance.StatusReady};if operation.Failed>0{operation.Status=maintenance.StatusFailed};return operation,true}
func maintenanceStateWithSystem(hardwareState hardware.State,recoveryState recovery.State,update ...UpdateState) maintenance.State { migrations,available:=userMigrationOperation();firmwareEnable:=hardwareState.Role=="physical"&&!hardwareState.Firmware.Installed;firmware:=hardwareState.Role=="physical"&&hardwareState.Firmware.Installed;recoveryAvailable:=hardwareState.Role=="physical"&&recoveryState.Status==recovery.StatusReady;recoveryStage:=false;if recoveryAvailable&&recoveryState.Staged==nil{for _,point:=range recoveryState.Points{if point.BootSafe{recoveryStage=true;break}}};state:=maintenance.NewState(maintenance.Availability{Update:true,Migrations:available,Hardware:true,FirmwareEnable:firmwareEnable,Firmware:firmware,Recovery:recoveryAvailable,RecoveryStage:recoveryStage,RecoveryCancel:recoveryAvailable&&recoveryState.Staged!=nil});state.Migrations=migrations;if len(update)>0{if update[0].RebootRequired{state.Update.Status=maintenance.StatusRebootRequired;state.Update.RequiresReboot=true}else{switch updatestate.Status(update[0].Status){case updatestate.StatusUpToDate,updatestate.StatusSucceeded:state.Update.Status=maintenance.StatusSucceeded;case updatestate.StatusCheckFailed,updatestate.StatusApplyFailed:state.Update.Status=maintenance.StatusFailed;default:state.Update.Status=maintenance.StatusReady}};if update[0].Status==string(updatestate.StatusAvailable){state.Update.Pending=update[0].ArchPending;if update[0].TargetVersion!=""&&update[0].TargetVersion!=update[0].CurrentVersion{state.Update.Pending++}}};return state }
func maintenanceStateWithHardware(hardwareState hardware.State,update ...UpdateState) maintenance.State{return maintenanceStateWithSystem(hardwareState,recovery.State{},update...)}
func maintenanceState(update ...UpdateState) maintenance.State{return maintenanceStateWithHardware(hardware.State{},update...)}
func migrationAttention(state maintenance.State)[]AttentionItem{migrations:=state.Migrations;if !migrations.Available||(migrations.Pending==0&&migrations.Failed==0){return []AttentionItem{}};level,text:="attention",fmt.Sprintf("%d user setup change(s) ready to apply",migrations.Pending);if migrations.Failed>0{level="critical";text=fmt.Sprintf("%d user setup migration(s) need retry",migrations.Failed)};item:=AttentionItem{ID:attentionID("migration",migrations.Revision),Level:level,Kind:"migration",Text:text};if attentionSuppressed(item.ID){return []AttentionItem{}};return []AttentionItem{item}}
func attentionItems(ps []Project,ss []Session,h Health) []AttentionItem {
	out:=[]AttentionItem{};seen:=map[string]bool{};add:=func(x AttentionItem){if attentionSuppressed(x.ID){return};k:=x.Kind+"|"+x.Agent+"|"+x.Project+"|"+x.Session+"|"+x.Text;if !seen[k]{seen[k]=true;out=append(out,x)}}
	for _,s:=range ss{if s.Attention{text:=fmt.Sprintf("%s is %s",s.Agent,s.Status);if s.Task.Title!=""{text+=": "+s.Task.Title};add(AttentionItem{ID:agentAttentionID(s),Level:"attention",Kind:"agent",Agent:s.Agent,Project:s.Project,Session:s.ID,Text:text})}}
	for _,a:=range h.Alerts{add(AttentionItem{ID:attentionID("system",a.Level,a.Text),Level:a.Level,Kind:"system",Text:a.Text})}
	for _,p:=range ps{if p.GitHub.CI!=nil&&strings.EqualFold(p.GitHub.CI.Status,"completed")&&p.GitHub.CI.Conclusion!=""&&!strings.EqualFold(p.GitHub.CI.Conclusion,"success")&&!strings.EqualFold(p.GitHub.CI.Conclusion,"skipped"){c:=p.GitHub.CI;add(AttentionItem{ID:attentionID("ci",p.Name,c.Name,c.Status,c.Conclusion,c.URL,c.Event,c.CreatedAt),Level:"critical",Kind:"ci",Project:p.Name,Text:fmt.Sprintf("%s CI %s",p.Name,c.Conclusion)})}}
	return out
}
func stableStateCollections(s State) State {
	if s.Projects == nil { s.Projects = []Project{} }
	for i := range s.Projects { if s.Projects[i].Commits == nil { s.Projects[i].Commits = []Commit{} } }
	if s.Agents == nil { s.Agents = []Agent{} }
	if s.Sessions == nil { s.Sessions = []Session{} }
	if s.Attention == nil { s.Attention = []AttentionItem{} }
	if s.Health.Alerts == nil { s.Health.Alerts = []Alert{} }
	if s.Resources == nil { s.Resources = []Resource{} }
	if s.Models == nil { s.Models = []Model{} }
	if s.System.Settings == nil { s.System.Settings = []SystemSetting{} }
	if s.DeveloperTools == nil { s.DeveloperTools = []DeveloperTool{} }
	if s.Events == nil { s.Events = []Event{} }
	if s.Recovery.Points == nil { s.Recovery.Points = []recovery.RecoveryPoint{} }
	return s
}
func state(home string) State { ps:=projects(home);ss:=mergedSessions(home);h:=health();updateStatus:=updates(home);hardwareStatus:=collectHardwareReadiness();recoveryStatus:=collectRecoveryReadiness();maintenanceStatus:=maintenanceLaunches.Apply(maintenanceStateWithSystem(hardwareStatus,recoveryStatus,updateStatus));attention:=attentionItems(ps,ss,h);attention=append(attention,migrationAttention(maintenanceStatus)...);return stableStateCollections(State{Host:hostName(),Uptime:strings.TrimPrefix(run("uptime","-p"),"up "),Load:shell(`awk '{print $1}' /proc/loadavg`),Projects:ps,Agents:agentCatalog(ss),Sessions:ss,Attention:attention,Health:h,Resources:resources(),Models:models(),Updates:updateStatus,Maintenance:maintenanceStatus,Hardware:hardwareStatus,Recovery:recoveryStatus,System:systemInfo(),DeveloperTools:developerTools(),Events:getEvents(),Timestamp:nowRFC()}) }

func projectPath(home,name string)(string,bool){if name==""{return "",false};root:=filepath.Join(home,"src");p:=filepath.Clean(filepath.Join(root,name));rel,err:=filepath.Rel(root,p);if err!=nil||strings.HasPrefix(rel,".."){return "",false};st,err:=os.Stat(p);return p,err==nil&&st.IsDir()}
func envMap(lines []string)map[string]string{out:=map[string]string{};for _,line:=range lines{if i:=strings.IndexByte(line,'=');i>0{out[line[:i]]=line[i+1:]}};return out}
func graphicalEnv()map[string]string{env:=envMap(os.Environ());if raw:=run("systemctl","--user","show-environment");raw!=""{for k,v:=range envMap(strings.Split(raw,"\n")){env[k]=v}};pidRaw:=shell(`pgrep -n -x plasmashell || true`);if pidRaw!=""{if b,err:=os.ReadFile(filepath.Join("/proc",pidRaw,"environ"));err==nil{for k,v:=range envMap(strings.Split(string(b),"\x00")){env[k]=v}}};return env}
func spawn(name string,args ...string)error{cmd:=exec.Command(name,args...);cmd.Stdout,cmd.Stderr,cmd.Stdin=nil,nil,nil;if err:=cmd.Start();err!=nil{addEvent("error",fmt.Sprintf("%s: %v",name,err));return err};return nil}
func spawnGUI(name string,args ...string)error{env:=graphicalEnv();keys:=[]string{"WAYLAND_DISPLAY","DISPLAY","XDG_RUNTIME_DIR","DBUS_SESSION_BUS_ADDRESS","XDG_CURRENT_DESKTOP","XDG_SESSION_TYPE","PATH","HOME","USER","SHELL","XAUTHORITY","XDG_CONFIG_HOME","XDG_DATA_HOME","XDG_CACHE_HOME"};runArgs:=[]string{"--user","--quiet","--collect","--property=Type=exec","--unit",fmt.Sprintf("agentos-ui-%d",time.Now().UnixNano())};for _,k:=range keys{if v:=env[k];v!=""{runArgs=append(runArgs,"--setenv="+k+"="+v)}};runArgs=append(runArgs,name);runArgs=append(runArgs,args...);cmd:=exec.Command("systemd-run",runArgs...);out,err:=cmd.CombinedOutput();if err!=nil{msg:=strings.TrimSpace(string(out));if msg==""{msg=err.Error()};addEvent("error",fmt.Sprintf("%s: %s",name,msg));return fmt.Errorf("launch %s: %s",name,msg)};addEvent("launch",fmt.Sprintf("%s via graphical transient service",name));return nil}
var maintenanceGUI=spawnGUI
type actionRequestError struct{Code,Message string}
func(e *actionRequestError)Error()string{return e.Message}
func actionFieldsAllowed(a Action,allowed ...string)bool{set:=map[string]bool{};for _,field:=range allowed{set[field]=true};return(a.Project==""||set["project"])&&(a.Agent==""||set["agent"])&&(a.PID==0||set["pid"])&&(a.Session==""||set["session"])&&(a.AttentionID==""||set["attention_id"])&&(a.RecoveryPointID==""||set["recovery_point_id"])}
func validateAction(a Action)error{
	if a.Name==""||a.Name!=strings.TrimSpace(a.Name){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"valid action name required"}}
	switch a.Name{
	case "terminal","files","browser","open-opencode","open-cursor","open-vscode","open-webstorm","install-opencode","install-cursor","install-vscode","install-webstorm","system-settings","wifi-settings","bluetooth-settings","mouse-settings","doctor","support","snapshot","sync","update-center-open","update-check","update-apply","migration-apply-user","firmware-enable","firmware-check","firmware-apply","restart-krdp","restart-plasma","reboot":if !actionFieldsAllowed(a){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"action parameters are not allowed"}}
	case "recovery-stage":if !recovery.ValidPointID(a.RecoveryPointID)||!actionFieldsAllowed(a,"recovery_point_id"){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"valid recovery_point_id required"}}
	case "recovery-cancel":if !actionFieldsAllowed(a){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"action parameters are not allowed"}}
	case "attention-acknowledge","attention-dismiss":if strings.TrimSpace(a.AttentionID)==""||!actionFieldsAllowed(a,"attention_id"){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"valid attention_id required"}}
	case "project-open","project-diff","open-pr":if strings.TrimSpace(a.Project)==""||!actionFieldsAllowed(a,"project"){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"valid project required"}}
	case "agent-start":if strings.TrimSpace(a.Agent)==""||!actionFieldsAllowed(a,"agent","project"){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"valid agent required"}}
	case "agent-stop":if !actionFieldsAllowed(a,"agent","project","pid","session")||(a.PID<=1&&strings.TrimSpace(a.Session)==""){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"session or live process required"}}
	case "agent-attach":if !actionFieldsAllowed(a,"agent","project"){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"invalid attach parameters"}}
	case "agent-logs":if !actionFieldsAllowed(a,"agent","project","session"){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"invalid log parameters"}}
	default:return &actionRequestError{Code:"VALIDATION_ERROR",Message:"unsupported action"}}
	return nil
}
func launchMaintenanceAction(action Action)error{name:=action.Name;command:="agentos update --check";if name=="update-apply"{command="agentos update --apply"}else if name=="migration-apply-user"{command="agentos migrate apply --scope user"}else if name=="firmware-enable"{command="agentos hardware firmware-enable"}else if name=="firmware-check"{command="agentos hardware firmware-check"}else if name=="firmware-apply"{command="read -q '?Apply available firmware updates? [y/N] ' || { echo; exit 1; }; echo; sudo agentos hardware firmware-apply --confirm"}else if name=="recovery-stage"{command="read -q '?Stage one-shot rollback for the next boot? [y/N] ' || { echo; exit 1; }; echo; sudo agentos recovery stage "+action.RecoveryPointID+" --confirm"}else if name=="recovery-cancel"{command="read -q '?Cancel the staged one-shot rollback? [y/N] ' || { echo; exit 1; }; echo; sudo agentos recovery cancel --confirm"}else if name=="support"{command="agentos support; echo; echo 'Review the local report before sharing it.'"};if err:=maintenanceGUI("kitty","-e","zsh","-lc",command+"; echo; read -k1 '?Press any key to close'");err!=nil{return err};maintenanceLaunches.Record(name);return nil}
func firmwareActionAvailable(name string,state hardware.State)bool{if state.Role!="physical"{return false};if name=="firmware-enable"{return !state.Firmware.Installed};return state.Firmware.Installed}
func newestAgentPID(agent string)int{bestPID,bestAge:=0,999999;for attempt:=0;attempt<20;attempt++{raw:=shell(`ps -eo pid=,etimes=,comm=`);bestPID,bestAge=0,999999;for _,line:=range strings.Split(raw,"\n"){f:=strings.Fields(line);if len(f)<3||filepath.Base(f[2])!=agent{continue};pid,age:=atoi(f[0]),atoi(f[1]);if pid>1&&age<bestAge{bestPID,bestAge=pid,age}};if bestPID>1&&bestAge<=3{return bestPID};time.Sleep(100*time.Millisecond)};return 0}
func recordLaunchedAgent(agent, project string, pid int) { if pid > 1 { addTypedEvent(Event{Kind:"agent.lifecycle",Agent:agent,Project:project,PID:pid,Status:string(StateRunning),Text:fmt.Sprintf("%s is running",agent),Source:"agentosd"}) } }
func doAction(home string,a Action)error{
	if err:=validateAction(a);err!=nil{return err}
	switch a.Name{
	case "attention-acknowledge":return recordAttentionDisposition(a.AttentionID,"acknowledged")
	case "attention-dismiss":return recordAttentionDisposition(a.AttentionID,"dismissed")
	case "terminal":return spawnGUI("kitty")
	case "files":return spawnGUI("dolphin")
	case "browser":return spawnGUI("chromium")
	case "open-opencode":return spawnGUI("kitty","-e","zsh","-lc","exec opencode")
	case "open-cursor":return spawnGUI("cursor")
	case "open-vscode":return spawnGUI("code")
	case "open-webstorm":return spawnGUI("webstorm")
	case "install-opencode":return spawnGUI("kitty","-e","zsh","-lc","install-agent-tools --opencode; echo; read -k1 '?Press any key to close'")
	case "install-cursor":return spawnGUI("kitty","-e","zsh","-lc","install-agent-tools --ide cursor; echo; read -k1 '?Press any key to close'")
	case "install-vscode":return spawnGUI("kitty","-e","zsh","-lc","install-agent-tools --ide vscode; echo; read -k1 '?Press any key to close'")
	case "install-webstorm":return spawnGUI("kitty","-e","zsh","-lc","install-agent-tools --ide webstorm; echo; read -k1 '?Press any key to close'")
	case "system-settings":return spawnGUI("systemsettings")
	case "wifi-settings":return spawnGUI("kcmshell6","kcm_networkmanagement")
	case "bluetooth-settings":return spawnGUI("kcmshell6","kcm_bluetooth")
	case "mouse-settings":return spawnGUI("kcmshell6","kcm_mouse")
	case "project-open":p,ok:=projectPath(home,a.Project);if !ok{return fmt.Errorf("unknown project")};addTypedEvent(Event{Kind:"project.opened",Project:a.Project,Text:"opened "+a.Project});return spawnGUI("kitty","--directory",p,"-e","zsh","-lc","exec herdr")
	case "project-diff":p,ok:=projectPath(home,a.Project);if !ok{return fmt.Errorf("unknown project")};return spawnGUI("kitty","--directory",p,"-e","zsh","-lc","git status --short; echo; git diff --stat; echo; git diff; exec zsh")
	case "open-pr":p,ok:=projectPath(home,a.Project);if !ok{return fmt.Errorf("unknown project")};return spawnGUI("kitty","--directory",p,"-e","zsh","-lc","gh pr view --web || true; sleep 2")
	case "agent-start":
		if a.Agent!="claude"&&a.Agent!="codex"&&a.Agent!="hermes"&&a.Agent!="herdr"{return fmt.Errorf("unknown agent")}
		cwd:=filepath.Join(home,"src")
		if a.Project!=""{if p,ok:=projectPath(home,a.Project);ok{cwd=p}else{return fmt.Errorf("unknown project")}}
		addTypedEvent(Event{Kind:"agent.lifecycle",Agent:a.Agent,Project:a.Project,Status:string(StateStarting),Text:fmt.Sprintf("starting %s",a.Agent)})
		if err:=spawnGUI("kitty","--directory",cwd,"-e","zsh","-lc","exec "+a.Agent);err!=nil{return err}
		if pid:=newestAgentPID(a.Agent);pid>1{recordLaunchedAgent(a.Agent,a.Project,pid)}
		return nil
	case "agent-stop":if a.PID>1{p,err:=os.FindProcess(a.PID);if err!=nil{return err};if err:=p.Signal(syscall.SIGTERM);err!=nil{return err}}else if strings.TrimSpace(a.Session)==""{return fmt.Errorf("session or live process required")};addTypedEvent(Event{Kind:"agent.lifecycle",Agent:a.Agent,Project:a.Project,Session:a.Session,Status:string(StateDone),Text:"stop requested"});return nil
	case "agent-attach":if a.Project!=""&&a.Project!="workspace"{p,ok:=projectPath(home,a.Project);if ok{return spawnGUI("kitty","--directory",p,"-e","zsh","-lc","exec herdr")}};return spawnGUI("kitty")
	case "agent-logs":return spawnGUI("kitty","-e","zsh","-lc",fmt.Sprintf("curl -sG http://127.0.0.1:4787/v1/logs --data-urlencode 'session=%s' --data-urlencode 'agent=%s' --data-urlencode 'project=%s' | jq '.logs'; exec zsh",url.QueryEscape(a.Session),url.QueryEscape(a.Agent),url.QueryEscape(a.Project)))
	case "doctor":return spawnGUI("kitty","-e","zsh","-lc","sudo workstation-doctor; echo; read -k1 '?Press any key to close'")
	case "snapshot":return spawnGUI("kitty","-e","zsh","-lc","sudo btrfs-pre-pacman-snapshot; echo; read -k1 '?Press any key to close'")
	case "sync":return spawnGUI("kitty","-e","zsh","-lc","sync-workstation; echo; read -k1 '?Press any key to close'")
	case "update-center-open":return maintenanceGUI("agentos-native-workspace","--view","system")
	case "support","update-check","update-apply","migration-apply-user":return launchMaintenanceAction(a)
	case "firmware-enable","firmware-check","firmware-apply":if !firmwareActionAvailable(a.Name,collectHardwareReadiness()){return &actionRequestError{Code:"ACTION_UNAVAILABLE",Message:"firmware action is unavailable on this system"}};return launchMaintenanceAction(a)
	case "recovery-stage":state:=collectRecoverySystem();if !state.CanStage(a.RecoveryPointID){return &actionRequestError{Code:"VALIDATION_ERROR",Message:"boot-safe recovery point required and no rollback may already be staged"}};return launchMaintenanceAction(a)
	case "recovery-cancel":state:=collectRecoverySystem();if state.Status!=recovery.StatusReady||state.Staged==nil{return &actionRequestError{Code:"VALIDATION_ERROR",Message:"no rollback is staged"}};return launchMaintenanceAction(a)
	case "restart-krdp":addEvent("system","restarting KRDP");return spawn("systemctl","--user","restart","app-org.kde.krdpserver.service")
	case "restart-plasma":addEvent("system","restarting Plasma");return spawn("systemctl","--user","restart","plasma-plasmashell.service")
	case "reboot":addEvent("system","reboot requested");return spawnGUI("kitty","-e","zsh","-lc","sudo reboot")
	default:return fmt.Errorf("unsupported action")}
}
func eventHandler(w http.ResponseWriter,r *http.Request){switch r.Method{case http.MethodGet:w.Header().Set("Content-Type","application/json");_=json.NewEncoder(w).Encode(getEvents());case http.MethodPost:var e Event;if err:=json.NewDecoder(r.Body).Decode(&e);err!=nil{writeAPIError(w,http.StatusBadRequest,"INVALID_JSON","invalid event JSON");return};if e.Kind==""{writeAPIError(w,http.StatusBadRequest,"VALIDATION_ERROR","event kind required");return};if e.Status!=""&&!validLifecycle(e.Status){writeAPIError(w,http.StatusBadRequest,"VALIDATION_ERROR","invalid lifecycle status");return};if attentionDispositionForKind(e.Kind)!=""&&strings.TrimSpace(e.AttentionID)==""{writeAPIError(w,http.StatusBadRequest,"VALIDATION_ERROR","attention ID required");return};if e.Source==""{e.Source="adapter"};addTypedEvent(e);w.WriteHeader(204);default:w.Header().Set("Allow","GET, POST");writeAPIError(w,http.StatusMethodNotAllowed,"METHOD_NOT_ALLOWED","method not allowed")}}
func actionHandler(home string) http.HandlerFunc { return func(w http.ResponseWriter,r *http.Request){if !allowMethod(w,r,http.MethodPost,http.MethodPost){return};decoder:=json.NewDecoder(http.MaxBytesReader(w,r.Body,16<<10));decoder.DisallowUnknownFields();var a Action;if err:=decoder.Decode(&a);err!=nil{writeAPIError(w,http.StatusBadRequest,"INVALID_JSON","invalid action JSON");return};if err:=decoder.Decode(&struct{}{});!errors.Is(err,io.EOF){writeAPIError(w,http.StatusBadRequest,"INVALID_JSON","invalid action JSON");return};if err:=doAction(home,a);err!=nil{var requestError *actionRequestError;if errors.As(err,&requestError){writeAPIError(w,http.StatusBadRequest,requestError.Code,requestError.Message)}else{writeAPIError(w,http.StatusBadRequest,"ACTION_FAILED","action could not be completed")};return};w.WriteHeader(204)} }
func main(){home,_:=os.UserHomeDir();initStore(home);addEvent("system","agentosd started");mux:=http.NewServeMux();mux.HandleFunc("/v1/healthz",func(w http.ResponseWriter,r *http.Request){if !allowMethod(w,r,http.MethodGet,http.MethodGet){return};_,_=w.Write([]byte("ok\n"))});mux.HandleFunc("/v1/version",func(w http.ResponseWriter,r *http.Request){if !allowMethod(w,r,http.MethodGet,http.MethodGet){return};w.Header().Set("Content-Type","application/json");_,_=w.Write([]byte(`{"api":"v1","runtime":"persistent-sessions"}`))});mux.HandleFunc("/v1/state",func(w http.ResponseWriter,r *http.Request){if !allowMethod(w,r,http.MethodGet,http.MethodGet){return};w.Header().Set("Content-Type","application/json");_=json.NewEncoder(w).Encode(state(home))});mux.HandleFunc("/v1/agents",func(w http.ResponseWriter,r *http.Request){if !allowMethod(w,r,http.MethodGet,http.MethodGet){return};w.Header().Set("Content-Type","application/json");_=json.NewEncoder(w).Encode(agentCatalog(mergedSessions(home)))});mux.HandleFunc("/v1/sessions",func(w http.ResponseWriter,r *http.Request){if !allowMethod(w,r,http.MethodGet,http.MethodGet){return};w.Header().Set("Content-Type","application/json");_=json.NewEncoder(w).Encode(mergedSessions(home))});mux.HandleFunc("/v1/events",eventHandler);mux.HandleFunc("/v1/logs",logsHandler);mux.HandleFunc("/v1/action",actionHandler(home));addr:="127.0.0.1:4787";log.Printf("agentosd listening on %s",addr);log.Fatal(http.ListenAndServe(addr,mux))}
