package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	configSchema = "agentos.config/v1"
	stateSchema  = "agentos.config-state/v1"
)

type Config struct {
	Version      int             `json:"version"`
	Channel      string          `json:"channel"`
	RemoteAccess RemoteAccess    `json:"remote_access"`
	Agents       map[string]bool `json:"agents"`
	Models       map[string]bool `json:"models"`
	ProjectRoots []string        `json:"project_roots"`
	Backup       BackupPolicy    `json:"backup"`
	Power        PowerPolicy     `json:"power"`
}
type RemoteAccess struct {
	SSH       bool `json:"ssh"`
	Tailscale bool `json:"tailscale"`
	KRDP      bool `json:"krdp"`
}
type BackupPolicy struct {
	Enabled  bool   `json:"enabled"`
	Schedule string `json:"schedule"`
	Target   string `json:"target"`
}
type PowerPolicy struct {
	Sleep     string `json:"sleep"`
	Hibernate string `json:"hibernate"`
}
type StateFile struct {
	Schema     string `json:"schema"`
	Version    int    `json:"version"`
	ConfigHash string `json:"config_hash"`
	AppliedAt  string `json:"applied_at"`
}
type Diff struct {
	Path    string      `json:"path"`
	Type    string      `json:"type"`
	Desired interface{} `json:"desired"`
	Actual  interface{} `json:"actual"`
	State   string      `json:"state"`
	Action  string      `json:"action,omitempty"`
}
type Plan struct {
	Schema     string `json:"schema"`
	Version    int    `json:"version"`
	Mode       string `json:"mode"`
	Config     string `json:"config"`
	ConfigHash string `json:"config_hash"`
	State      string `json:"state"`
	Migration  string `json:"migration"`
	Changes    []Diff `json:"changes"`
}

