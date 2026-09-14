package main

import (
    "bufio"
    "context"
    "encoding/json"
    "fmt"
    "log"
    "net/http"
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
    Number         int    `json:"number"`
    Title          string `json:"title"`
    URL            string `json:"url"`
    Draft          bool   `json:"draft"`
    ReviewDecision string `json:"review_decision"`
    MergeState     string `json:"merge_state"`
}
type CIState struct {
    Name       string `json:"name"`
    Status     string `json:"status"`
    Conclusion string `json:"conclusion"`
    URL        string `json:"url"`
    Event      string `json:"event"`
    CreatedAt  string `json:"created_at"`
}
type GitHubState struct {
    Available bool         `json:"available"`
    Repo      string       `json:"repo"`
    PR        *PullRequest `json:"pr,omitempty"`
    CI        *CIState     `json:"ci,omitempty"`
    Error     string       `json:"error,omitempty"`
}
type Project struct {
    Name         string      `json:"name"`
    Path         string      `json:"path"`
    Branch       string      `json:"branch"`
    Dirty        bool        `json:"dirty"`
    DirtyCount   int         `json:"dirty_count"`
    Ahead        int         `json:"ahead"`
    Behind       int         `json:"behind"`
    Upstream     string      `json:"upstream"`
    LastActivity string      `json:"last_activity"`
    Worktrees    int         `json:"worktrees"`
    Commits      []Commit    `json:"commits"`
    GitHub       GitHubState `json:"github"`
}
type Task struct {
    ID    string `json:"id,omitempty"`
    Title string `json:"title,omitempty"`
    State string `json:"state,omitempty"`
}
type ToolCall struct {
    Name  string `json:"name,omitempty"`
    State string `json:"state,omitempty"`
}
type Artifact struct {
    Kind string `json:"kind,omitempty"`
    Path string `json:"path,omitempty"`
    URL  string `json:"url,omitempty"`
}
type Session struct {
    ID           string `json:"id"`
    Agent        string `json:"agent"`
    PID          int    `json:"pid"`
    Elapsed      string `json:"elapsed"`
    Seconds      int    `json:"seconds"`
    Project      string `json:"project"`
    CWD          string `json:"cwd"`
    Status       string `json:"status"`
    Attention    bool   `json:"attention"`
    StatusSource string `json:"status_source"`
    Task         Task   `json:"task,omitempty"`
}
type Resource struct {
    Name string `json:"name"`
    PID  int    `json:"pid"`
    MB   int    `json:"mb"`
}
type Model struct {
    Name      string `json:"name"`
    Size      string `json:"size"`
    Processor string `json:"processor"`
}
type Alert struct {
    Level string `json:"level"`
    Text  string `json:"text"`
}
type Health struct {
    Status      string  `json:"status"`
    FailedUnits int     `json:"failed_units"`
    MemoryPct   int     `json:"memory_pct"`
    SwapPct     int     `json:"swap_pct"`
    DiskPct     int     `json:"disk_pct"`
    CPUtemp     string  `json:"cpu_temp"`
    Tailscale   string  `json:"tailscale"`
    SSH         bool    `json:"ssh"`
    KRDP        bool    `json:"krdp"`
    Ollama      bool    `json:"ollama"`
    BtrfsErrors int     `json:"btrfs_errors"`
    Alerts      []Alert `json:"alerts"`
}
type UpdateState struct {
    Channel     string `json:"channel"`
    Version     string `json:"version"`
    ArchPending int    `json:"arch_pending"`
    LastUpdate  string `json:"last_update"`
}
type Event struct {
    ID       string    `json:"id,omitempty"`
    Time     string    `json:"time,omitempty"`
    Kind     string    `json:"kind"`
    Text     string    `json:"text,omitempty"`
    Agent    string    `json:"agent,omitempty"`
    Session  string    `json:"session,omitempty"`
    Project  string    `json:"project,omitempty"`
    Status   string    `json:"status,omitempty"`
    Task     Task      `json:"task,omitempty"`
    Tool     ToolCall  `json:"tool,omitempty"`
    Artifact *Artifact `json:"artifact,omitempty"`
    Source   string    `json:"source,omitempty"`
}
type AttentionItem struct {
    Level   string `json:"level"`
    Kind    string `json:"kind"`
    Agent   string `json:"agent,omitempty"`
    Project string `json:"project,omitempty"`
    Session string `json:"session,omitempty"`
    Text    string `json:"text"`
}
type State struct {
    Host      string          `json:"host"`
    Uptime    string          `json:"uptime"`
    Load      string          `json:"load"`
    Projects  []Project       `json:"projects"`
    Sessions  []Session       `json:"sessions"`
    Attention []AttentionItem `json:"attention"`
    Health    Health          `json:"health"`
    Resources []Resource      `json:"resources"`
    Models    []Model         `json:"models"`
    Updates   UpdateState     `json:"updates"`
    Events    []Event         `json:"events"`
    Timestamp string          `json:"timestamp"`
}
type Action struct {
    Name    string `json:"name"`
    Project string `json:"project,omitempty"`
    Agent   string `json:"agent,omitempty"`
    PID     int    `json:"pid,omitempty"`
}
type githubCacheEntry struct {
    At    time.Time
    State GitHubState
}

