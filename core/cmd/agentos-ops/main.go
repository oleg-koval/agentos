// Command agentos-ops contains the typed policy/runtime operations that used
// to be implemented by several Bash entrypoints.  The installed shell files
// are compatibility shims; all parsing, state transitions, and policy checks
// live here so the same behavior is used by packages and source checkouts.
package main

import (
	"agentos/core/internal/maintenance"
	"agentos/core/internal/recovery"
	"agentos/core/internal/updatestate"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type envConfig struct {
	channelFile string
	versionFile string
	repoState   string
	pacmanConf  string
	pacmanInc   string
	registry    string
	config      string
	configState string
	stateRoot   string
}

func configFromEnv() envConfig {
	root := env("AGENTOS_STATE_DIR", "/var/lib/agentos")
	registry := os.Getenv("AGENTOS_CAPABILITIES_FILE")
	if registry == "" {
		registry = "/usr/share/agentos/registry/capabilities.json"
		if _, err := os.Stat(registry); err != nil {
			registry = filepath.Join(repoRoot(), "registry/capabilities.json")
		}
	}
	return envConfig{
		channelFile: env("AGENTOS_CHANNEL_FILE", "/etc/agentos/channel"),
		versionFile: env("AGENTOS_VERSION_FILE", "/etc/agentos/version"),
		repoState:   env("AGENTOS_REPOSITORY_STATE", filepath.Join(root, "repository.json")),
		pacmanConf:  env("AGENTOS_PACMAN_CONF", env("PACMAN_CONF", "/etc/pacman.conf")),
		pacmanInc:   env("AGENTOS_PACMAN_INCLUDE", "/etc/pacman.d/agentos.conf"),
		registry:    registry,
		config:      env("AGENTOS_CONFIG", "/etc/agentos/config.yaml"),
		configState: env("AGENTOS_CONFIG_STATE", filepath.Join(root, "config-state.json")),
		stateRoot:   env("AGENTOS_TRANSACTION_ROOT", filepath.Join(homeDir(), ".local/share/agentos/generations")),
	}
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func homeDir() string {
	if value := os.Getenv("HOME"); value != "" {
		return value
	}
	if current, err := user.Current(); err == nil {
		return current.HomeDir
	}
	return "/"
}

func workstationUser() string {
	if value := os.Getenv("AGENTOS_WORKSTATION_USER"); value != "" {
		return value
	}
	if value := os.Getenv("WORKSTATION_USER"); value != "" {
		return value
	}
	if value := os.Getenv("SUDO_USER"); value != "" {
		return value
	}
	for _, configPath := range []string{"/etc/agentos/host.conf", "/etc/legacy-workstation.conf"} {
		data, err := os.ReadFile(configPath)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "WORKSTATION_USER=") {
				return strings.Trim(strings.TrimPrefix(line, "WORKSTATION_USER="), "\"'")
			}
		}
	}
	return os.Getenv("USER")
}

func userSystemctl(args ...string) (string, error) {
	username := workstationUser()
	if os.Geteuid() == 0 && username != "" {
		if current, err := user.Lookup(username); err == nil {
			runtime := "/run/user/" + current.Uid
			if _, err := exec.LookPath("runuser"); err == nil {
				envArgs := []string{"-u", username, "--", "env", "HOME=" + current.HomeDir, "XDG_RUNTIME_DIR=" + runtime, "DBUS_SESSION_BUS_ADDRESS=unix:path=" + runtime + "/bus", "systemctl", "--user"}
				return run("runuser", append(envArgs, args...)...)
			}
		}
	}
	return run("systemctl", append([]string{"--user"}, args...)...)
}

func userSystemctlOK(args ...string) bool {
	_, err := userSystemctl(args...)
	return err == nil
}

func runUserSystemctlAndPrint(args ...string) error {
	output, err := userSystemctl(args...)
	if output != "" {
		fmt.Println(output)
	}
	return err
}

func repoRoot() string {
	if value := os.Getenv("AGENTOS_REPO_ROOT"); value != "" {
		return value
	}
	if value := os.Getenv("LEGACY_WORKSTATION_REPO_ROOT"); value != "" {
		return value
	}
	for _, candidate := range []string{"registry/capabilities.json", "../registry/capabilities.json"} {
		if _, err := os.Stat(candidate); err == nil {
			return filepath.Dir(filepath.Dir(candidate))
		}
	}
	if executable, err := os.Executable(); err == nil {
		return filepath.Clean(filepath.Join(filepath.Dir(executable), "../../../.."))
	}
	return "."
}

func run(name string, args ...string) (string, error) {
	command := exec.Command(name, args...)
	output, err := command.CombinedOutput()
	return strings.TrimSpace(string(output)), err
}

func commandOK(name string, args ...string) bool {
	if _, err := exec.LookPath(name); err != nil {
		return false
	}
	_, err := run(name, args...)
	return err == nil
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".agentos-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func writePrivileged(path string, data []byte, mode os.FileMode) error {
	if err := writeAtomic(path, data, mode); err == nil {
		return nil
	}
	command := exec.Command("sudo", "tee", path)
	command.Stdin = strings.NewReader(string(data))
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("write %s: %s", path, strings.TrimSpace(string(output)))
	}
	return nil
}

type capabilityRegistry struct {
	Capabilities []capability `json:"capabilities"`
}
type capability struct {
	ID        string   `json:"id"`
	Kind      string   `json:"kind"`
	Installer string   `json:"installer"`
	Packages  []string `json:"packages"`
	Provider  string   `json:"provider"`
	Ollama    string   `json:"ollama"`
}

func readRegistry(path string) (map[string]capability, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("capability registry: %w", err)
	}
	var registry capabilityRegistry
	if err := json.Unmarshal(data, &registry); err != nil {
		return nil, fmt.Errorf("invalid capability registry: %w", err)
	}
	result := make(map[string]capability, len(registry.Capabilities))
	for _, item := range registry.Capabilities {
		if item.ID == "" || item.Kind == "" {
			return nil, errors.New("invalid capability registry: each capability needs id and kind")
		}
		if _, exists := result[item.ID]; exists {
			return nil, fmt.Errorf("invalid capability registry: duplicate %s", item.ID)
		}
		result[item.ID] = item
	}
	return result, nil
}