func main() {
	configPath := flag.String("config", envOr("AGENTOS_CONFIG", "/etc/agentos/config.yaml"), "desired configuration")
	statePath := flag.String("state", envOr("AGENTOS_CONFIG_STATE", "/var/lib/agentos/config-state.json"), "applied state")
	flag.Parse()
	if flag.NArg() != 1 || (flag.Arg(0) != "plan" && flag.Arg(0) != "apply" && flag.Arg(0) != "mark-applied") {
		fmt.Fprintln(os.Stderr, "Usage: agentos-config [--config PATH] [--state PATH] plan|apply|mark-applied")
		os.Exit(2)
	}
	cfg, hash, err := readConfig(*configPath)
	if err != nil {
		fatal(err)
	}
	if err := validateConfig(cfg); err != nil {
		fatal(err)
	}
	if flag.Arg(0) == "mark-applied" {
		if err := writeState(*statePath, cfg.Version, hash); err != nil {
			fatal(err)
		}
		fmt.Printf("applied config version %d (%s)\n", cfg.Version, hash)
		return
	}
	plan := makePlan(cfg, hash, flag.Arg(0), *configPath, *statePath)
	if flag.Arg(0) == "apply" {
		// Applying mutations is deliberately owned by agentos-cli.sh. This command
		// remains a pure validator/plan producer so no action can run before the
		// complete document is parsed and validated.
		plan.Mode = "apply"
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(plan); err != nil {
		fatal(err)
	}
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
func fatal(err error) { fmt.Fprintln(os.Stderr, "agentos-config:", err); os.Exit(1) }

func readConfig(path string) (Config, string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, "", fmt.Errorf("read %s: %w", path, err)
	}
	cfg, err := parseYAML(string(data))
	if err != nil {
		return Config{}, "", fmt.Errorf("parse %s: %w", path, err)
	}
	h := sha256.Sum256(data)
	return cfg, hex.EncodeToString(h[:]), nil
}

func parseYAML(text string) (Config, error) {
	var cfg Config
	cfg.Agents = map[string]bool{}
	cfg.Models = map[string]bool{}
	seen := map[string]bool{}
	section := ""
	var err error
	scanner := bufio.NewScanner(strings.NewReader(text))
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		raw := strings.TrimRight(scanner.Text(), "\r")
		if strings.Contains(raw, "\t") {
			return cfg, fmt.Errorf("line %d: tabs are not supported; use spaces", lineNo)
		}
		line := stripComment(raw)
		if strings.TrimSpace(line) == "" {
			continue
		}
		indent := len(line) - len(strings.TrimLeft(line, " "))
		if indent%2 != 0 {
			return cfg, fmt.Errorf("line %d: indentation must use two-space levels", lineNo)
		}
		content := strings.TrimSpace(line)
		if indent == 0 {
			key, value, ok := splitYAMLKey(content)
			if !ok {
				return cfg, fmt.Errorf("line %d: expected key: value", lineNo)
			}
			if value == "" {
				if !allowedSection(key) {
					return cfg, fmt.Errorf("line %d: unknown section %q", lineNo, key)
				}
				if seen[key] {
					return cfg, fmt.Errorf("line %d: duplicate section %q", lineNo, key)
				}
				seen[key] = true
				section = key
				continue
			}
			if section != "" {
				section = ""
			}
			if seen[key] {
				return cfg, fmt.Errorf("line %d: duplicate key %q", lineNo, key)
			}
			seen[key] = true
			switch key {
			case "version":
				cfg.Version, err = parseInt(value)
			case "channel":
				cfg.Channel, err = parseString(value)
			default:
				err = fmt.Errorf("line %d: unknown key %q", lineNo, key)
			}
			if err != nil {
				return cfg, fmt.Errorf("line %d: %w", lineNo, err)
			}
			continue
		}
		if section == "project_roots" {
			if indent != 2 || !strings.HasPrefix(content, "-") {
				return cfg, fmt.Errorf("line %d: project_roots must be a list", lineNo)
			}
			value := strings.TrimSpace(strings.TrimPrefix(content, "-"))
			if value == "" {
				return cfg, fmt.Errorf("line %d: empty project root", lineNo)
			}
			root, e := parseString(value)
			if e != nil {
				return cfg, fmt.Errorf("line %d: %w", lineNo, e)
			}
			cfg.ProjectRoots = append(cfg.ProjectRoots, root)
			continue
		}
		if indent != 2 {
			return cfg, fmt.Errorf("line %d: nested indentation is not supported", lineNo)
		}
		key, value, ok := splitYAMLKey(content)
		if !ok || value == "" {
			return cfg, fmt.Errorf("line %d: expected section key: value", lineNo)
		}
		full := section + "." + key
		if seen[full] {
			return cfg, fmt.Errorf("line %d: duplicate key %q", lineNo, full)
		}
		seen[full] = true
		switch section {
		case "agents", "models":
			v, e := parseBool(value)
			if e != nil {
				err = e
			} else if section == "agents" {
				cfg.Agents[key] = v
			} else {
				cfg.Models[key] = v
			}
		case "remote_access":
			err = setRemote(&cfg.RemoteAccess, key, value)
		case "backup":
			err = setBackup(&cfg.Backup, key, value)
		case "power":
			err = setPower(&cfg.Power, key, value)
		default:
			err = fmt.Errorf("line %d: section %q cannot contain values", lineNo, section)
		}
		if err != nil {
			return cfg, fmt.Errorf("line %d: %w", lineNo, err)
		}
	}
	if err := scanner.Err(); err != nil {
		return cfg, err
	}
	for _, key := range []string{"version", "channel", "remote_access", "agents", "models", "project_roots", "backup", "power"} {
		if !seen[key] {
			return cfg, fmt.Errorf("missing required key or section %q", key)
		}
	}
	for _, key := range []string{"ssh", "tailscale", "krdp"} {
		if !seen["remote_access."+key] {
			return cfg, fmt.Errorf("missing required key %q", "remote_access."+key)
		}
	}
	for _, key := range []string{"enabled", "schedule", "target"} {
		if !seen["backup."+key] {
			return cfg, fmt.Errorf("missing required key %q", "backup."+key)
		}
	}
	for _, key := range []string{"sleep", "hibernate"} {
		if !seen["power."+key] {
			return cfg, fmt.Errorf("missing required key %q", "power."+key)
		}
	}
	return cfg, nil
}

