package recovery

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const Schema = "agentos.recovery/v1"

type Status string

const (
	StatusReady       Status = "ready"
	StatusUnavailable Status = "unavailable"
)

type NextBoot string

const (
	NextBootNormal       NextBoot = "normal"
	NextBootRollbackOnce NextBoot = "rollback-once"
	NextBootUnknown      NextBoot = "unknown"
)

type RecoveryPoint struct {
	ID       string `json:"id"`
	BootSafe bool   `json:"boot_safe"`
	Created  string `json:"created,omitempty"`
}

type Staged struct {
	SourceID        string `json:"source_id"`
	TargetSubvolume string `json:"target_subvolume"`
	StagedAt        string `json:"staged_at,omitempty"`
}

type State struct {
	Schema          string          `json:"schema"`
	Status          Status          `json:"status"`
	CurrentRoot     string          `json:"current_root,omitempty"`
	CurrentRollback bool            `json:"current_rollback"`
	NextBoot        NextBoot        `json:"next_boot"`
	Points          []RecoveryPoint `json:"points"`
	Staged          *Staged         `json:"staged,omitempty"`
}

type Paths struct {
	SnapshotDir     string
	BootSnapshotDir string
	StateFile       string
}

var pointIDPattern = regexp.MustCompile(`^pre-pacman-[0-9]{8}-[0-9]{6}(?:-[0-9]+-[0-9]+)?$`)
var rollbackSubvolumePattern = regexp.MustCompile(`^@rollback-[0-9]{8}-[0-9]{6}$`)

func ValidPointID(id string) bool { return pointIDPattern.MatchString(id) }

func PathsFromEnvironment() Paths {
	snapshots := environment("BTRFS_SNAPSHOT_DIR", "/.snapshots")
	stateRoot := environment("AGENTOS_STATE_DIR", environment("WORKSTATION_STATE_DIR", "/var/lib/agentos"))
	if os.Getenv("AGENTOS_STATE_DIR") == "" && os.Getenv("WORKSTATION_STATE_DIR") == "" {
		stateFile := filepath.Join(stateRoot, "rollback.env")
		legacyStateFile := "/var/lib/legacy-workstation/rollback.env"
		if _, err := os.Stat(stateFile); errors.Is(err, os.ErrNotExist) {
			if _, legacyErr := os.Stat(legacyStateFile); legacyErr == nil {
				stateRoot = filepath.Dir(legacyStateFile)
			}
		}
	}
	return Paths{
		SnapshotDir:     snapshots,
		BootSnapshotDir: environment("BTRFS_BOOT_SNAPSHOT_DIR", filepath.Join(snapshots, "boot")),
		StateFile:       filepath.Join(stateRoot, "rollback.env"),
	}
}

func CollectSystem() State {
	output, err := exec.Command("findmnt", "-no", "OPTIONS", "/").Output()
	if err != nil {
		return unavailableState()
	}
	root, ok := rootSubvolume(string(output))
	if !ok {
		return unavailableState()
	}
	return Collect(PathsFromEnvironment(), root)
}

func Collect(paths Paths, currentRoot string) State {
	state := State{Schema: Schema, Status: StatusReady, CurrentRoot: currentRoot, NextBoot: NextBootNormal, Points: []RecoveryPoint{}}
	entries, err := os.ReadDir(paths.SnapshotDir)
	if err != nil {
		return unavailableState()
	}
	for _, entry := range entries {
		if !entry.IsDir() || !ValidPointID(entry.Name()) {
			continue
		}
		state.Points = append(state.Points, RecoveryPoint{
			ID:       entry.Name(),
			BootSafe: validBootBundle(filepath.Join(paths.BootSnapshotDir, entry.Name())),
			Created:  createdAt(entry.Name()),
		})
	}
	sort.Slice(state.Points, func(i, j int) bool { return state.Points[i].ID > state.Points[j].ID })

	content, err := os.ReadFile(paths.StateFile)
	if errors.Is(err, os.ErrNotExist) {
		state.CurrentRollback = strings.HasPrefix(currentRoot, "@rollback-")
		if state.CurrentRollback {
			state.NextBoot = NextBootUnknown
		}
		return state
	}
	if err != nil {
		return unavailableState()
	}
	staged, err := parseStaged(content)
	if err != nil || !state.pointIsBootSafe(staged.SourceID) {
		return unavailableState()
	}
	state.Staged = staged
	state.CurrentRollback = currentRoot == staged.TargetSubvolume
	if !state.CurrentRollback {
		state.NextBoot = NextBootRollbackOnce
	}
	return state
}

