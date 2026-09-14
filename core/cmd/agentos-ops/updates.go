package main

import (
	"agentos/core/internal/updatestate"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

var agentOSPackageNames = []string{"agentos-base", "agentos-keyring", "agentos-runtime", "agentos-shell"}

type updateManifest struct {
	Schema        string            `json:"schema"`
	Channel       string            `json:"channel"`
	Version       string            `json:"version"`
	RepositoryURL string            `json:"repository_url"`
	Packages      map[string]string `json:"-"`
	RawPackages   []struct {
		Name string `json:"name"`
	} `json:"packages"`
}

func packageVersionFromArchive(archive, packageName string) (string, bool) {
	if strings.Contains(archive, "-debug-") || !strings.HasPrefix(archive, packageName+"-") {
		return "", false
	}
	value := strings.TrimPrefix(archive, packageName+"-")
	for _, suffix := range []string{"-x86_64.pkg.tar.zst", "-any.pkg.tar.zst"} {
		if strings.HasSuffix(value, suffix) {
			version := strings.TrimSuffix(value, suffix)
			return version, version != ""
		}
	}
	return "", false
}

func parseUpdateManifest(data []byte, channel string) (updateManifest, error) {
	var manifest updateManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return updateManifest{}, fmt.Errorf("invalid release manifest: %w", err)
	}
	if manifest.Schema != "agentos.release/v2" || manifest.Channel != channel || strings.TrimSpace(manifest.Version) == "" {
		return updateManifest{}, errors.New("release manifest does not match the active channel")
	}
	manifest.Packages = map[string]string{}
	for _, item := range manifest.RawPackages {
		for _, packageName := range agentOSPackageNames {
			if version, ok := packageVersionFromArchive(item.Name, packageName); ok {
				manifest.Packages[packageName] = version
			}
		}
	}
	for _, packageName := range agentOSPackageNames {
		if manifest.Packages[packageName] == "" {
			return updateManifest{}, fmt.Errorf("release manifest is missing %s", packageName)
		}
	}
	return manifest, nil
}

func agentOSPackagesNeedUpdate(desired, installed map[string]string) bool {
	for _, packageName := range agentOSPackageNames {
		if desired[packageName] == "" || installed[packageName] != desired[packageName] {
			return true
		}
	}
	return false
}

func installedAgentOSPackages() map[string]string {
	output, _ := run("pacman", append([]string{"-Q"}, agentOSPackageNames...)...)
	installed := map[string]string{}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 {
			installed[fields[0]] = fields[1]
		}
	}
	return installed
}

func packageUpdates() ([]string, error) {
	output, err := run("checkupdates")
	if err != nil {
		var exitError *exec.ExitError
		if !errors.As(err, &exitError) || exitError.ExitCode() != 2 {
			return nil, errors.New("could not check Arch package updates")
		}
	}
	if strings.TrimSpace(output) == "" {
		return []string{}, nil
	}
	return strings.Split(output, "\n"), nil
}

func updateRequiresReboot(lines []string) bool {
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "linux", "linux-lts", "linux-zen", "linux-hardened":
			return true
		}
	}
	return false
}

func currentBootID() string {
	return readFirstLine(env("AGENTOS_BOOT_ID_FILE", "/proc/sys/kernel/random/boot_id"))
}

func fetchSignedUpdateManifest(c envConfig, channel string) (updateManifest, error) {
	if !repositoryReady(c) {
		return updateManifest{}, errors.New("signed AgentOS repository is not ready")
	}
	state, err := readRepositoryState(c.repoState)
	if err != nil || !state.Configured {
		return updateManifest{}, errors.New("signed AgentOS repository state is unavailable")
	}
	_, configuredChannel, err := repositoryBaseURL(state.URL)
	if err != nil || configuredChannel != channel {
		return updateManifest{}, errors.New("signed AgentOS repository does not match the active channel")
	}
	pacmanServer, found := pacmanIncludeServer(c.pacmanInc)
	if !found || strings.TrimRight(pacmanServer, "/") != strings.TrimRight(state.URL, "/") {
		return updateManifest{}, errors.New("pacman repository does not match configured trust state")
	}
	dir := os.Getenv("AGENTOS_UPDATE_MANIFEST_DIR")
	remove := func() {}
	if dir == "" {
		dir, err = os.MkdirTemp("", "agentos-update-*")
		if err != nil {
			return updateManifest{}, err
		}
		remove = func() { _ = os.RemoveAll(dir) }
		for _, name := range []string{"release-manifest.json", "release-manifest.json.asc"} {
			if _, err := run("curl", "--fail", "--silent", "--show-error", "--output", filepath.Join(dir, name), state.URL+"/"+name); err != nil {
				remove()
				return updateManifest{}, fmt.Errorf("could not fetch signed release metadata: %w", err)
			}
		}
	}
	defer remove()
	keyFile := env("AGENTOS_SIGNING_KEY_FILE", "/usr/share/agentos/agentos-signing.asc")
	verifier := env("AGENTOS_VERIFY_REPO_SCRIPT", "/usr/lib/agentos/verify-repo.sh")
	if _, err := run(verifier, dir, keyFile); err != nil {
		return updateManifest{}, errors.New("release metadata signature verification failed")
	}
	data, err := os.ReadFile(filepath.Join(dir, "release-manifest.json"))
	if err != nil {
		return updateManifest{}, err
	}
	manifest, err := parseUpdateManifest(data, channel)
	if err != nil {
		return updateManifest{}, err
	}
	base, _, baseErr := repositoryBaseURL(state.URL)
	if baseErr != nil || manifest.RepositoryURL == "" || strings.TrimSuffix(manifest.RepositoryURL, "/") != strings.TrimSuffix(base, "/") {
		return updateManifest{}, errors.New("release manifest repository URL does not match configured trust state")
	}
	return manifest, nil
}