var eventMu sync.Mutex
var events []Event
var eventPath string
var githubMu sync.Mutex
var githubCache = map[string]githubCacheEntry{}

func validLifecycle(s string) bool {
    switch LifecycleState(strings.ToUpper(s)) {
    case StateStarting, StateRunning, StateThinking, StateTool, StateWaiting, StateBlocked, StateBackground, StateDone, StateFailed:
        return true
    default:
        return false
    }
}

func initEventStore(home string) {
    eventPath = filepath.Join(home, ".local", "state", "agentos", "events.jsonl")
    _ = os.MkdirAll(filepath.Dir(eventPath), 0o700)
    f, err := os.Open(eventPath)
    if err != nil {
        return
    }
    defer f.Close()
    loaded := make([]Event, 0, 200)
    scanner := bufio.NewScanner(f)
    for scanner.Scan() {
        var e Event
        if json.Unmarshal(scanner.Bytes(), &e) == nil {
            loaded = append(loaded, e)
            if len(loaded) > 200 {
                loaded = loaded[len(loaded)-200:]
            }
        }
    }
    for i := len(loaded) - 1; i >= 0; i-- {
        events = append(events, loaded[i])
    }
}

func persistEvent(e Event) {
    if eventPath == "" {
        return
    }
    f, err := os.OpenFile(eventPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
    if err != nil {
        return
    }
    defer f.Close()
    b, err := json.Marshal(e)
    if err == nil {
        _, _ = f.Write(append(b, '\n'))
    }
}

func addTypedEvent(e Event) {
    if e.Time == "" {
        e.Time = time.Now().Format(time.RFC3339)
    }
    if e.ID == "" {
        e.ID = fmt.Sprintf("%d", time.Now().UnixNano())
    }
    if e.Source == "" {
        e.Source = "agentosd"
    }
    if e.Status != "" {
        e.Status = strings.ToUpper(e.Status)
    }
    eventMu.Lock()
    events = append([]Event{e}, events...)
    if len(events) > 200 {
        events = events[:200]
    }
    persistEvent(e)
    eventMu.Unlock()
}

func addEvent(kind, text string) { addTypedEvent(Event{Kind: kind, Text: text}) }
func getEvents() []Event {
    eventMu.Lock()
    defer eventMu.Unlock()
    out := make([]Event, len(events))
    copy(out, events)
    return out
}

func run(name string, args ...string) string {
    cmd := exec.Command(name, args...)
    b, err := cmd.Output()
    if err != nil {
        return ""
    }
    return strings.TrimSpace(string(b))
}
func shell(s string) string { return run("sh", "-lc", s) }
func atoi(s string) int {
    n, _ := strconv.Atoi(strings.TrimSpace(s))
    return n
}
func readFile(p string) string {
    b, _ := os.ReadFile(p)
    return string(b)
}
func hostName() string {
    if h, _ := os.Hostname(); h != "" {
        return h
    }
    if h := strings.TrimSpace(readFile("/etc/hostname")); h != "" {
        return h
    }
    return "unknown"
}

func githubRepo(remote string) string {
    remote = strings.TrimSpace(remote)
    remote = strings.TrimSuffix(remote, ".git")
    if strings.HasPrefix(remote, "git@github.com:") {
        return strings.TrimPrefix(remote, "git@github.com:")
    }
    for _, prefix := range []string{"https://github.com/", "http://github.com/", "ssh://git@github.com/"} {
        if strings.HasPrefix(remote, prefix) {
            return strings.TrimPrefix(remote, prefix)
        }
    }
    return ""
}
func ghJSON(args []string, dst any) error {
    ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
    defer cancel()
    cmd := exec.CommandContext(ctx, "gh", args...)
    cmd.Env = append(os.Environ(), "GH_PROMPT_DISABLED=1", "GIT_TERMINAL_PROMPT=0")
    b, err := cmd.Output()
    if ctx.Err() != nil {
        return fmt.Errorf("github query timed out")
    }
    if err != nil {
        return err
    }
    return json.Unmarshal(b, dst)
}
func githubState(p, branch string) GitHubState {
    remote := run("git", "-C", p, "remote", "get-url", "origin")
    repo := githubRepo(remote)
    if repo == "" {
        return GitHubState{Available: false}
    }
    key := repo + "@" + branch
    githubMu.Lock()
    if e, ok := githubCache[key]; ok && time.Since(e.At) < 30*time.Second {
        githubMu.Unlock()
        return e.State
    }
    githubMu.Unlock()
    st := GitHubState{Available: true, Repo: repo}
    if _, err := exec.LookPath("gh"); err != nil {
        st.Available = false
        st.Error = "gh unavailable"
        return st
    }
    var prs []struct {
        Number         int    `json:"number"`
        Title          string `json:"title"`
        URL            string `json:"url"`
        Draft          bool   `json:"isDraft"`
        ReviewDecision string `json:"reviewDecision"`
        MergeState     string `json:"mergeStateStatus"`
    }
    if err := ghJSON([]string{"pr", "list", "--repo", repo, "--head", branch, "--state", "open", "--limit", "1", "--json", "number,title,url,isDraft,reviewDecision,mergeStateStatus"}, &prs); err == nil && len(prs) > 0 {
        x := prs[0]
        st.PR = &PullRequest{Number: x.Number, Title: x.Title, URL: x.URL, Draft: x.Draft, ReviewDecision: x.ReviewDecision, MergeState: x.MergeState}
    }
    var runs []struct {
        Name       string `json:"name"`
        Status     string `json:"status"`
        Conclusion string `json:"conclusion"`
        URL        string `json:"url"`
        Event      string `json:"event"`
        CreatedAt  string `json:"createdAt"`
    }
    if err := ghJSON([]string{"run", "list", "--repo", repo, "--branch", branch, "--limit", "1", "--json", "name,status,conclusion,url,event,createdAt"}, &runs); err == nil && len(runs) > 0 {
        x := runs[0]
        st.CI = &CIState{Name: x.Name, Status: x.Status, Conclusion: x.Conclusion, URL: x.URL, Event: x.Event, CreatedAt: x.CreatedAt}
    }
    githubMu.Lock()
    githubCache[key] = githubCacheEntry{At: time.Now(), State: st}
    githubMu.Unlock()
    return st
}

func projectInfo(p string) Project {
    name := filepath.Base(p)
    branch := run("git", "-C", p, "branch", "--show-current")
    if branch == "" {
        return Project{Name: name, Path: p, Branch: "folder"}
    }
    dirtyRaw := run("git", "-C", p, "status", "--porcelain")
    dirtyCount := 0
    if dirtyRaw != "" {
        dirtyCount = len(strings.Split(dirtyRaw, "\n"))
    }
    upstream := run("git", "-C", p, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    ahead, behind := 0, 0
    if upstream != "" {
        f := strings.Fields(run("git", "-C", p, "rev-list", "--left-right", "--count", "HEAD...@{u}"))
        if len(f) >= 2 {
            ahead, behind = atoi(f[0]), atoi(f[1])
        }
    }
    wt := 0
    for _, line := range strings.Split(run("git", "-C", p, "worktree", "list", "--porcelain"), "\n") {
        if strings.HasPrefix(line, "worktree ") {
            wt++
        }
    }
    if wt > 0 {
        wt--
    }
    commits := []Commit{}
    raw := run("git", "-C", p, "log", "-5", "--pretty=format:%h%x09%s%x09%cr")
    for _, line := range strings.Split(raw, "\n") {
        f := strings.SplitN(line, "\t", 3)
        if len(f) == 3 {
            commits = append(commits, Commit{f[0], f[1], f[2]})
        }
    }
    return Project{Name: name, Path: p, Branch: branch, Dirty: dirtyCount > 0, DirtyCount: dirtyCount, Ahead: ahead, Behind: behind, Upstream: upstream, LastActivity: run("git", "-C", p, "log", "-1", "--format=%cr"), Worktrees: wt, Commits: commits, GitHub: githubState(p, branch)}
}
func projects(home string) []Project {
    root := filepath.Join(home, "src")
    es, err := os.ReadDir(root)
    if err != nil {
        return nil
    }
    out := []Project{}
    for _, e := range es {
        if e.IsDir() {
            out = append(out, projectInfo(filepath.Join(root, e.Name())))
        }
    }
    sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
    return out
}
func sessionProject(home, cwd string) string {
    src := filepath.Join(home, "src") + string(os.PathSeparator)
    if strings.HasPrefix(cwd, src) {
        rest := strings.TrimPrefix(cwd, src)
        if i := strings.IndexRune(rest, os.PathSeparator); i >= 0 {
            return rest[:i]
        }
        return rest
    }
    return "workspace"
}
func processState(pid int) string {
    raw := run("ps", "-o", "stat=", "-p", strconv.Itoa(pid))
    if raw == "" {
        return ""
    }
    return string(raw[0])
}
func latestLifecycle(agent, project string) (string, Task, bool, bool) {
    eventMu.Lock()
    defer eventMu.Unlock()
    cutoff := time.Now().Add(-30 * time.Minute)
    for _, e := range events {
        if e.Agent != agent || e.Status == "" || !validLifecycle(e.Status) {
            continue
        }
        if e.Project != "" && project != "" && e.Project != project {
            continue
        }
        t, err := time.Parse(time.RFC3339, e.Time)
        if err == nil && t.Before(cutoff) {
            continue
        }
        attention := e.Status == string(StateWaiting) || e.Status == string(StateBlocked) || e.Status == string(StateFailed)
        return e.Status, e.Task, attention, true
    }
    return "", Task{}, false, false
}
func sessionStatus(agent, project string, pid int) (string, string, Task, bool) {
    if status, task, attention, ok := latestLifecycle(agent, project); ok {
        return status, "agent-event", task, attention
    }
    st := processState(pid)
    if strings.ContainsAny(st, "TZ") || st == "D" {
        return string(StateBlocked), "process-inferred", Task{}, true
    }
    if agent == "hermes" || agent == "herdr" {
        return string(StateBackground), "process-inferred", Task{}, false
    }
    if st == "S" || st == "I" {
        return string(StateWaiting), "process-inferred", Task{}, true
    }
    return string(StateRunning), "process-inferred", Task{}, false
}
func sessions(home string) []Session {
    raw := shell(`ps -eo pid=,etimes=,comm=`)
    out := []Session{}
    for _, line := range strings.Split(raw, "\n") {
        f := strings.Fields(line)
        if len(f) < 3 {
            continue
        }
        agent := filepath.Base(f[2])
        if agent != "claude" && agent != "codex" && agent != "hermes" && agent != "herdr" {
            continue
        }
        pid, sec := atoi(f[0]), atoi(f[1])
        cwd, _ := os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid))
        project := sessionProject(home, cwd)
        status, source, task, attention := sessionStatus(agent, project, pid)
        out = append(out, Session{ID: fmt.Sprintf("%s:%d", agent, pid), Agent: agent, PID: pid, Elapsed: duration(sec), Seconds: sec, Project: project, CWD: cwd, Status: status, Attention: attention, StatusSource: source, Task: task})
    }
    return out
}
func duration(sec int) string {
    d := time.Duration(sec) * time.Second
    if d >= time.Hour {
        return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
    }
    if d >= time.Minute {
        return fmt.Sprintf("%dm", int(d.Minutes()))
    }
    return fmt.Sprintf("%ds", sec)
}