func capabilityIDs(reg map[string]capability, requested []string) ([]string, error) {
	if len(requested) > 0 {
		for _, id := range requested {
			if _, ok := reg[id]; !ok {
				return nil, fmt.Errorf("Unknown capability: %s", id)
			}
		}
		return requested, nil
	}
	ids := make([]string, 0, len(reg))
	for id := range reg {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids, nil
}

func capabilitySatisfied(item capability) bool {
	if item.Provider != "" {
		return true
	}
	if item.Kind == "agent" {
		return commandOK(item.ID, "--version") || commandOK(item.ID, "version")
	}
	if item.Ollama != "" {
		output, err := run("ollama", "list")
		return err == nil && (strings.Contains(output, item.Ollama) ||
			(item.ID == "qwen-coder" && strings.Contains(output, "qwen2.5-coder:7b")) ||
			(item.ID == "gemma" && strings.Contains(output, "gemma4:e4b")))
	}
	if item.Kind == "capability" {
		for _, packageName := range item.Packages {
			if !commandOK("pacman", "-Q", packageName) {
				return false
			}
		}
		return len(item.Packages) > 0
	}
	return false
}

func listCapabilities(c envConfig) error {
	registry, err := readRegistry(c.registry)
	if err != nil {
		return err
	}
	labels := map[string]string{"agent": "Agents:", "capability": "Capabilities:", "model": "Models:", "workflow": "Workflows:"}
	for _, kind := range []string{"agent", "capability", "model", "workflow"} {
		ids := make([]string, 0)
		for id, item := range registry {
			if item.Kind == kind {
				ids = append(ids, id)
			}
		}
		sort.Strings(ids)
		if len(ids) > 0 {
			fmt.Printf("%-14s%s\n", labels[kind], strings.Join(ids, " "))
		}
	}
	return nil
}

func installCapability(item capability) error {
	if item.Installer == "agent-tools" {
		// Pass the registry ID unchanged so a store install cannot silently
		// install every agent or select a different tool than requested.
		return runAndPrint("install-agent-tools", "--agent", item.ID)
	}
	if item.Ollama != "" {
		return runAndPrint("ollama", "pull", item.Ollama)
	}
	if len(item.Packages) > 0 && item.Kind == "capability" {
		args := append([]string{"pacman", "-S", "--needed"}, item.Packages...)
		return runAndPrint("sudo", args...)
	}
	if item.Provider != "" {
		if item.Kind == "workflow" {
			fmt.Printf("%s workflow is available through Hermes/Herdr project automation.\n", item.ID)
		} else {
			fmt.Printf("%s is provided through agent integrations; use the relevant agent/tooling setup.\n", item.ID)
		}
		return nil
	}
	return fmt.Errorf("no installer is defined for capability: %s", item.ID)
}

func runAndPrint(name string, args ...string) error {
	output, err := run(name, args...)
	if output != "" {
		fmt.Println(output)
	}
	return err
}

func runAgentOSHelper(name string, args ...string) error {
	if _, err := exec.LookPath(name); err == nil {
		return runAndPrint(name, args...)
	}
	sourcePath := filepath.Join(repoRoot(), name+".sh")
	if _, err := os.Stat(sourcePath); err == nil {
		return runAndPrint("bash", append([]string{sourcePath}, args...)...)
	}
	return runAndPrint(name, args...)
}

func planCapabilities(c envConfig, requested []string) error {
	registry, err := readRegistry(c.registry)
	if err != nil {
		return err
	}
	ids, err := capabilityIDs(registry, requested)
	if err != nil {
		return err
	}
	for _, id := range ids {
		state := "pending"
		if registry[id].Provider != "" {
			state = "provided"
		} else if capabilitySatisfied(registry[id]) {
			state = "satisfied"
		}
		fmt.Printf("%s: %s\n", id, state)
	}
	return nil
}

func applyCapabilities(c envConfig, requested []string) error {
	registry, err := readRegistry(c.registry)
	if err != nil {
		return err
	}
	ids, err := capabilityIDs(registry, requested)
	if err != nil {
		return err
	}
	for _, id := range ids {
		item := registry[id]
		if item.Provider != "" || capabilitySatisfied(item) {
			state := "satisfied"
			if item.Provider != "" {
				state = "provided"
			}
			fmt.Printf("%s: skipped (%s)\n", id, state)
			continue
		}
		if err := installCapability(item); err != nil {
			return err
		}
		fmt.Printf("%s: applied\n", id)
	}
	return nil
}

type configChange struct {
	Path    string      `json:"path"`
	Type    string      `json:"type,omitempty"`
	Desired interface{} `json:"desired"`
	Actual  interface{} `json:"actual,omitempty"`
	State   string      `json:"state"`
	Action  string      `json:"action"`
}
type configPlan struct {
	Schema     string         `json:"schema"`
	Version    int            `json:"version"`
	Mode       string         `json:"mode"`
	Config     string         `json:"config"`
	ConfigHash string         `json:"config_hash"`
	State      string         `json:"state"`
	Migration  string         `json:"migration"`
	Changes    []configChange `json:"changes"`
}

func configHelper(c envConfig) string {
	if value := os.Getenv("AGENTOS_CONFIG_HELPER"); value != "" {
		return value
	}
	if value, err := exec.LookPath("agentos-config"); err == nil {
		return value
	}
	if _, err := os.Stat("/usr/bin/agentos-config"); err == nil {
		return "/usr/bin/agentos-config"
	}
	return filepath.Join(repoRoot(), ".agentos-config")
}

func configInitializer(c envConfig) string {
	if value := os.Getenv("AGENTOS_CONFIG_INIT_HELPER"); value != "" {
		return value
	}
	if _, err := os.Stat("/usr/lib/agentos/ensure-agentos-config"); err == nil {
		return "/usr/lib/agentos/ensure-agentos-config"
	}
	return filepath.Join(repoRoot(), "ensure-agentos-config.sh")
}

func runWithEnv(name string, values []string, args ...string) (string, error) {
	command := exec.Command(name, args...)
	command.Env = append(os.Environ(), values...)
	output, err := command.CombinedOutput()
	return strings.TrimSpace(string(output)), err
}

func initializeConfig(c envConfig) error {
	helper := configInitializer(c)
	if _, err := os.Stat(helper); err != nil {
		return fmt.Errorf("AgentOS config initializer is unavailable: %s", helper)
	}
	_, beforeErr := os.Lstat(c.config)
	args := []string{"AGENTOS_CONFIG_FILE=" + c.config, helper}
	var output string
	var err error
	if os.Geteuid() == 0 {
		output, err = runWithEnv("env", nil, args...)
	} else {
		output, err = runWithEnv("sudo", nil, append([]string{"env"}, args...)...)
	}
	if output != "" {
		fmt.Println(output)
	}
	if err != nil {
		return err
	}
	if _, err := os.Lstat(c.config); err != nil {
		return fmt.Errorf("AgentOS config initializer did not create %s", c.config)
	}
	if beforeErr == nil {
		fmt.Printf("AgentOS config already exists; left unchanged: %s\n", c.config)
	} else {
		fmt.Printf("AgentOS first-run config ready: %s\n", c.config)
	}
	return nil
}

func readConfigPlan(c envConfig) (configPlan, error) {
	helper := configHelper(c)
	output, err := run(helper, "--config", c.config, "--state", c.configState, "plan")
	if err != nil {
		return configPlan{}, fmt.Errorf("agentos-config plan: %s", output)
	}
	var plan configPlan
	if err := json.Unmarshal([]byte(output), &plan); err != nil || plan.Schema != "agentos.config/v1" {
		return configPlan{}, errors.New("agentos config helper returned an invalid plan")
	}
	return plan, nil
}

func boolValue(value interface{}) bool {
	b, _ := value.(bool)
	return b
}

func applyConfig(c envConfig) error {
	plan, err := readConfigPlan(c)
	if err != nil {
		return err
	}
	registry, err := readRegistry(c.registry)
	if err != nil {
		return err
	}
	for _, change := range plan.Changes {
		if change.State != "pending" || !strings.HasPrefix(change.Action, "capability:") {
			continue
		}
		id := strings.TrimPrefix(change.Action, "capability:")
		if _, ok := registry[id]; !ok {
			return fmt.Errorf("Unknown capability: %s", id)
		}
		if !boolValue(change.Desired) {
			return fmt.Errorf("cannot disable capability through config: %s", id)
		}
	}
	for _, change := range plan.Changes {
		if change.State != "pending" {
			continue
		}
		switch {
		case strings.HasPrefix(change.Action, "capability:"):
			if err := applyCapabilities(c, []string{strings.TrimPrefix(change.Action, "capability:")}); err != nil {
				return err
			}
		case change.Action == "channel":
			value, ok := change.Desired.(string)
			if !ok || (value != "stable" && value != "beta" && value != "edge" && value != "none") {
				return errors.New("invalid AgentOS channel")
			}
			if err := writePrivileged(c.channelFile, []byte(value+"\n"), 0o644); err != nil {
				return err
			}
		case change.Action == "remote-validate":
			return fmt.Errorf("required remote access is not currently healthy: %s", change.Path)
		case change.Action == "remote-krdp":
			value, ok := change.Desired.(bool)
			if !ok {
				return errors.New("remote_access.krdp must be boolean")
			}
			mode := "--disable"
			if value {
				mode = "--enable"
			}
			if err := runAndPrint("agentos-remote-desktop", mode); err != nil {
				return err
			}
		case change.Action == "project-root":
			return fmt.Errorf("project root is missing: %s", strings.TrimPrefix(change.Path, "project_roots."))
		case change.Action == "power":
			if err := runAndPrint("sudo", "agentos-power-policy", "apply"); err != nil {
				return err
			}
		case change.Action == "backup":
			if err := applyBackupPolicy(plan); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unknown config action: %s", change.Action)
		}
	}
	helper := configHelper(c)
	if _, err := run(helper, "--config", c.config, "--state", c.configState, "mark-applied"); err != nil {
		if _, sudoErr := run("sudo", helper, "--config", c.config, "--state", c.configState, "mark-applied"); sudoErr != nil {
			return err
		}
	}
	plan.State = "applied"
	encoded, _ := json.MarshalIndent(plan, "", "  ")
	fmt.Println(string(encoded))
	return nil
}

func applyBackupPolicy(plan configPlan) error {
	schedule := "disabled"
	enabled := false
	for _, change := range plan.Changes {
		switch change.Path {
		case "backup.schedule":
			schedule, _ = change.Desired.(string)
		case "backup.enabled":
			enabled = boolValue(change.Desired)
		}
	}
	if !enabled {
		schedule = "disabled"
	}
	if err := runAndPrint("sudo", "systemctl", "--global", "disable", "hermes-backup-quick.timer", "hermes-backup-full.timer"); err != nil {
		return err
	}
	if err := runUserSystemctlAndPrint("disable", "--now", "hermes-backup-quick.timer", "hermes-backup-full.timer"); err != nil {
		return err
	}
	switch schedule {
	case "quick":
		return runUserSystemctlAndPrint("enable", "--now", "hermes-backup-quick.timer")
	case "full":
		return runUserSystemctlAndPrint("enable", "--now", "hermes-backup-full.timer")
	case "weekly":
		return runUserSystemctlAndPrint("enable", "--now", "hermes-backup-quick.timer", "hermes-backup-full.timer")
	case "disabled":
		return nil
	default:
		return fmt.Errorf("invalid backup schedule: %s", schedule)
	}
}

func configCommand(c envConfig, args []string) error {
	if len(args) == 0 {
		args = []string{"plan"}
	}
	configPath, statePath := c.config, c.configState
	filtered := []string{}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--config", "--state":
			if i+1 >= len(args) {
				return fmt.Errorf("%s requires a path", args[i])
			}
			if args[i] == "--config" {
				configPath = args[i+1]
			} else {
				statePath = args[i+1]
			}
			i++
		default:
			filtered = append(filtered, args[i])
		}
	}
	c.config, c.configState = configPath, statePath
	if len(filtered) != 1 || (filtered[0] != "init" && filtered[0] != "plan" && filtered[0] != "apply") {
		return errors.New("usage: agentos config [init|plan|apply] [--config PATH] [--state PATH]")
	}
	if filtered[0] == "init" {
		return initializeConfig(c)
	}
	if filtered[0] == "plan" {
		raw, err := run(configHelper(c), "--config", c.config, "--state", c.configState, "plan")
		if err != nil {
			if _, statErr := os.Stat(c.config); errors.Is(statErr, os.ErrNotExist) {
				return fmt.Errorf("AgentOS config is missing at %s; run sudo agentos config init, then agentos config plan", c.config)
			}
			return err
		}
		fmt.Println(raw)
		return nil
	}
	return applyConfig(c)
}