func stripComment(s string) string {
	quoted := false
	for i, r := range s {
		if r == '"' {
			quoted = !quoted
		}
		if r == '#' && !quoted {
			return s[:i]
		}
	}
	return s
}
func splitYAMLKey(s string) (string, string, bool) {
	i := strings.IndexByte(s, ':')
	if i < 1 {
		return "", "", false
	}
	return strings.TrimSpace(s[:i]), strings.TrimSpace(s[i+1:]), true
}
func allowedSection(s string) bool {
	switch s {
	case "remote_access", "agents", "models", "project_roots", "backup", "power":
		return true
	}
	return false
}
func parseString(s string) (string, error) {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return strconv.Unquote(s)
	}
	if strings.ContainsAny(s, "\t\r\n") {
		return "", errors.New("invalid string")
	}
	return s, nil
}
func parseInt(s string) (int, error) {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("invalid integer %q", s)
	}
	return n, nil
}
func parseBool(s string) (bool, error) {
	switch strings.ToLower(s) {
	case "true":
		return true, nil
	case "false":
		return false, nil
	}
	return false, fmt.Errorf("invalid boolean %q", s)
}
func setRemote(r *RemoteAccess, key, value string) error {
	v, err := parseBool(value)
	if err != nil {
		return err
	}
	switch key {
	case "ssh":
		r.SSH = v
	case "tailscale":
		r.Tailscale = v
	case "krdp":
		r.KRDP = v
	default:
		return fmt.Errorf("unknown remote_access key %q", key)
	}
	return nil
}
func setBackup(b *BackupPolicy, key, value string) error {
	switch key {
	case "enabled":
		v, e := parseBool(value)
		b.Enabled = v
		return e
	case "schedule":
		v, e := parseString(value)
		b.Schedule = v
		return e
	case "target":
		v, e := parseString(value)
		b.Target = v
		return e
	default:
		return fmt.Errorf("unknown backup key %q", key)
	}
}
func setPower(p *PowerPolicy, key, value string) error {
	v, e := parseString(value)
	if e != nil {
		return e
	}
	switch key {
	case "sleep":
		p.Sleep = v
	case "hibernate":
		p.Hibernate = v
	default:
		return fmt.Errorf("unknown power key %q", key)
	}
	return nil
}

func validateConfig(c Config) error {
	if c.Version != 1 {
		return fmt.Errorf("unsupported config version %d (expected 1)", c.Version)
	}
	if c.Channel != "stable" && c.Channel != "beta" && c.Channel != "edge" && c.Channel != "none" {
		return fmt.Errorf("channel must be stable, beta, edge, or none")
	}
	if c.Backup.Schedule != "quick" && c.Backup.Schedule != "full" && c.Backup.Schedule != "weekly" {
		return fmt.Errorf("backup.schedule must be quick, full, or weekly")
	}
	if c.Backup.Enabled && c.Backup.Target == "" {
		return errors.New("backup.target is required when backup.enabled is true")
	}
	if c.Backup.Target != "" && !filepath.IsAbs(c.Backup.Target) {
		return errors.New("backup.target must be an absolute path")
	}
	if c.Power.Sleep != "disabled" || c.Power.Hibernate != "disabled" {
		return errors.New("power.sleep and power.hibernate must be disabled on AgentOS always-on systems")
	}
	for i, root := range c.ProjectRoots {
		if !filepath.IsAbs(root) {
			return fmt.Errorf("project_roots[%d] must be an absolute path", i)
		}
	}
	return nil
}

func makePlan(c Config, hash, mode, configPath, statePath string) Plan {
	p := Plan{Schema: configSchema, Version: c.Version, Mode: mode, Config: configPath, ConfigHash: hash, State: "converged", Migration: "none", Changes: []Diff{}}
	add := func(path, typ string, desired, actual interface{}, action string) {
		state := "satisfied"
		if fmt.Sprint(desired) != fmt.Sprint(actual) {
			state = "pending"
			p.State = "pending"
		}
		p.Changes = append(p.Changes, Diff{Path: path, Type: typ, Desired: desired, Actual: actual, State: state, Action: action})
	}
	add("channel", "enum", c.Channel, readFile(envOr("AGENTOS_CHANNEL_FILE", "/etc/agentos/channel"), "stable"), "channel")
	add("remote_access.ssh", "bool", c.RemoteAccess.SSH, commandOK("systemctl", "is-active", "sshd"), "remote-validate")
	add("remote_access.tailscale", "bool", c.RemoteAccess.Tailscale, commandOK("tailscale", "ip", "-4"), "remote-validate")
	add("remote_access.krdp", "bool", c.RemoteAccess.KRDP, commandOK("systemctl", "--user", "is-active", "app-org.kde.krdpserver.service"), "remote-krdp")
	for _, id := range sortedKeys(c.Agents) {
		add("agents."+id, "bool", c.Agents[id], capabilityActual(id, false), "capability:"+id)
	}
	for _, id := range sortedKeys(c.Models) {
		add("models."+id, "bool", c.Models[id], capabilityActual(id, true), "capability:"+id)
	}
	for _, root := range c.ProjectRoots {
		add("project_roots."+root, "path", true, dirExists(root), "project-root")
	}
	add("backup.enabled", "bool", c.Backup.Enabled, backupActual(c.Backup.Target), "backup")
	desiredBackupSchedule := c.Backup.Schedule
	if !c.Backup.Enabled {
		desiredBackupSchedule = "disabled"
	}
	add("backup.schedule", "enum", desiredBackupSchedule, backupScheduleActual(), "backup")
	add("backup.target", "path", c.Backup.Target, c.Backup.Target, "")
	add("power.sleep", "enum", c.Power.Sleep, powerActual("sleep"), "power")
	add("power.hibernate", "enum", c.Power.Hibernate, powerActual("hibernate"), "power")
	p.Migration = stateMigration(statePath, c.Version, hash)
	return p
}