func health() Health {
    mem := atoi(shell(`free | awk '/^Mem:/ {printf "%d", $3*100/$2}'`))
    swap := atoi(shell(`free | awk '/^Swap:/ {if($2>0) printf "%d", $3*100/$2; else print 0}'`))
    disk := atoi(shell(`df --output=pcent / | tail -1 | tr -dc '0-9'`))
    failed := atoi(shell(`systemctl --failed --no-legend 2>/dev/null | wc -l`))
    temp := shell(`for f in /sys/class/hwmon/hwmon*/temp*_input; do [ -r "$f" ] && cat "$f"; done 2>/dev/null | sort -nr | head -1 | awk '{printf "%.0f°C",$1/1000}'`)
    ts := run("tailscale", "ip", "-4")
    ssh := run("systemctl", "is-active", "sshd") == "active"
    krdp := shell(`systemctl --user is-active app-org.kde.krdpserver.service 2>/dev/null`) == "active"
    ollama := run("systemctl", "is-active", "ollama") == "active"
    btrfs := atoi(shell(`sudo -n btrfs device stats / 2>/dev/null | awk '{s+=$NF} END{print s+0}'`))
    alerts := []Alert{}
    if failed > 0 {
        alerts = append(alerts, Alert{"critical", fmt.Sprintf("%d failed systemd units", failed)})
    }
    if disk >= 90 {
        alerts = append(alerts, Alert{"critical", fmt.Sprintf("Root disk %d%% full", disk)})
    } else if disk >= 80 {
        alerts = append(alerts, Alert{"warning", fmt.Sprintf("Root disk %d%% full", disk)})
    }
    if mem >= 90 {
        alerts = append(alerts, Alert{"warning", fmt.Sprintf("Memory pressure %d%%", mem)})
    }
    if ts == "" {
        alerts = append(alerts, Alert{"critical", "Tailscale offline"})
    }
    if !ssh {
        alerts = append(alerts, Alert{"critical", "SSH offline"})
    }
    if !krdp {
        alerts = append(alerts, Alert{"warning", "KRDP inactive"})
    }
    if btrfs > 0 {
        alerts = append(alerts, Alert{"critical", fmt.Sprintf("Btrfs errors %d", btrfs)})
    }
    status := "healthy"
    for _, a := range alerts {
        if a.Level == "critical" {
            status = "critical"
            break
        }
        status = "warning"
    }
    return Health{Status: status, FailedUnits: failed, MemoryPct: mem, SwapPct: swap, DiskPct: disk, CPUtemp: temp, Tailscale: ts, SSH: ssh, KRDP: krdp, Ollama: ollama, BtrfsErrors: btrfs, Alerts: alerts}
}
func resources() []Resource {
    raw := shell(`ps -eo pid=,comm=,rss= --sort=-rss | head -n 9`)
    out := []Resource{}
    for _, line := range strings.Split(raw, "\n") {
        f := strings.Fields(line)
        if len(f) >= 3 {
            out = append(out, Resource{Name: f[1], PID: atoi(f[0]), MB: atoi(f[2]) / 1024})
        }
    }
    return out
}
func models() []Model {
    raw := run("ollama", "ps")
    if raw == "" {
        return nil
    }
    lines := strings.Split(raw, "\n")
    out := []Model{}
    for i, line := range lines {
        if i == 0 || strings.TrimSpace(line) == "" {
            continue
        }
        f := strings.Fields(line)
        if len(f) >= 4 {
            out = append(out, Model{Name: f[0], Size: f[2], Processor: f[len(f)-1]})
        }
    }
    return out
}
func updates() UpdateState {
    ch := strings.TrimSpace(readFile("/etc/agentos/channel"))
    if ch == "" {
        ch = "stable"
    }
    v := strings.TrimSpace(readFile("/etc/agentos/version"))
    if v == "" {
        v = "dev"
    }
    pending := 0
    if _, err := exec.LookPath("checkupdates"); err == nil {
        raw := shell(`checkupdates 2>/dev/null || true`)
        if raw != "" {
            pending = len(strings.Split(raw, "\n"))
        }
    }
    return UpdateState{Channel: ch, Version: v, ArchPending: pending, LastUpdate: strings.TrimSpace(readFile("/var/lib/agentos/last-update"))}
}
func attentionItems(ps []Project, ss []Session, h Health) []AttentionItem {
    out := []AttentionItem{}
    for _, s := range ss {
        if s.Attention {
            text := fmt.Sprintf("%s is %s", s.Agent, s.Status)
            if s.Task.Title != "" {
                text += ": " + s.Task.Title
            }
            out = append(out, AttentionItem{Level: "attention", Kind: "agent", Agent: s.Agent, Project: s.Project, Session: s.ID, Text: text})
        }
    }
    for _, a := range h.Alerts {
        out = append(out, AttentionItem{Level: a.Level, Kind: "system", Text: a.Text})
    }
    for _, p := range ps {
        if p.GitHub.CI != nil && strings.EqualFold(p.GitHub.CI.Status, "completed") && p.GitHub.CI.Conclusion != "" && !strings.EqualFold(p.GitHub.CI.Conclusion, "success") && !strings.EqualFold(p.GitHub.CI.Conclusion, "skipped") {
            out = append(out, AttentionItem{Level: "critical", Kind: "ci", Project: p.Name, Text: fmt.Sprintf("%s CI %s", p.Name, p.GitHub.CI.Conclusion)})
        }
    }
    return out
}
func state(home string) State {
    ps := projects(home)
    ss := sessions(home)
    h := health()
    return State{Host: hostName(), Uptime: strings.TrimPrefix(run("uptime", "-p"), "up "), Load: shell(`awk '{print $1}' /proc/loadavg`), Projects: ps, Sessions: ss, Attention: attentionItems(ps, ss, h), Health: h, Resources: resources(), Models: models(), Updates: updates(), Events: getEvents(), Timestamp: time.Now().Format(time.RFC3339)}
}