type repositoryState struct {
	Schema           string `json:"schema"`
	Configured       bool   `json:"configured"`
	URL              string `json:"url"`
	Fingerprint      string `json:"fingerprint"`
	Include          string `json:"include"`
	ConfiguredAt     string `json:"configured_at,omitempty"`
	RepairedAt       string `json:"repaired_at,omitempty"`
	ChannelChangedAt string `json:"channel_changed_at,omitempty"`
}

func normalizeFingerprint(value string) string {
	return strings.ToUpper(strings.Join(strings.Fields(value), ""))
}

func repositoryNeedsRoot(c envConfig) bool {
	return os.Geteuid() == 0 || (os.Getenv("AGENTOS_REPOSITORY_TEST_MODE") == "1" && c.pacmanConf != "/etc/pacman.conf")
}

func repositoryConfigPresent(c envConfig) bool {
	include, err := os.ReadFile(c.pacmanInc)
	if err != nil {
		return false
	}
	text := string(include)
	conf, err := os.ReadFile(c.pacmanConf)
	if err != nil {
		return false
	}
	return strings.Contains(text, "[agentos]") && strings.Contains(text, "SigLevel = Required") &&
		strings.Contains(text, "Server = https://") && strings.Contains(string(conf), "Include = "+c.pacmanInc)
}

func repositoryReady(c envConfig) bool {
	state, err := readRepositoryState(c.repoState)
	return err == nil && state.Configured && repositoryConfigPresent(c) && commandOK("pacman", "-Sl", "agentos")
}

func pacmanIncludeServer(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "Server = ") {
			return strings.TrimSpace(strings.TrimPrefix(trimmed, "Server = ")), true
		}
	}
	return "", false
}

func readRepositoryState(path string) (repositoryState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return repositoryState{}, err
	}
	var state repositoryState
	if err := json.Unmarshal(data, &state); err != nil {
		return repositoryState{}, err
	}
	return state, nil
}

func repositoryStatus(c envConfig) error {
	state, err := readRepositoryState(c.repoState)
	if err != nil {
		state = repositoryState{}
	}
	trusted := false
	if state.Fingerprint != "" {
		output, keyErr := run("gpg", "--homedir", env("PACMAN_KEYRING", "/etc/pacman.d/gnupg"), "--batch", "--list-keys", "--with-colons", state.Fingerprint)
		trusted = keyErr == nil && strings.Contains(strings.ToUpper(output), state.Fingerprint)
	}
	configured := state.Configured && repositoryConfigPresent(c)
	reachable := commandOK("pacman", "-Sl", "agentos")
	result := map[string]interface{}{
		"configured": configured, "state_configured": state.Configured,
		"pacman_configured": repositoryConfigPresent(c), "trusted_key": trusted,
		"repository_reachable": reachable, "include": c.pacmanInc,
		"fingerprint": state.Fingerprint,
	}
	encoded, _ := json.Marshal(result)
	fmt.Println(string(encoded))
	return nil
}

func removeRepositoryConfig(c envConfig) error {
	data, err := os.ReadFile(c.pacmanConf)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	result := make([]string, 0, len(lines))
	inAgentOS := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "# BEGIN AGENTOS REPOSITORY" || trimmed == "[agentos]" {
			inAgentOS = true
			continue
		}
		if inAgentOS && (trimmed == "# END AGENTOS REPOSITORY" || strings.HasPrefix(trimmed, "[")) {
			inAgentOS = false
		}
		if inAgentOS || strings.TrimSpace(line) == "Include = "+c.pacmanInc {
			continue
		}
		result = append(result, line)
	}
	return writeAtomic(c.pacmanConf, []byte(strings.Join(result, "\n")), 0o644)
}

func ensureRepositoryInclude(c envConfig) error {
	data, err := os.ReadFile(c.pacmanConf)
	if err != nil {
		return fmt.Errorf("pacman configuration not found: %s", c.pacmanConf)
	}
	line := "Include = " + c.pacmanInc
	if !strings.Contains(string(data), line) {
		data = append(data, []byte("\n"+line+"\n")...)
	}
	return writeAtomic(c.pacmanConf, data, 0o644)
}

func repositoryConfigure(c envConfig, args []string) error {
	if len(args) != 3 {
		return errors.New("usage: agentos-repository configure URL PUBLIC_KEY_FILE EXPECTED_FINGERPRINT")
	}
	repositoryURL, keyPath, fingerprint := strings.TrimRight(args[0], "/"), args[1], normalizeFingerprint(args[2])
	parsed, err := url.Parse(repositoryURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || strings.ContainsAny(repositoryURL, "\r\n \t") {
		return errors.New("repository URL must use HTTPS")
	}
	if _, err := os.Stat(keyPath); err != nil {
		return fmt.Errorf("public key not found: %s", keyPath)
	}
	if len(fingerprint) != 40 {
		return errors.New("expected fingerprint must be a full 40-character fingerprint")
	}
	actual, err := run("gpg", "--show-keys", "--with-colons", keyPath)
	if err != nil {
		return fmt.Errorf("could not read signing key: %w", err)
	}
	actualFingerprint := ""
	for _, line := range strings.Split(actual, "\n") {
		fields := strings.Split(line, ":")
		if len(fields) > 9 && fields[0] == "fpr" {
			actualFingerprint = normalizeFingerprint(fields[9])
			break
		}
	}
	if actualFingerprint == "" || actualFingerprint != fingerprint {
		return fmt.Errorf("signing key fingerprint mismatch. expected=%s actual=%s", fingerprint, valueOr(actualFingerprint, "unknown"))
	}
	if err := runAndPrint("pacman-key", "--add", keyPath); err != nil {
		return err
	}
	if err := runAndPrint("pacman-key", "--lsign-key", actualFingerprint); err != nil {
		return err
	}
	if err := removeRepositoryConfig(c); err != nil {
		return err
	}
	include := fmt.Sprintf("# Managed by agentos-repository. Do not weaken signature verification.\n[agentos]\nSigLevel = Required\nServer = %s\n", repositoryURL)
	if err := writeAtomic(c.pacmanInc, []byte(include), 0o644); err != nil {
		return err
	}
	if err := ensureRepositoryInclude(c); err != nil {
		return err
	}
	state := repositoryState{Schema: "agentos.repository/v1", Configured: true, URL: repositoryURL, Fingerprint: actualFingerprint, Include: c.pacmanInc, ConfiguredAt: time.Now().UTC().Format(time.RFC3339)}
	data, _ := json.MarshalIndent(state, "", "  ")
	if err := writeAtomic(c.repoState, append(data, '\n'), 0o644); err != nil {
		return err
	}
	if err := runAndPrint("pacman", "-Sy"); err != nil {
		return err
	}
	fmt.Printf("AgentOS signed repository configured: %s\n", repositoryURL)
	return nil
}

func valueOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func repositoryBaseURL(rawURL string) (string, string, error) {
	trimmed := strings.TrimRight(rawURL, "/")
	idx := strings.LastIndex(trimmed, "/")
	if idx <= 0 {
		return "", "", fmt.Errorf("repository URL is not channel-qualified: %s", rawURL)
	}
	base, last := trimmed[:idx], trimmed[idx+1:]
	switch last {
	case "stable", "beta", "edge":
	default:
		return "", "", fmt.Errorf("repository URL is not channel-qualified: %s", rawURL)
	}
	return base, last, nil
}

// repositoryDetachChannel makes channel=none true of the machine and not just of
// the channel file. Leaving the repository in pacman.conf means pacman keeps
// pulling AgentOS packages from whichever channel was last configured, which is
// the opposite of what the setting asks for. The trusted state file is kept so
// switching back to a channel does not need the configure arguments again, and
// imported signing-key trust is retained for the same reason disable retains it.
func repositoryDetachChannel(c envConfig, state repositoryState) error {
	if err := removeRepositoryConfig(c); err != nil {
		return err
	}
	_ = os.Remove(c.pacmanInc)
	state.ChannelChangedAt = time.Now().UTC().Format(time.RFC3339)
	data, _ := json.MarshalIndent(state, "", "  ")
	if err := writeAtomic(c.repoState, append(data, '\n'), 0o644); err != nil {
		return err
	}
	if err := writePrivileged(c.channelFile, []byte("none\n"), 0o644); err != nil {
		return err
	}
	if err := runAndPrint("pacman", "-Syy"); err != nil {
		return err
	}
	fmt.Println("AgentOS repository detached from pacman; channel=none (upstream Arch only). Signing-key trust is retained intentionally.")
	return nil
}

func repositorySetChannel(c envConfig, args []string) error {
	if len(args) != 1 {
		return errors.New("usage: agentos-repository set-channel stable|beta|edge|none")
	}
	channel := args[0]
	switch channel {
	case "stable", "beta", "edge", "none":
	default:
		return errors.New("channel must be stable, beta, edge, or none")
	}
	state, err := readRepositoryState(c.repoState)
	if err != nil || !state.Configured {
		if channel == "none" {
			// Nothing is configured, so upstream Arch only is already the truth.
			// Recording it keeps the channel file and the machine in agreement.
			return writePrivileged(c.channelFile, []byte(channel+"\n"), 0o644)
		}
		return errors.New("AgentOS repository is not configured; run agentos-repository configure first")
	}
	if channel == "none" {
		return repositoryDetachChannel(c, state)
	}
	base, previous, err := repositoryBaseURL(state.URL)
	if err != nil {
		return err
	}
	newURL := base + "/" + channel
	include := fmt.Sprintf("# Managed by agentos-repository. Do not weaken signature verification.\n[agentos]\nSigLevel = Required\nServer = %s\n", newURL)
	if err := writeAtomic(c.pacmanInc, []byte(include), 0o644); err != nil {
		return err
	}
	if err := ensureRepositoryInclude(c); err != nil {
		return err
	}
	state.URL = newURL
	state.ChannelChangedAt = time.Now().UTC().Format(time.RFC3339)
	data, _ := json.MarshalIndent(state, "", "  ")
	if err := writeAtomic(c.repoState, append(data, '\n'), 0o644); err != nil {
		return err
	}
	if err := writePrivileged(c.channelFile, []byte(channel+"\n"), 0o644); err != nil {
		return err
	}
	if err := runAndPrint("pacman", "-Syy"); err != nil {
		return err
	}
	fmt.Printf("AgentOS repository channel changed: %s -> %s (%s)\n", previous, channel, newURL)
	return nil
}

func signingSubkeyExpiry(c envConfig) (int, error) {
	state, err := readRepositoryState(c.repoState)
	if err != nil || state.Fingerprint == "" {
		return 0, errors.New("no trusted AgentOS repository fingerprint on record")
	}
	output, err := run("gpg", "--homedir", env("PACMAN_KEYRING", "/etc/pacman.d/gnupg"), "--batch", "--with-colons", "--list-keys", state.Fingerprint)
	if err != nil {
		return 0, err
	}
	earliest := int64(-1)
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Split(line, ":")
		if len(fields) < 7 || fields[0] != "sub" || fields[6] == "" {
			continue
		}
		expiry, convErr := strconv.ParseInt(fields[6], 10, 64)
		if convErr != nil {
			continue
		}
		if earliest == -1 || expiry < earliest {
			earliest = expiry
		}
	}
	if earliest == -1 {
		return 0, errors.New("no expiring signing subkey found")
	}
	return int((earliest - time.Now().Unix()) / 86400), nil
}