func inspectUpdate(c envConfig) (updatestate.Record, []string, error) {
	channel := valueOr(readFirstLine(c.channelFile), "stable")
	current := valueOr(readFirstLine(c.versionFile), "dev")
	record := updatestate.Record{Schema: updatestate.Schema, Channel: channel, CurrentVersion: current, TargetVersion: current, CheckedAt: time.Now().UTC().Format(time.RFC3339)}
	lines, err := packageUpdates()
	if err != nil {
		return record, nil, err
	}
	record.ArchPending = len(lines)
	agentPending := false
	if channel != "none" {
		manifest, err := fetchSignedUpdateManifest(c, channel)
		if err != nil {
			return record, lines, err
		}
		record.TargetVersion = manifest.Version
		agentPending = agentOSPackagesNeedUpdate(manifest.Packages, installedAgentOSPackages())
	}
	if agentPending || len(lines) > 0 {
		record.Status = updatestate.StatusAvailable
	} else {
		record.Status = updatestate.StatusUpToDate
	}
	return record, lines, nil
}

func userUpdateStatePath() string {
	stateHome := os.Getenv("XDG_STATE_HOME")
	if stateHome == "" {
		stateHome = filepath.Join(homeDir(), ".local", "state")
	}
	return env("AGENTOS_UPDATE_CHECK_STATE", filepath.Join(stateHome, "agentos", "update-check.json"))
}

func systemUpdateStatePath() string {
	return env("AGENTOS_UPDATE_RESULT_STATE", "/var/lib/agentos/update-result.json")
}

func loadUpdateRecord(path string) (updatestate.Record, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return updatestate.Record{}, err
	}
	var record updatestate.Record
	if err := json.Unmarshal(data, &record); err != nil {
		return updatestate.Record{}, err
	}
	if record.Schema != updatestate.Schema || !updatestate.ValidStatus(record.Status) {
		return updatestate.Record{}, errors.New("invalid update state")
	}
	return record, nil
}

func saveUpdateRecord(path string, record updatestate.Record, mode fs.FileMode) error {
	record.Schema = updatestate.Schema
	data, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(path, append(data, '\n'), mode)
}

func boundedUpdateFailure(message string) string {
	message = strings.TrimSpace(message)
	if len(message) > 512 {
		return message[:512]
	}
	return message
}

func checkUpdateCommand(c envConfig) error {
	started := updatestate.Record{
		Schema:         updatestate.Schema,
		Status:         updatestate.StatusChecking,
		Channel:        valueOr(readFirstLine(c.channelFile), "stable"),
		CurrentVersion: valueOr(readFirstLine(c.versionFile), "dev"),
		CheckedAt:      time.Now().UTC().Format(time.RFC3339),
	}
	if err := saveUpdateRecord(userUpdateStatePath(), started, 0o600); err != nil {
		return err
	}
	record, _, err := inspectUpdate(c)
	if err != nil {
		record.Status = updatestate.StatusCheckFailed
		record.LastFailure = boundedUpdateFailure(err.Error())
	}
	if saveErr := saveUpdateRecord(userUpdateStatePath(), record, 0o600); saveErr != nil {
		return saveErr
	}
	fmt.Printf("AgentOS channel: %s\nAgentOS version: %s\n", record.Channel, record.CurrentVersion)
	if record.TargetVersion != "" {
		fmt.Printf("Available version: %s\n", record.TargetVersion)
	}
	fmt.Printf("Update status: %s\nArch/package updates: %d\n", record.Status, record.ArchPending)
	return err
}