func projectPath(home, name string) (string, bool) {
    if name == "" {
        return "", false
    }
    root := filepath.Join(home, "src")
    p := filepath.Clean(filepath.Join(root, name))
    rel, err := filepath.Rel(root, p)
    if err != nil || strings.HasPrefix(rel, "..") {
        return "", false
    }
    st, err := os.Stat(p)
    return p, err == nil && st.IsDir()
}
func envMap(lines []string) map[string]string {
    out := map[string]string{}
    for _, line := range lines {
        if i := strings.IndexByte(line, '='); i > 0 {
            out[line[:i]] = line[i+1:]
        }
    }
    return out
}
func graphicalEnv() map[string]string {
    env := envMap(os.Environ())
    if raw := run("systemctl", "--user", "show-environment"); raw != "" {
        for k, v := range envMap(strings.Split(raw, "\n")) {
            env[k] = v
        }
    }
    pidRaw := shell(`pgrep -n -x plasmashell || true`)
    if pidRaw != "" {
        if b, err := os.ReadFile(filepath.Join("/proc", pidRaw, "environ")); err == nil {
            for k, v := range envMap(strings.Split(string(b), "\x00")) {
                env[k] = v
            }
        }
    }
    return env
}
func spawn(name string, args ...string) error {
    cmd := exec.Command(name, args...)
    cmd.Stdout, cmd.Stderr, cmd.Stdin = nil, nil, nil
    if err := cmd.Start(); err != nil {
        addEvent("error", fmt.Sprintf("%s: %v", name, err))
        return err
    }
    return nil
}
func spawnGUI(name string, args ...string) error {
    env := graphicalEnv()
    keys := []string{"WAYLAND_DISPLAY", "DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "PATH", "HOME", "USER", "SHELL", "XAUTHORITY", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"}
    runArgs := []string{"--user", "--quiet", "--collect", "--property=Type=exec", "--unit", fmt.Sprintf("agentos-ui-%d", time.Now().UnixNano())}
    for _, k := range keys {
        if v := env[k]; v != "" {
            runArgs = append(runArgs, "--setenv="+k+"="+v)
        }
    }
    runArgs = append(runArgs, name)
    runArgs = append(runArgs, args...)
    cmd := exec.Command("systemd-run", runArgs...)
    out, err := cmd.CombinedOutput()
    if err != nil {
        msg := strings.TrimSpace(string(out))
        if msg == "" {
            msg = err.Error()
        }
        addEvent("error", fmt.Sprintf("%s: %s", name, msg))
        return fmt.Errorf("launch %s: %s", name, msg)
    }
    addEvent("launch", fmt.Sprintf("%s via graphical transient service", name))
    return nil
}
func doAction(home string, a Action) error {
    switch a.Name {
    case "terminal":
        return spawnGUI("kitty")
    case "files":
        return spawnGUI("dolphin")
    case "browser":
        return spawnGUI("chromium")
    case "project-open":
        p, ok := projectPath(home, a.Project)
        if !ok {
            return fmt.Errorf("unknown project")
        }
        addTypedEvent(Event{Kind: "project.opened", Project: a.Project, Text: "opened " + a.Project})
        return spawnGUI("kitty", "--directory", p, "-e", "zsh", "-lc", "exec herdr")
    case "project-diff":
        p, ok := projectPath(home, a.Project)
        if !ok {
            return fmt.Errorf("unknown project")
        }
        return spawnGUI("kitty", "--directory", p, "-e", "zsh", "-lc", "git status --short; echo; git diff --stat; echo; git diff; exec zsh")
    case "agent-start":
        if a.Agent != "claude" && a.Agent != "codex" && a.Agent != "hermes" && a.Agent != "herdr" {
            return fmt.Errorf("unknown agent")
        }
        cwd := filepath.Join(home, "src")
        if a.Project != "" {
            if p, ok := projectPath(home, a.Project); ok {
                cwd = p
            } else {
                return fmt.Errorf("unknown project")
            }
        }
        addTypedEvent(Event{Kind: "agent.lifecycle", Agent: a.Agent, Project: a.Project, Status: string(StateStarting), Text: fmt.Sprintf("starting %s", a.Agent)})
        return spawnGUI("kitty", "--directory", cwd, "-e", "zsh", "-lc", "exec "+a.Agent)
    case "agent-stop":
        if a.PID <= 1 {
            return fmt.Errorf("invalid pid")
        }
        p, err := os.FindProcess(a.PID)
        if err != nil {
            return err
        }
        if err := p.Signal(syscall.SIGTERM); err != nil {
            return err
        }
        addTypedEvent(Event{Kind: "agent.lifecycle", Agent: a.Agent, Project: a.Project, Session: fmt.Sprintf("%s:%d", a.Agent, a.PID), Status: string(StateDone), Text: "stop requested"})
        return nil
    case "doctor":
        return spawnGUI("kitty", "-e", "zsh", "-lc", "sudo workstation-doctor; echo; read -k1 '?Press any key to close'")
    case "snapshot":
        return spawnGUI("kitty", "-e", "zsh", "-lc", "sudo btrfs-pre-pacman-snapshot; echo; read -k1 '?Press any key to close'")
    case "sync":
        return spawnGUI("kitty", "-e", "zsh", "-lc", "sync-workstation; echo; read -k1 '?Press any key to close'")
    case "update-check":
        return spawnGUI("kitty", "-e", "zsh", "-lc", "agentos update --check; echo; read -k1 '?Press any key to close'")
    case "restart-krdp":
        addEvent("system", "restarting KRDP")
        return spawn("systemctl", "--user", "restart", "app-org.kde.krdpserver.service")
    case "restart-plasma":
        addEvent("system", "restarting Plasma")
        return spawn("systemctl", "--user", "restart", "plasma-plasmashell.service")
    case "reboot":
        addEvent("system", "reboot requested")
        return spawnGUI("kitty", "-e", "zsh", "-lc", "sudo reboot")
    default:
        return fmt.Errorf("unsupported action")
    }
}