func (state State) CanStage(id string) bool {
	return state.Status == StatusReady && state.Staged == nil && state.pointIsBootSafe(id)
}

func (state State) pointIsBootSafe(id string) bool {
	if !ValidPointID(id) {
		return false
	}
	for _, point := range state.Points {
		if point.ID == id {
			return point.BootSafe
		}
	}
	return false
}

func unavailableState() State {
	return State{Schema: Schema, Status: StatusUnavailable, NextBoot: NextBootUnknown, Points: []RecoveryPoint{}}
}

func rootSubvolume(options string) (string, bool) {
	for _, option := range strings.Split(strings.TrimSpace(options), ",") {
		if strings.HasPrefix(option, "subvol=") {
			root := strings.TrimPrefix(option, "subvol=")
			root = strings.TrimPrefix(root, "/")
			return root, root != ""
		}
	}
	return "@", strings.TrimSpace(options) != ""
}

func createdAt(id string) string {
	const prefix = "pre-pacman-"
	stamp := strings.TrimPrefix(id, prefix)
	if len(stamp) < len("20060102-150405") {
		return ""
	}
	parsed, err := time.Parse("20060102-150405", stamp[:len("20060102-150405")])
	if err != nil {
		return ""
	}
	return parsed.UTC().Format(time.RFC3339)
}

func parseStaged(content []byte) (*Staged, error) {
	values := map[string]string{}
	seen := map[string]bool{}
	scanner := bufio.NewScanner(strings.NewReader(string(content)))
	allowed := map[string]bool{"ROLLBACK_SUBVOL": true, "SOURCE_SNAPSHOT": true, "RECOVERY_DIR": true, "RECOVERY_ENTRY": true, "STAGED_AT": true}
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || !allowed[key] || seen[key] || strings.TrimSpace(value) != value || strings.ContainsAny(value, "'\"`$\\") {
			return nil, errors.New("invalid rollback state")
		}
		seen[key] = true
		values[key] = value
	}
	if scanner.Err() != nil || !ValidPointID(values["SOURCE_SNAPSHOT"]) || !rollbackSubvolumePattern.MatchString(values["ROLLBACK_SUBVOL"]) || values["RECOVERY_ENTRY"] != "agentos-rollback.conf" {
		return nil, errors.New("invalid rollback state")
	}
	if stagedAt := values["STAGED_AT"]; stagedAt != "" {
		if _, err := time.Parse(time.RFC3339, stagedAt); err != nil {
			return nil, errors.New("invalid rollback state")
		}
	}
	return &Staged{SourceID: values["SOURCE_SNAPSHOT"], TargetSubvolume: values["ROLLBACK_SUBVOL"], StagedAt: values["STAGED_AT"]}, nil
}

func validBootBundle(bundle string) bool {
	resolvedBundle, err := filepath.EvalSymlinks(bundle)
	if err != nil {
		return false
	}
	entry := filepath.Join(bundle, "loader", "entries", "arch.conf")
	if info, err := os.Lstat(entry); err != nil || !info.Mode().IsRegular() {
		return false
	}
	manifest := filepath.Join(bundle, "MANIFEST.sha256")
	manifestInfo, err := os.Lstat(manifest)
	if errors.Is(err, os.ErrNotExist) {
		return true
	}
	if err != nil || !manifestInfo.Mode().IsRegular() {
		return false
	}
	file, err := os.Open(manifest)
	if err != nil {
		return false
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	verified := 0
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 2 || len(fields[0]) != sha256.Size*2 {
			return false
		}
		relative := strings.TrimPrefix(fields[1], "*")
		relative = strings.TrimPrefix(relative, "./")
		if relative == "" || filepath.IsAbs(relative) || strings.HasPrefix(filepath.Clean(relative), "..") {
			return false
		}
		path := filepath.Join(bundle, relative)
		resolved, err := filepath.EvalSymlinks(path)
		if err != nil {
			return false
		}
		within, err := filepath.Rel(resolvedBundle, resolved)
		if err != nil || within == ".." || strings.HasPrefix(within, ".."+string(os.PathSeparator)) {
			return false
		}
		if info, err := os.Lstat(resolved); err != nil || !info.Mode().IsRegular() {
			return false
		}
		actual, err := fileSHA256(resolved)
		if err != nil || !strings.EqualFold(actual, fields[0]) {
			return false
		}
		verified++
	}
	return scanner.Err() == nil && verified > 0
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func environment(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