func expiryHintApplies(output string) bool {
	return strings.Contains(strings.ToLower(output), "is expired")
}

func printExpiryHint(output string) {
	if expiryHintApplies(output) {
		fmt.Fprintln(os.Stderr, "HINT: a repository signature looks expired. Run: sudo agentos-repository refresh-keys")
	}
}

func runAndPrintWithExpiryHint(name string, args ...string) error {
	output, err := run(name, args...)
	if output != "" {
		fmt.Println(output)
	}
	if err != nil {
		printExpiryHint(output)
	}
	return err
}

func repositoryRefreshKeys(c envConfig, args []string) error {
	if len(args) != 0 {
		return errors.New("usage: agentos-repository refresh-keys")
	}
	state, err := readRepositoryState(c.repoState)
	if err != nil || !state.Configured {
		return errors.New("AgentOS repository is not configured; run agentos-repository configure first")
	}
	base, _, err := repositoryBaseURL(state.URL)
	if err != nil {
		return err
	}
	keyURL := base + "/agentos-signing.asc"
	tmp, err := os.CreateTemp("", "agentos-signing-*.asc")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	tmp.Close()
	defer os.Remove(tmpPath)
	if err := runAndPrint("curl", "--fail", "--silent", "--show-error", "--output", tmpPath, keyURL); err != nil {
		return fmt.Errorf("could not fetch refreshed signing key: %w", err)
	}
	actual, err := run("gpg", "--show-keys", "--with-colons", tmpPath)
	if err != nil {
		return fmt.Errorf("could not read fetched signing key: %w", err)
	}
	fingerprint := ""
	for _, line := range strings.Split(actual, "\n") {
		fields := strings.Split(line, ":")
		if len(fields) > 9 && fields[0] == "fpr" {
			fingerprint = normalizeFingerprint(fields[9])
			break
		}
	}
	if fingerprint == "" || fingerprint != normalizeFingerprint(state.Fingerprint) {
		return fmt.Errorf("fetched signing key fingerprint mismatch. expected=%s actual=%s", state.Fingerprint, valueOr(fingerprint, "unknown"))
	}
	if err := runAndPrint("pacman-key", "--add", tmpPath); err != nil {
		return err
	}
	fmt.Println("AgentOS signing key refreshed and re-added to the pacman keyring.")
	return nil
}

func repositoryVerify(c envConfig, args []string) error {
	if len(args) != 0 {
		return errors.New("usage: agentos-repository verify")
	}
	healthy := true
	state, err := readRepositoryState(c.repoState)
	if err != nil || !state.Configured {
		fmt.Println("[FAIL] repository state: not configured")
		healthy = false
	} else {
		fmt.Printf("[OK]   repository state: configured url=%s fingerprint=%s\n", state.URL, state.Fingerprint)
	}
	if !repositoryConfigPresent(c) {
		fmt.Println("[FAIL] pacman configuration: AgentOS repository include is missing or malformed")
		healthy = false
	} else {
		fmt.Println("[OK]   pacman configuration: SigLevel=Required, Server configured")
	}
	days, expiryErr := signingSubkeyExpiry(c)
	switch {
	case expiryErr != nil:
		fmt.Printf("[WARN] signing subkey expiry: %s\n", expiryErr)
	case days < 0:
		fmt.Printf("[FAIL] signing subkey expiry: expired %d day(s) ago\n", -days)
		healthy = false
	case days < 30:
		fmt.Printf("[FAIL] signing subkey expiry: %d day(s) remaining\n", days)
		healthy = false
	default:
		fmt.Printf("[OK]   signing subkey expiry: %d day(s) remaining\n", days)
	}
	if sigErr := repositoryVerifyLocalSignatures(c); sigErr != nil {
		fmt.Printf("[FAIL] signature verification: %s\n", sigErr)
		healthy = false
	} else {
		fmt.Println("[OK]   signature verification: locally synced repository matches its signatures")
	}
	if !healthy {
		return errors.New("AgentOS repository verification failed")
	}
	return nil
}

func repositoryVerifyLocalSignatures(c envConfig) error {
	keyFile := env("AGENTOS_SIGNING_KEY_FILE", "/usr/share/agentos/agentos-signing.asc")
	if _, err := os.Stat(keyFile); err != nil {
		return fmt.Errorf("signing public key not found at %s (is agentos-keyring installed?)", keyFile)
	}
	state, err := readRepositoryState(c.repoState)
	if err != nil || !state.Configured {
		return errors.New("AgentOS repository is not configured")
	}
	script := env("AGENTOS_VERIFY_REPO_SCRIPT", "/usr/lib/agentos/verify-repo.sh")
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("verify-repo.sh not found at %s", script)
	}
	tmpDir, err := os.MkdirTemp("", "agentos-verify-repo-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)
	for _, name := range []string{"agentos.db.tar.gz", "agentos.db.tar.gz.sig", "release-manifest.json", "release-manifest.json.asc"} {
		if err := runAndPrint("curl", "--fail", "--silent", "--show-error", "--output", filepath.Join(tmpDir, name), state.URL+"/"+name); err != nil {
			return fmt.Errorf("could not fetch %s for local verification: %w", name, err)
		}
	}
	return runAndPrint(script, tmpDir, keyFile)
}

func repositoryCommand(c envConfig, args []string) error {
	if !repositoryNeedsRoot(c) {
		return errors.New("run agentos-repository with sudo")
	}
	if len(args) == 0 || args[0] == "status" {
		return repositoryStatus(c)
	}
	switch args[0] {
	case "configure":
		return repositoryConfigure(c, args[1:])
	case "repair":
		state, err := readRepositoryState(c.repoState)
		if err != nil {
			return errors.New("AgentOS repository state is missing; run configure with the public key")
		}
		if !strings.HasPrefix(state.URL, "https://") || len(normalizeFingerprint(state.Fingerprint)) != 40 {
			return errors.New("stored AgentOS repository state is invalid")
		}
		if !repositoryConfigPresent(c) {
			include := fmt.Sprintf("# Managed by agentos-repository. Do not weaken signature verification.\n[agentos]\nSigLevel = Required\nServer = %s\n", state.URL)
			if err := writeAtomic(c.pacmanInc, []byte(include), 0o644); err != nil {
				return err
			}
			if err := ensureRepositoryInclude(c); err != nil {
				return err
			}
		}
		state.Include = c.pacmanInc
		state.RepairedAt = time.Now().UTC().Format(time.RFC3339)
		data, _ := json.MarshalIndent(state, "", "  ")
		return writeAtomic(c.repoState, append(data, '\n'), 0o644)
	case "migrate":
		if _, err := os.Stat(c.repoState); err == nil {
			return repositoryCommand(c, []string{"repair"})
		}
		if data, err := os.ReadFile(c.pacmanConf); err == nil && strings.Contains(string(data), "[agentos]") {
			return errors.New("AgentOS repository is configured inline but has no trusted state; run configure")
		}
		fmt.Println("No legacy AgentOS repository configuration found; nothing to migrate.")
		return nil
	case "disable":
		if err := removeRepositoryConfig(c); err != nil {
			return err
		}
		_ = os.Remove(c.pacmanInc)
		_ = os.Remove(c.repoState)
		fmt.Println("AgentOS repository disabled. Imported signing-key trust is retained intentionally.")
		return nil
	case "set-channel":
		return repositorySetChannel(c, args[1:])
	case "verify":
		return repositoryVerify(c, args[1:])
	case "refresh-keys":
		return repositoryRefreshKeys(c, args[1:])
	default:
		return errors.New("usage: agentos-repository status|configure|repair|migrate|disable|set-channel|verify|refresh-keys")
	}
}