func eventHandler(w http.ResponseWriter, r *http.Request) {
    switch r.Method {
    case http.MethodGet:
        w.Header().Set("Content-Type", "application/json")
        _ = json.NewEncoder(w).Encode(getEvents())
    case http.MethodPost:
        var e Event
        if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
            http.Error(w, "bad event", http.StatusBadRequest)
            return
        }
        if e.Kind == "" {
            http.Error(w, "event kind required", http.StatusBadRequest)
            return
        }
        if e.Status != "" && !validLifecycle(e.Status) {
            http.Error(w, "invalid lifecycle status", http.StatusBadRequest)
            return
        }
        if e.Source == "" {
            e.Source = "adapter"
        }
        addTypedEvent(e)
        w.WriteHeader(http.StatusNoContent)
    default:
        http.Error(w, "GET or POST required", http.StatusMethodNotAllowed)
    }
}

func main() {
    home, _ := os.UserHomeDir()
    initEventStore(home)
    addEvent("system", "agentosd started")
    mux := http.NewServeMux()
    mux.HandleFunc("/v1/healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok\n")) })
    mux.HandleFunc("/v1/state", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        _ = json.NewEncoder(w).Encode(state(home))
    })
    mux.HandleFunc("/v1/events", eventHandler)
    mux.HandleFunc("/v1/action", func(w http.ResponseWriter, r *http.Request) {
        if r.Method != http.MethodPost {
            http.Error(w, "POST required", http.StatusMethodNotAllowed)
            return
        }
        var a Action
        if err := json.NewDecoder(r.Body).Decode(&a); err != nil {
            http.Error(w, "bad request", http.StatusBadRequest)
            return
        }
        if err := doAction(home, a); err != nil {
            http.Error(w, err.Error(), http.StatusBadRequest)
            return
        }
        w.WriteHeader(http.StatusNoContent)
    })
    addr := "127.0.0.1:4787"
    log.Printf("agentosd listening on %s", addr)
    log.Fatal(http.ListenAndServe(addr, mux))
}
