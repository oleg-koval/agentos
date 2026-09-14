package main

import "testing"

func TestGithubRepo(t *testing.T) {
    cases := map[string]string{
        "git@github.com:example/agentos.git":     "example/agentos",
        "https://github.com/example/agentos.git": "example/agentos",
        "ssh://git@github.com/example/agentos.git": "example/agentos",
        "https://gitlab.com/example/project.git":            "",
        "":                                                   "",
    }
    for input, want := range cases {
        if got := githubRepo(input); got != want {
            t.Fatalf("githubRepo(%q) = %q, want %q", input, got, want)
        }
    }
}

func TestDuration(t *testing.T) {
    cases := map[int]string{5: "5s", 65: "1m", 3661: "1h01m"}
    for seconds, want := range cases {
        if got := duration(seconds); got != want {
            t.Fatalf("duration(%d) = %q, want %q", seconds, got, want)
        }
    }
}

func TestValidLifecycle(t *testing.T) {
    for _, state := range []string{"STARTING", "RUNNING", "THINKING", "TOOL", "WAITING", "BLOCKED", "BACKGROUND", "DONE", "FAILED", "waiting"} {
        if !validLifecycle(state) {
            t.Fatalf("expected lifecycle state %q to be valid", state)
        }
    }
    if validLifecycle("SLEEPING") {
        t.Fatal("unexpected lifecycle state accepted")
    }
}

func TestAttentionItems(t *testing.T) {
    sessions := []Session{{ID: "codex:42", Agent: "codex", Project: "repo", Status: "WAITING", Attention: true, Task: Task{Title: "Need approval"}}}
    projects := []Project{{Name: "repo", GitHub: GitHubState{CI: &CIState{Status: "completed", Conclusion: "failure"}}}}
    health := Health{Alerts: []Alert{{Level: "warning", Text: "Disk pressure"}}}
    got := attentionItems(projects, sessions, health)
    if len(got) != 3 {
        t.Fatalf("attentionItems length = %d, want 3", len(got))
    }
    if got[0].Kind != "agent" || got[1].Kind != "system" || got[2].Kind != "ci" {
        t.Fatalf("unexpected attention ordering: %#v", got)
    }
}