func transactionCommand(c envConfig, args []string) error {
	mode := "status"
	if len(args) > 0 {
		mode = args[0]
	}
	if err := os.MkdirAll(c.stateRoot, 0o755); err != nil {
		return err
	}
	generation := ""
	if len(args) > 1 {
		generation = args[1]
	}
	if generation == "" {
		data, _ := os.ReadFile(filepath.Join(c.stateRoot, "current"))
		generation = strings.TrimSpace(string(data))
	}
	if mode == "preflight" {
		generation = time.Now().UTC().Format("20060102-150405") + "-unknown"
		dir := filepath.Join(c.stateRoot, generation)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		if !commandOK("systemctl", "is-active", "sshd.service") || !portListening(22) || strings.TrimSpace(firstLine(runOutput("tailscale", "ip", "-4"))) == "" {
			return errors.New("remote-access preflight failed")
		}
		if snapshotOutput, snapshotErr := run("sudo", "btrfs-pre-pacman-snapshot"); snapshotErr == nil {
			snapshot := snapshotFromOutput(snapshotOutput)
			if snapshot != "" {
				_ = writeAtomic(filepath.Join(dir, "snapshot.name"), []byte(snapshot+"\n"), 0o644)
			}
		}
		metadata := map[string]interface{}{"generation": generation, "status": "PREPARED", "phase": "before", "message": "preflight passed", "time": time.Now().Format(time.RFC3339), "host": hostname(), "snapshot": readFirstLine(filepath.Join(dir, "snapshot.name"))}
		data, _ := json.MarshalIndent(metadata, "", "  ")
		if err := writeAtomic(filepath.Join(dir, "before.json"), append(data, '\n'), 0o644); err != nil {
			return err
		}
		if err := writeAtomic(filepath.Join(c.stateRoot, "current"), []byte(generation+"\n"), 0o644); err != nil {
			return err
		}
		fmt.Println("Prepared AgentOS generation " + generation)
		fmt.Println(generation)
		return nil
	}
	if generation == "" || !directoryExists(filepath.Join(c.stateRoot, generation)) {
		if mode == "status" {
			fmt.Println("No AgentOS convergence generation recorded yet.")
			return nil
		}
		return errors.New("unknown AgentOS generation")
	}
	dir := filepath.Join(c.stateRoot, generation)
	snapshot := readFirstLine(filepath.Join(dir, "snapshot.name"))
	metadata := map[string]interface{}{
		"generation": generation, "status": "FAILED", "phase": "failure",
		"message": "convergence command failed before validation", "time": time.Now().Format(time.RFC3339),
		"host": hostname(), "snapshot": snapshot,
		"remote": map[string]interface{}{"ssh_active": commandOK("systemctl", "is-active", "sshd.service")},
	}
	if mode == "fail" {
		data, _ := json.MarshalIndent(metadata, "", "  ")
		if err := writeAtomic(filepath.Join(dir, "failure.json"), append(data, '\n'), 0o644); err != nil {
			return err
		}
		if snapshot != "" {
			if status, _ := run("sudo", "rollback-workstation", "status"); !strings.Contains(status, "Staged rollback state:") {
				if _, err := run("sudo", "rollback-workstation", "stage", snapshot); err == nil {
					_ = writeAtomic(filepath.Join(dir, "rollback-staged"), []byte(snapshot+"\n"), 0o644)
				}
			}
		}
		fmt.Printf("AgentOS generation %s marked FAILED.\n", generation)
		return nil
	}
	if mode == "rollback" {
		if snapshot == "" {
			return errors.New("no recoverable snapshot recorded for generation")
		}
		if status, _ := run("sudo", "rollback-workstation", "status"); strings.Contains(status, "Staged rollback state:") {
			return nil
		}
		if _, err := run("sudo", "rollback-workstation", "stage", snapshot); err != nil {
			return err
		}
		return writeAtomic(filepath.Join(dir, "rollback-staged"), []byte(snapshot+"\n"), 0o644)
	}
	if mode == "validate" {
		failures := []string{}
		if !commandOK("systemctl", "is-active", "sshd.service") || !portListening(22) {
			failures = append(failures, "SSH invariant failed")
		}
		if strings.TrimSpace(firstLine(runOutput("tailscale", "ip", "-4"))) == "" {
			failures = append(failures, "Tailscale invariant failed")
		}
		if !userSystemctlOK("is-active", "agentosd.service") {
			failures = append(failures, "agentosd inactive")
		}
		if !commandOK("curl", "--fail", "--silent", "--max-time", "3", "http://127.0.0.1:4787/v1/healthz") {
			failures = append(failures, "agentosd health endpoint failed")
		}
		if len(failures) > 0 {
			metadata["message"] = strings.Join(failures, "; ")
			data, _ := json.MarshalIndent(metadata, "", "  ")
			if err := writeAtomic(filepath.Join(dir, "after.json"), append(data, '\n'), 0o644); err != nil {
				return err
			}
			if snapshot != "" {
				_ = transactionCommand(c, []string{"rollback", generation})
			}
			return fmt.Errorf("AgentOS generation %s FAILED validation: %s", generation, strings.Join(failures, "; "))
		}
		metadata["status"], metadata["phase"], metadata["message"] = "GOOD", "after", "all protected invariants passed"
		data, _ := json.MarshalIndent(metadata, "", "  ")
		return writeAtomic(filepath.Join(dir, "after.json"), append(data, '\n'), 0o644)
	}
	if mode == "status" {
		fmt.Printf("Generation: %s\n", generation)
		for _, name := range []string{"before", "after", "failure"} {
			if data, err := os.ReadFile(filepath.Join(dir, name+".json")); err == nil {
				fmt.Println(string(data))
			}
		}
		return nil
	}
	return fmt.Errorf("unsupported transaction mode: %s", mode)
}

func runOutput(name string, args ...string) string {
	output, _ := run(name, args...)
	return output
}

func firstLine(value string) string {
	return strings.Split(strings.TrimSpace(value), "\n")[0]
}

func snapshotFromOutput(output string) string {
	for _, line := range strings.Split(output, "\n") {
		if marker := "Created pre-pacman snapshot: "; strings.Contains(line, marker) {
			return filepath.Base(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), marker)))
		}
	}
	return ""
}

func portListening(port int) bool {
	output, err := run("ss", "-ltnH")
	if err != nil {
		return false
	}
	needle := ":" + strconv.Itoa(port)
	for _, line := range strings.Split(output, "\n") {
		if strings.Contains(line, needle+" ") || strings.HasSuffix(strings.TrimSpace(line), needle) {
			return true
		}
	}
	return false
}

func directoryExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func readFirstLine(path string) string {
	data, _ := os.ReadFile(path)
	return strings.TrimSpace(string(data))
}