func stateMigration(path string, version int, hash string) string {
	prior, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "initial"
	}
	if err != nil {
		return "state-unreadable"
	}
	var state StateFile
	if err := json.Unmarshal(prior, &state); err != nil {
		return "state-invalid"
	}
	if state.Schema != stateSchema {
		return "state-schema-mismatch"
	}
	if state.Version != version {
		return "state-version-mismatch"
	}
	if state.ConfigHash != hash {
		return "desired-config-changed"
	}
	return "none"
}

func sortedKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
func readFile(path, fallback string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return fallback
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return fallback
	}
	return value
}
func commandOK(name string, args ...string) bool {
	_, err := exec.LookPath(name)
	if err != nil {
		return false
	}
	return exec.Command(name, args...).Run() == nil
}
func dirExists(path string) bool { info, err := os.Stat(path); return err == nil && info.IsDir() }
func capabilityActual(id string, model bool) bool {
	if model {
		if !commandOK("ollama", "list") {
			return false
		}
		out, err := exec.Command("ollama", "list").Output()
		if err != nil {
			return false
		}
		actual := string(out)
		if strings.Contains(actual, id) {
			return true
		}
		aliases := map[string]string{"qwen-coder": "qwen2.5-coder:7b", "gemma": "gemma4:e4b"}
		return strings.Contains(actual, aliases[id])
	}
	return commandOK(id, "--version") || commandOK(id, "version")
}
func backupActual(target string) bool {
	if target == "" {
		target = envOr("HERMES_BACKUP_AGE_RECIPIENTS", filepath.Join(envOr("HOME", ""), ".config/agentos/hermes-backup-recipients.txt"))
		legacy := filepath.Join(envOr("HOME", ""), ".config/legacy-workstation/hermes-backup-recipients.txt")
		if !fileNonEmpty(target) && fileNonEmpty(legacy) {
			target = legacy
		}
	}
	return fileNonEmpty(target) && commandOK("systemctl", "--user", "is-enabled", "hermes-backup-quick.timer")
}
func backupScheduleActual() string {
	if commandOK("systemctl", "--user", "is-enabled", "hermes-backup-full.timer") {
		return "full"
	}
	if commandOK("systemctl", "--user", "is-enabled", "hermes-backup-quick.timer") {
		return "quick"
	}
	return "disabled"
}
func fileNonEmpty(path string) bool { info, err := os.Stat(path); return err == nil && info.Size() > 0 }
func powerActual(kind string) string {
	path := envOr("AGENTOS_SLEEP_POLICY_FILE", "/etc/systemd/sleep.conf.d/10-agentos-always-on.conf")
	data, err := os.ReadFile(path)
	setting := map[string]string{"sleep": "AllowSuspend=no", "hibernate": "AllowHibernation=no"}[kind]
	if err == nil && setting != "" && strings.Contains(string(data), setting) {
		return "disabled"
	}
	return "enabled"
}
func writeState(path string, version int, hash string) error {
	state := StateFile{Schema: stateSchema, Version: version, ConfigHash: hash, AppliedAt: time.Now().UTC().Format(time.RFC3339)}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