func onboardingCommand(args []string) error {
	local := false
	wantTailscale, wantKRDP := false, false
	target := ""
	for _, arg := range args {
		switch arg {
		case "--local", "--remote-session":
			local = true
		case "--tailscale":
			wantTailscale = true
		case "--krdp":
			wantKRDP = true
		case "--help", "-h", "help":
			fmt.Println("Usage: agentos-onboarding [--tailscale] [--krdp] USER@HOST | --local")
			return nil
		default:
			if strings.HasPrefix(arg, "--") || target != "" {
				return errors.New("invalid onboarding arguments")
			}
			target = arg
		}
	}
	if !local {
		if target == "" {
			return errors.New("an SSH target is required unless --local is used")
		}
		remoteArgs := []string{"--local", "--remote-session"}
		if wantTailscale {
			remoteArgs = append(remoteArgs, "--tailscale")
		}
		if wantKRDP {
			remoteArgs = append(remoteArgs, "--krdp")
		}
		sshArgs := []string{"-tt", "-o", "BatchMode=no", "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1", target, "sudo -v && agentos-onboarding " + strings.Join(remoteArgs, " ")}
		return runAndPrint("ssh", sshArgs...)
	}
	failures := 0
	ok := func(name, detail string) { fmt.Printf("[OK]   %-22s %s\n", name, detail) }
	fail := func(name, detail string) { fmt.Printf("[FAIL]  %-21s %s\n", name, detail); failures++ }
	skip := func(name, detail string) { fmt.Printf("[SKIP] %-22s %s\n", name, detail) }
	if os.Geteuid() == 0 || commandOK("sudo", "-n", "true") {
		ok("Sudo read access", "non-interactive administrative checks available")
	} else {
		fail("Sudo read access", "run sudo -v, then rerun; no privileged changes were attempted")
	}
	if commandOK("systemctl", "is-active", "--quiet", "sshd") {
		ok("SSH service", "sshd is active")
	} else {
		fail("SSH service", "sshd is not active")
	}
	c := configFromEnv()
	c.config = env("AGENTOS_ONBOARDING_CONFIG", c.config)
	status, statusErr := captureRepositoryStatus(c)
	if statusErr == nil && status.Configured && status.StateConfigured && status.PacmanConfigured && status.Trusted && status.Reachable {
		ok("Signed repository", "configured, trusted, and reachable")
	} else {
		fail("Signed repository", "not fully configured, trusted, or reachable")
	}
	if commandOK("pacman", "-Q", "agentos-runtime") && commandOK("pacman", "-Q", "agentos-shell") {
		ok("AgentOS packages", "runtime and shell installed")
	} else {
		fail("AgentOS packages", "agentos-runtime and agentos-shell are not both installed")
	}
	if _, err := os.Stat(env("AGENTOS_ONBOARDING_CONFIG", c.config)); err == nil {
		if _, err := readConfigPlan(c); err == nil {
			ok("First-run config", "valid desired state")
		} else {
			fail("First-run config", "invalid or unreadable desired state")
		}
	} else {
		skip("First-run config", "not configured; run the guided VPS installer first")
	}
	if output, err := run("curl", "--fail", "--silent", "--show-error", "--max-time", "5", "http://127.0.0.1:4787/v1/healthz"); err == nil && strings.TrimSpace(output) == "ok" {
		ok("AgentOS local API", "health endpoint is healthy")
	} else {
		fail("AgentOS local API", "agentosd health endpoint is unavailable")
	}
	if userSystemctlOK("is-active", "--quiet", "agentos-home.service") {
		ok("AgentOS Home", "agentos-home.service is active")
	} else if os.Getenv("WAYLAND_DISPLAY") == "" {
		skip("AgentOS Home", "no Wayland session; graphical Home is optional on a headless VPS")
	} else {
		fail("AgentOS Home", "agentos-home.service is not active")
	}
	if wantTailscale {
		if commandOK("systemctl", "is-active", "--quiet", "tailscaled") && commandOK("tailscale", "ip", "-4") {
			ok("Tailscale", "active with IPv4 address")
		} else {
			fail("Tailscale", "requested but tailscaled or IPv4 is unavailable")
		}
	} else {
		skip("Tailscale", "not requested; no Tailscale state was changed")
	}
	if wantKRDP {
		if userSystemctlOK("is-active", "--quiet", "app-org.kde.krdpserver.service") {
			ok("KRDP", "service is active")
		} else {
			fail("KRDP", "requested but the user KRDP service is not active")
		}
	} else {
		skip("KRDP", "not requested; no graphical-access state was changed")
	}
	if failures > 0 {
		return fmt.Errorf("onboarding validation failed: %d required check(s) need attention", failures)
	}
	fmt.Println("\nOnboarding validation passed.")
	return nil
}

type repositoryStatusResult struct {
	Configured, StateConfigured, PacmanConfigured, Trusted, Reachable bool
}

func captureRepositoryStatus(c envConfig) (repositoryStatusResult, error) {
	output, err := run("agentos-repository", "status")
	if err != nil && os.Geteuid() != 0 {
		output, err = run("sudo", "agentos-repository", "status")
	}
	if err == nil {
		var value struct {
			Configured bool `json:"configured"`
			State      bool `json:"state_configured"`
			Pacman     bool `json:"pacman_configured"`
			Trusted    bool `json:"trusted_key"`
			Reachable  bool `json:"repository_reachable"`
		}
		if json.Unmarshal([]byte(output), &value) == nil {
			return repositoryStatusResult{value.Configured, value.State, value.Pacman, value.Trusted, value.Reachable}, nil
		}
	}
	state, err := readRepositoryState(c.repoState)
	if err != nil {
		return repositoryStatusResult{}, err
	}
	return repositoryStatusResult{state.Configured, state.Configured && repositoryConfigPresent(c), repositoryConfigPresent(c), true, commandOK("pacman", "-Sl", "agentos")}, nil
}

func updateCommand(c envConfig, args []string) (resultErr error) {
	mode := "--scheduled"
	if len(args) > 0 {
		mode = args[0]
	}
	channel := readFirstLine(c.channelFile)
	if channel == "" {
		channel = "stable"
	}
	switch channel {
	case "stable", "beta", "edge", "none":
	default:
		return fmt.Errorf("invalid AgentOS channel: %s", channel)
	}
	if mode == "--scheduled" && channel != "stable" {
		fmt.Printf("Automatic weekly updates only apply on stable channel (current: %s).\n", channel)
		return nil
	}
	if os.Geteuid() != 0 {
		return errors.New("agentos-weekly-update must run as root")
	}
	resultPath:=systemUpdateStatePath()
	previous,_:=loadUpdateRecord(resultPath)
	record:=updatestate.Record{Schema:updatestate.Schema,Channel:channel,CurrentVersion:valueOr(readFirstLine(c.versionFile),"dev"),CheckedAt:time.Now().UTC().Format(time.RFC3339),MigrationStatus:"not-run"}
	snapshot:=""
	defer func(){if resultErr==nil{return};record.Status=updatestate.StatusApplyFailed;record.LastFailure=boundedUpdateFailure(resultErr.Error());record.SnapshotID=snapshot;if record.LastSuccessAt==""{record.LastSuccessAt=previous.LastSuccessAt};if saveErr:=saveUpdateRecord(resultPath,record,0o644);saveErr!=nil{fmt.Fprintf(os.Stderr,"Could not persist update failure: %v\n",saveErr)}}()
	fmt.Printf("AgentOS update starting: %s channel=%s\n", time.Now().Format(time.RFC3339), channel)
	if channel != "none" && !repositoryReady(c) {
		return fmt.Errorf("channel=%s requires a configured AgentOS repository; run: sudo agentos-repository configure <url> <keyfile> <fingerprint>", channel)
	}
	inspected,pendingPackages,err:=inspectUpdate(c)
	if err!=nil{return err}
	record=inspected
	record.LastSuccessAt=previous.LastSuccessAt
	record.MigrationStatus="not-run"
	if channel != "none" {
		if err := runAndPrintWithExpiryHint("pacman", "-Sy", "--noconfirm"); err != nil {
			return err
		}
		if err := runAndPrintWithExpiryHint("pacman", "-S", "--needed", "--noconfirm", "agentos-keyring"); err != nil {
			return err
		}
		if days, expiryErr := signingSubkeyExpiry(c); expiryErr == nil && days < 30 {
			fmt.Fprintf(os.Stderr, "WARNING: AgentOS signing subkey expires in %d day(s); run: sudo agentos-repository refresh-keys\n", days)
		}
	}
	if output, snapshotErr := run("btrfs-pre-pacman-snapshot"); snapshotErr == nil {
		fmt.Println(output)
		snapshot = snapshotFromOutput(output)
	}
	if err := runAndPrintWithExpiryHint("pacman", "-Syu", "--noconfirm"); err != nil {
		return err
	}
	if _, err := migrationConfigFromEnv().apply(migrationScopeSystem); err != nil {
		record.MigrationStatus="failed"
		fmt.Fprintln(os.Stderr, "System migration failed. Snapshot is available for rollback.")
		if snapshot != "" {
			_ = runAndPrint("rollback-workstation", "stage", snapshot)
		}
		return fmt.Errorf("system migration failed: %w", err)
	}
	record.MigrationStatus="succeeded"
	_ = runAndPrint("systemctl", "daemon-reload")
	_ = runUserSystemctlAndPrint("daemon-reload")
	_ = runUserSystemctlAndPrint("restart", "agentosd.service")
	_ = runUserSystemctlAndPrint("restart", "agentos-herdr-bridge.service")
	doctorOutput, doctorErr := run("workstation-doctor", "--check")
	_ = writeAtomic("/var/log/agentos-post-update-doctor.log", []byte(doctorOutput+"\n"), 0o644)
	if doctorErr != nil {
		fmt.Fprintln(os.Stderr, "Post-update doctor reported problems. Snapshot is available for rollback.")
		if snapshot != "" {
			_ = runAndPrint("rollback-workstation", "stage", snapshot)
		}
		return errors.New("post-update doctor reported problems")
	}
	if snapshot != "" {
		generation := "update-" + time.Now().UTC().Format("20060102-150405")
		_ = runAndPrint("agentos-boot-health", "arm", generation, snapshot)
	}
	stamp := time.Now().Format(time.RFC3339)
	if channel!="none"&&record.TargetVersion!=""{if err:=writeAtomic(c.versionFile,[]byte(record.TargetVersion+"\n"),0o644);err!=nil{return err};record.CurrentVersion=record.TargetVersion}
	if err := writeAtomic(filepath.Join(env("AGENTOS_STATE_DIR","/var/lib/agentos"),"last-update"), []byte(stamp+"\n"), 0o644); err != nil {
		return err
	}
	record.LastSuccessAt=stamp;record.LastFailure="";record.SnapshotID=snapshot;record.RebootRequired=updateRequiresReboot(pendingPackages);record.Status=updatestate.StatusSucceeded;if record.RebootRequired{record.Status=updatestate.StatusRebootRequired;record.BootID=currentBootID()}
	if err:=saveUpdateRecord(resultPath,record,0o644);err!=nil{return err}
	fmt.Printf("AgentOS weekly update completed: %s\n", stamp)
	return nil
}

func doctorCommand(c envConfig, args []string) error {
	mode := "--check"
	if len(args) > 0 {
		mode = args[0]
	}
	if mode != "--check" && mode != "--notify" {
		return errors.New("usage: workstation-doctor [--check|--notify]")
	}
	if mode == "--notify" {
		output, err := run(os.Args[0], "--entrypoint", "doctor", "--check")
		fmt.Println(output)
		if err != nil {
			path := filepath.Join(os.TempDir(), "agentos-doctor-report.txt")
			if writeErr := writeAtomic(path, []byte(output+"\n"), 0o600); writeErr == nil {
				_ = runAndPrint("workstation-alert", "--subject", "AgentOS health alert", "--file", path)
				_ = os.Remove(path)
			}
		}
		return err
	}
	failures, warnings := 0, 0
	ok := func(name, detail string) { fmt.Printf("[OK]   %-24s %s\n", name, detail) }
	warn := func(name, detail string) { fmt.Printf("[WARN] %-24s %s\n", name, detail); warnings++ }
	fail := func(name, detail string) { fmt.Printf("[FAIL] %-24s %s\n", name, detail); failures++ }
	fmt.Println("AgentOS workstation doctor")
	fmt.Printf("Generated: %s\nHost: %s\nKernel: %s\n\n", time.Now().UTC().Format(time.RFC3339), hostname(), kernelRelease())
	rootFS, _ := run("findmnt", "-no", "FSTYPE", "/")
	if rootFS == "btrfs" {
		ok("Root filesystem", "Btrfs")
	} else {
		fail("Root filesystem", "expected Btrfs, found "+valueOr(rootFS, "unknown"))
	}
	if output, err := run("df", "-P", "/"); err == nil {
		fields := strings.Fields(output)
		if len(fields) >= 5 {
			usage := strings.TrimSuffix(fields[len(fields)-2], "%")
			if value, parseErr := strconv.Atoi(usage); parseErr == nil {
				switch {
				case value >= 90:
					fail("Root disk usage", usage+"% used")
				case value >= 80:
					warn("Root disk usage", usage+"% used")
				default:
					ok("Root disk usage", usage+"% used")
				}
			}
		}
	}
	if failedUnits, err := run("systemctl", "--failed", "--no-legend", "--plain"); err == nil && failedUnits != "" {
		fail("Systemd units", "failed units detected")
	} else {
		ok("Systemd units", "no failed system units")
	}
	for _, service := range []string{"sshd", "tailscaled", "ollama"} {
		if commandOK("systemctl", "is-active", "--quiet", service) {
			ok(service, "active")
		} else {
			fail(service, "inactive")
		}
	}
	if rootFS == "btrfs" {
		if os.Geteuid() != 0 && !commandOK("sudo", "-n", "true") {
			warn("Btrfs device stats", "needs root; run sudo workstation-doctor for full check")
		} else if output, err := run("btrfs", "device", "stats", "/"); err != nil {
			fail("Btrfs device stats", "check failed: "+valueOr(output, "unknown error"))
		} else if btrfsErrorCounters(output) {
			fail("Btrfs device stats", "non-zero device error counters")
		} else {
			ok("Btrfs device stats", "all counters zero")
		}
		snapshots, _ := filepath.Glob("/.snapshots/pre-pacman-*")
		if len(snapshots) == 0 {
			warn("Pacman snapshots", "none yet")
		} else {
			sort.Strings(snapshots)
			ok("Pacman snapshots", fmt.Sprintf("%d retained; newest %s", len(snapshots), filepath.Base(snapshots[len(snapshots)-1])))
		}
	}
	if devices, _ := filepath.Glob("/dev/nvme*n*"); len(devices) > 0 {
		found := false
		for _, device := range devices {
			info, statErr := os.Stat(device)
			if statErr != nil || info.Mode()&os.ModeDevice == 0 || strings.Contains(filepath.Base(device), "p") {
				continue
			}
			found = true
			if os.Geteuid() != 0 && !commandOK("sudo", "-n", "true") {
				warn("SMART "+filepath.Base(device), "needs root for health check")
				continue
			}
			output, err := run("smartctl", "-H", device)
			if err == nil && (strings.Contains(strings.ToUpper(output), "PASSED") || strings.Contains(strings.ToUpper(output), "OK")) {
				ok("SMART "+filepath.Base(device), "healthy")
			} else {
				fail("SMART "+filepath.Base(device), "health check did not report PASSED/OK")
			}
		}
		if !found {
			warn("NVMe SMART", "no NVMe namespace block device found")
		}
	} else {
		warn("NVMe SMART", "no NVMe namespace block device found")
	}
	if commandOK("systemctl", "is-active", "--quiet", "tailscaled") {
		if commandOK("tailscale", "status", "--json") {
			ok("Tailscale control", "reachable")
		} else {
			warn("Tailscale control", "daemon is active but status query failed")
		}
	}
	workstationUser := workstationUser()
	workstationHome := homeDirFor(workstationUser)
	herdr := filepath.Join(workstationHome, ".local", "bin", "herdr")
	if info, err := os.Stat(herdr); err == nil && info.Mode().Perm()&0o111 != 0 {
		if version, versionErr := run(herdr, "--version"); versionErr == nil {
			ok("Herdr", firstLine(version))
		} else {
			ok("Herdr", "installed")
		}
		if userSystemctlOK("is-active", "--quiet", "herdr.service") {
			ok("Herdr integrations", "status readable")
		} else {
			warn("Herdr integrations", "could not read integration status")
		}
	} else {
		fail("Herdr", "not installed; run sync-workstation")
	}
	if _, err := os.Stat(filepath.Join(workstationHome, ".hermes")); err == nil {
		gateway := filepath.Join(workstationHome, ".config/systemd/user/hermes-gateway.service")
		if _, err := os.Stat(gateway); err == nil {
			if userSystemctlOK("is-active", "--quiet", "hermes-gateway.service") {
				ok("Hermes gateway", "active")
			} else {
				fail("Hermes gateway", "configured service is not active")
			}
		} else {
			warn("Hermes gateway", "Hermes configured but managed gateway not installed")
		}
		checkBackupAge(workstationHome, "quick", 48*time.Hour, ok, warn, fail)
		checkBackupAge(workstationHome, "full", 9*24*time.Hour, ok, warn, fail)
	}
	if _, err := os.Stat("/etc/restic-backup.env"); err == nil {
		if commandOK("systemctl", "is-failed", "--quiet", "restic-backup.service") {
			fail("Restic backup", "last service run failed")
		} else {
			ok("Restic backup", "service is not failed")
		}
		if commandOK("systemctl", "is-failed", "--quiet", "restic-verify.service") {
			fail("Restic verify", "last integrity/restore check failed")
		} else {
			ok("Restic verify", "service is not failed")
		}
	} else {
		warn("Restic", "not configured yet")
	}
	channel := valueOr(readFirstLine(c.channelFile), "stable")
	switch channel {
	case "stable", "beta", "edge", "none":
		if channel == "none" {
			// An unconditional OK here would report a healthy machine while pacman
			// still pulls AgentOS packages, which is exactly the state the setting
			// is meant to prevent.
			if repositoryConfigPresent(c) {
				fail("Repository channel", "channel=none but the AgentOS repository is still configured in pacman; run: sudo agentos-repository set-channel none")
			} else {
				ok("Repository channel", "channel=none (upstream Arch only)")
			}
		} else {
			state, stateErr := readRepositoryState(c.repoState)
			pacmanServer, pacmanServerFound := pacmanIncludeServer(c.pacmanInc)
			switch {
			case stateErr != nil || !state.Configured:
				fail("Repository channel", fmt.Sprintf("channel=%s but AgentOS repository is not configured", channel))
			case !strings.HasSuffix(strings.TrimRight(state.URL, "/"), "/"+channel):
				fail("Repository channel", fmt.Sprintf("channel=%s but repository URL is %s", channel, state.URL))
			case pacmanServerFound && pacmanServer != state.URL:
				fail("Repository channel", fmt.Sprintf("channel=%s but pacman is configured for %s while recorded state says %s", channel, pacmanServer, state.URL))
			case !repositoryConfigPresent(c):
				fail("Repository channel", "repository state is trusted but pacman is not configured")
			default:
				ok("Repository channel", fmt.Sprintf("channel=%s matches the configured repository", channel))
			}
		}
	default:
		fail("Repository channel", "invalid channel value: "+channel)
	}
	if failures > 0 {
		fmt.Printf("\nSummary: %d failure(s), %d warning(s).\n", failures, warnings)
		return errors.New("workstation health has actionable failures")
	}
	fmt.Printf("\nSummary: %d failure(s), %d warning(s).\n", failures, warnings)
	return nil
}

func btrfsErrorCounters(output string) bool {
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 {
			value, err := strconv.Atoi(fields[len(fields)-1])
			if err == nil && value != 0 {
				return true
			}
		}
	}
	return false
}

func homeDirFor(username string) string {
	if username == "" {
		return homeDir()
	}
	if current, err := user.Lookup(username); err == nil && current.HomeDir != "" {
		return current.HomeDir
	}
	return homeDir()
}

func checkBackupAge(home, kind string, maxAge time.Duration, ok, warn, fail func(string, string)) {
	files, _ := filepath.Glob(filepath.Join(home, ".local/share/hermes-backups", "hermes-"+kind+"-*.zip.age"))
	if len(files) == 0 {
		warn("Hermes "+kind+" backup", "no encrypted "+kind+" backup yet")
		return
	}
	sort.Slice(files, func(i, j int) bool {
		left, _ := os.Stat(files[i])
		right, _ := os.Stat(files[j])
		return left.ModTime().After(right.ModTime())
	})
	info, err := os.Stat(files[0])
	if err != nil {
		warn("Hermes "+kind+" backup", "could not inspect latest backup")
		return
	}
	if time.Since(info.ModTime()) > maxAge {
		fail("Hermes "+kind+" backup", "older than "+maxAge.String()+": "+filepath.Base(files[0]))
	} else {
		ok("Hermes "+kind+" backup", filepath.Base(files[0]))
	}
}

func hostname() string {
	if output, err := run("hostname"); err == nil && output != "" {
		return output
	}
	if output, err := run("uname", "-n"); err == nil && output != "" {
		return output
	}
	return "unknown"
}

func kernelRelease() string {
	if output, err := run("uname", "-r"); err == nil && output != "" {
		return output
	}
	return "unknown"
}

func maintenanceState() maintenance.State {
	hardwareState := collectHardwareState()
	firmwareEnable := hardwareState.Role == "physical" && !hardwareState.Firmware.Installed
	firmware := hardwareState.Role == "physical" && hardwareState.Firmware.Installed
	recoveryState := collectRecoveryState()
	recoveryAvailable := hardwareState.Role == "physical" && recoveryState.Status == recovery.StatusReady
	recoveryStage := false
	if recoveryAvailable && recoveryState.Staged == nil {
		for _, point := range recoveryState.Points {
			if point.BootSafe {
				recoveryStage = true
				break
			}
		}
	}
	return maintenance.NewState(maintenance.Availability{
		Update:         true,
		Hardware:       true,
		FirmwareEnable: firmwareEnable,
		Firmware:       firmware,
		Recovery:       recoveryAvailable,
		RecoveryStage:  recoveryStage,
		RecoveryCancel: recoveryAvailable && recoveryState.Staged != nil,
	})
}

func agentosCommand(c envConfig, args []string) error {
	if len(args) == 0 || args[0] == "help" {
		fmt.Println("Usage: agentos [welcome|version|channel|update|maintenance|hardware|migrate|recovery|rollback|state|sessions|health|boot-status|repository|store|plan|apply|config|project|agent|remote|support|telemetry]")
		fmt.Println("  agentos plan [capability...]")
		fmt.Println("  agentos apply [capability...]")
		fmt.Println("  agentos config init|plan|apply")
		return nil
	}
	switch args[0] {
	case "welcome":
		if len(args) != 1 {
			return errors.New("usage: agentos welcome")
		}
		fmt.Println("Welcome to AgentOS")
		fmt.Println("  Inspect: agentos health | agentos state | agentos store list")
		fmt.Println("  Work:    agentos project open NAME | agentos agent start codex")
		fmt.Println("  Setup:   sudo agentos config init | agentos config plan")
		fmt.Println("  Help:    /usr/share/agentos/AGENTS.md | agentos support")
		fmt.Println("  Safety:  updates, sudo, rollback, reboot, and telemetry require explicit action")
		return nil
	case "version":
		fmt.Printf("AgentOS %s (%s)\n", valueOr(readFirstLine(c.versionFile), "dev"), valueOr(readFirstLine(c.channelFile), "stable"))
		return nil
	case "channel":
		if len(args) == 1 {
			fmt.Println(valueOr(readFirstLine(c.channelFile), "stable"))
			return nil
		}
		switch args[1] {
		case "stable", "beta", "edge", "none":
		default:
			return errors.New("channel must be stable, beta, edge, or none")
		}
		return writePrivileged(c.channelFile, []byte(args[1]+"\n"), 0o644)
	case "update":
		mode := []string{"--check"}
		if len(args) > 1 {
			mode = args[1:]
		}
		if mode[0] == "--apply" {
			updater := "agentos-weekly-update"
			if _, err := os.Stat("/usr/lib/agentos/agentos-weekly-update"); err == nil {
				updater = "/usr/lib/agentos/agentos-weekly-update"
			}
			return runAndPrint("sudo", updater, "--manual")
		}
		if mode[0] != "--check" {
			return errors.New("usage: agentos update [--check|--apply]")
		}
		return checkUpdateCommand(c)
	case "maintenance":
		if len(args) != 1 {
			return errors.New("usage: agentos maintenance")
		}
		encoded, err := json.MarshalIndent(maintenanceState(), "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(encoded))
		return nil
	case "hardware":
		return hardwareCommand(args[1:])
	case "migrate":
		return migrationCommand(args[1:])
	case "repository":
		if os.Geteuid() != 0 {
			repositoryArgs := append([]string{"agentos-repository"}, args[1:]...)
			return runAndPrint("sudo", repositoryArgs...)
		}
		return repositoryCommand(c, args[1:])
	case "store":
		if len(args) == 1 || args[1] == "list" {
			return listCapabilities(c)
		}
		if len(args) < 3 || args[1] != "install" {
			return errors.New("usage: agentos store [list|install <capability>]")
		}
		registry, err := readRegistry(c.registry)
		if err != nil {
			return err
		}
		item, ok := registry[args[2]]
		if !ok {
			return fmt.Errorf("Unknown capability: %s", args[2])
		}
		return installCapability(item)
	case "plan":
		return planCapabilities(c, args[1:])
	case "apply":
		return applyCapabilities(c, args[1:])
	case "config":
		return configCommand(c, args[1:])
	case "boot-status":
		return runAndPrint("sudo", "agentos-boot-health", "status")
	case "recovery", "rollback":
		return recoveryCommand(args[1:])
	case "state", "sessions", "health":
		endpoint := "/v1/" + args[0]
		if args[0] == "state" || args[0] == "health" {
			endpoint = "/v1/state"
		}
		output, err := run("curl", "--fail", "--silent", "--max-time", "3", env("AGENTOSD_URL", "http://127.0.0.1:4787")+endpoint)
		if err != nil {
			return runAndPrint("workstation-doctor", "--check")
		}
		var value interface{}
		if json.Unmarshal([]byte(output), &value) == nil {
			encoded, _ := json.MarshalIndent(value, "", "  ")
			fmt.Println(string(encoded))
		} else {
			fmt.Println(output)
		}
		return nil
	case "remote":
		return runAndPrint("agentos-remote-desktop", "--status")
	case "support":
		return runAgentOSHelper("agentos-support", args[1:]...)
	case "telemetry":
		return runAgentOSHelper("agentos-telemetry", args[1:]...)
	case "project":
		if len(args) != 3 || args[1] != "open" || args[2] == "" {
			return errors.New("usage: agentos project open <name>")
		}
		return daemonAction(map[string]string{"name": "project-open", "project": args[2]})
	case "agent":
		if len(args) < 3 || len(args) > 4 || args[1] != "start" || args[2] == "" {
			return errors.New("usage: agentos agent start <agent> [project]")
		}
		if args[2] != "claude" && args[2] != "codex" && args[2] != "hermes" && args[2] != "herdr" {
			return errors.New("unknown agent")
		}
		project := ""
		if len(args) == 4 {
			project = args[3]
		}
		return daemonAction(map[string]string{"name": "agent-start", "agent": args[2], "project": project})
	default:
		return errors.New("unknown AgentOS command")
	}
}

func daemonAction(action map[string]string) error {
	payload, err := json.Marshal(action)
	if err != nil {
		return err
	}
	return runAndPrint("curl", "--fail", "--silent", "--max-time", "5", "-X", "POST", "-H", "Content-Type: application/json", "--data", string(payload), env("AGENTOSD_URL", "http://127.0.0.1:4787")+"/v1/action")
}

func main() {
	entrypoint := "agentos"
	args := os.Args[1:]
	if len(args) >= 2 && args[0] == "--entrypoint" {
		entrypoint, args = args[1], args[2:]
	}
	c := configFromEnv()
	var err error
	switch entrypoint {
	case "agentos":
		err = agentosCommand(c, args)
	case "repository":
		err = repositoryCommand(c, args)
	case "transaction":
		err = transactionCommand(c, args)
	case "onboarding":
		err = onboardingCommand(args)
	case "update":
		err = updateCommand(c, args)
	case "doctor":
		err = doctorCommand(c, args)
	default:
		err = fmt.Errorf("unknown operations entrypoint: %s", entrypoint)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "agentos:", err)
		os.Exit(1)
	}
}
