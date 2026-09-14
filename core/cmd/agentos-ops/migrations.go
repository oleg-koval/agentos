package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

const migrationSchema = "agentos.migrations/v1"

type migrationScope string

const (
	migrationScopeSystem migrationScope = "system"
	migrationScopeUser   migrationScope = "user"
)

type migrationStatus string

const (
	migrationPending migrationStatus = "pending"
	migrationApplied migrationStatus = "applied"
	migrationFailed  migrationStatus = "failed"
)

type migrationResult struct {
	ID        string          `json:"id"`
	Status    migrationStatus `json:"status"`
	AppliedAt string          `json:"applied_at,omitempty"`
	FailedAt  string          `json:"failed_at,omitempty"`
	Error     string          `json:"error,omitempty"`
}

type migrationScopeStatus struct {
	Scope      migrationScope    `json:"scope"`
	Migrations []migrationResult `json:"migrations"`
}

type migrationReport struct {
	Schema string                 `json:"schema"`
	Scopes []migrationScopeStatus `json:"scopes"`
}

type migrationFailure struct {
	At    string `json:"at"`
	Error string `json:"error"`
}

type migrationStore struct {
	Schema  int                         `json:"schema"`
	Applied map[string]string           `json:"applied"`
	Failed  map[string]migrationFailure `json:"failed"`
}

type migrationDefinition struct {
	ID   string
	Path string
}

type migrationConfig struct {
	definitionsRoot string
	systemStateRoot string
	userStateRoot   string
	trustedOwner    int
}

func migrationConfigFromEnv() migrationConfig {
	userState := os.Getenv("XDG_STATE_HOME")
	if userState == "" {
		userState = filepath.Join(homeDir(), ".local", "state")
	}
	trustedOwner := 0
	if os.Getenv("AGENTOS_MIGRATION_TEST_MODE") == "1" {
		trustedOwner = os.Geteuid()
	}
	return migrationConfig{
		definitionsRoot: env("AGENTOS_MIGRATIONS_DIR", "/usr/share/agentos/migrations"),
		systemStateRoot: env("AGENTOS_SYSTEM_MIGRATION_STATE", "/var/lib/agentos/migrations"),
		userStateRoot:   env("AGENTOS_USER_MIGRATION_STATE", filepath.Join(userState, "agentos", "migrations")),
		trustedOwner:    trustedOwner,
	}
}

func parseMigrationScope(value string) (migrationScope, error) {
	switch migrationScope(value) {
	case migrationScopeSystem:
		return migrationScopeSystem, nil
	case migrationScopeUser:
		return migrationScopeUser, nil
	default:
		return "", errors.New("migration scope must be system or user")
	}
}

func (c migrationConfig) stateRoot(scope migrationScope) string {
	if scope == migrationScopeSystem {
		return c.systemStateRoot
	}
	return c.userStateRoot
}

var migrationIDPattern = regexp.MustCompile(`^[0-9]{8}-[0-9]{3}-[a-z0-9][a-z0-9-]*$`)

func trustedMigrationPath(info os.FileInfo, owner int) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == owner && info.Mode().Perm()&0o022 == 0
}

func (c migrationConfig) definitions(scope migrationScope) ([]migrationDefinition, error) {
	dir := filepath.Join(c.definitionsRoot, string(scope))
	dirInfo, err := os.Lstat(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return []migrationDefinition{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect %s migrations: %w", scope, err)
	}
	if !dirInfo.IsDir() || !trustedMigrationPath(dirInfo, c.trustedOwner) {
		return nil, fmt.Errorf("%s migration directory must be package-owned and not group/world writable", scope)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read %s migrations: %w", scope, err)
	}
	definitions := make([]migrationDefinition, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if filepath.Ext(name) != ".sh" {
			return nil, fmt.Errorf("invalid migration definition %q", name)
		}
		id := strings.TrimSuffix(name, ".sh")
		if !migrationIDPattern.MatchString(id) {
			return nil, fmt.Errorf("invalid migration ID %q", id)
		}
		info, err := os.Lstat(filepath.Join(dir, name))
		if err != nil {
			return nil, fmt.Errorf("inspect migration %q: %w", id, err)
		}
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("migration %q must be a regular package-owned file", id)
		}
		if !trustedMigrationPath(info, c.trustedOwner) {
			return nil, fmt.Errorf("migration %q must be package-owned and not group/world writable", id)
		}
		definitions = append(definitions, migrationDefinition{ID: id, Path: filepath.Join(dir, name)})
	}
	sort.Slice(definitions, func(i, j int) bool { return definitions[i].ID < definitions[j].ID })
	return definitions, nil
}

func emptyMigrationStore() migrationStore {
	return migrationStore{Schema: 1, Applied: map[string]string{}, Failed: map[string]migrationFailure{}}
}

func loadMigrationStore(root string) (migrationStore, error) {
	path := filepath.Join(root, "state.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return emptyMigrationStore(), nil
	}
	if err != nil {
		return migrationStore{}, err
	}
	store := emptyMigrationStore()
	if err := json.Unmarshal(data, &store); err != nil {
		return migrationStore{}, fmt.Errorf("invalid migration state: %w", err)
	}
	if store.Schema != 1 {
		return migrationStore{}, fmt.Errorf("unsupported migration state schema %d", store.Schema)
	}
	if store.Applied == nil {
		store.Applied = map[string]string{}
	}
	if store.Failed == nil {
		store.Failed = map[string]migrationFailure{}
	}
	return store, nil
}

func migrationStateModes(scope migrationScope) (os.FileMode, os.FileMode) {
	if scope == migrationScopeSystem {
		return 0o755, 0o644
	}
	return 0o700, 0o600
}

func saveMigrationStore(root string, scope migrationScope, store migrationStore) error {
	dirMode, fileMode := migrationStateModes(scope)
	if err := os.MkdirAll(root, dirMode); err != nil {
		return err
	}
	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(root, "state.json"), append(data, '\n'), fileMode)
}

func migrationStatusFor(scope migrationScope, definitions []migrationDefinition, store migrationStore) migrationScopeStatus {
	status := migrationScopeStatus{Scope: scope, Migrations: make([]migrationResult, 0, len(definitions))}
	for _, definition := range definitions {
		result := migrationResult{ID: definition.ID, Status: migrationPending}
		if appliedAt, ok := store.Applied[definition.ID]; ok {
			result.Status = migrationApplied
			result.AppliedAt = appliedAt
		} else if failure, ok := store.Failed[definition.ID]; ok {
			result.Status = migrationFailed
			result.FailedAt = failure.At
			result.Error = failure.Error
		}
		status.Migrations = append(status.Migrations, result)
	}
	return status
}

func (c migrationConfig) status(scope migrationScope) (migrationScopeStatus, error) {
	definitions, err := c.definitions(scope)
	if err != nil {
		return migrationScopeStatus{}, err
	}
	store, err := loadMigrationStore(c.stateRoot(scope))
	if err != nil {
		return migrationScopeStatus{}, err
	}
	return migrationStatusFor(scope, definitions, store), nil
}

type migrationLock struct{ file *os.File }

func acquireMigrationLock(root string, scope migrationScope) (*migrationLock, error) {
	dirMode, _ := migrationStateModes(scope)
	if err := os.MkdirAll(root, dirMode); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(root, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, errors.New("migration runner already active for this scope")
		}
		return nil, err
	}
	return &migrationLock{file: file}, nil
}

func (lock *migrationLock) Close() error {
	unlockErr := syscall.Flock(int(lock.file.Fd()), syscall.LOCK_UN)
	closeErr := lock.file.Close()
	if unlockErr != nil {
		return unlockErr
	}
	return closeErr
}

func executeMigration(definition migrationDefinition) error {
	command := exec.Command("bash", definition.Path)
	command.Stdin = nil
	command.Stdout = nil
	command.Stderr = nil
	if err := command.Run(); err != nil {
		return fmt.Errorf("migration %s failed: %w", definition.ID, err)
	}
	return nil
}

func boundedMigrationError(err error) string {
	message := err.Error()
	if len(message) > 512 {
		return message[:512]
	}
	return message
}

func (c migrationConfig) apply(scope migrationScope) (migrationScopeStatus, error) {
	definitions, err := c.definitions(scope)
	if err != nil {
		return migrationScopeStatus{}, err
	}
	root := c.stateRoot(scope)
	lock, err := acquireMigrationLock(root, scope)
	if err != nil {
		return migrationScopeStatus{}, err
	}
	defer lock.Close()
	store, err := loadMigrationStore(root)
	if err != nil {
		return migrationScopeStatus{}, err
	}
	for _, definition := range definitions {
		if _, applied := store.Applied[definition.ID]; applied {
			continue
		}
		if err := executeMigration(definition); err != nil {
			failure := boundedMigrationError(err)
			store.Failed = map[string]migrationFailure{definition.ID: {At: time.Now().UTC().Format(time.RFC3339), Error: failure}}
			if saveErr := saveMigrationStore(root, scope, store); saveErr != nil {
				return migrationStatusFor(scope, definitions, store), saveErr
			}
			return migrationStatusFor(scope, definitions, store), errors.New(failure)
		}
		store.Applied[definition.ID] = time.Now().UTC().Format(time.RFC3339)
		delete(store.Failed, definition.ID)
		if err := saveMigrationStore(root, scope, store); err != nil {
			return migrationStatusFor(scope, definitions, store), err
		}
	}
	return migrationStatusFor(scope, definitions, store), nil
}

func printMigrationReport(report migrationReport) error {
	encoded, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(encoded))
	return nil
}

func migrationScopeFlag(args []string) (migrationScope, bool, error) {
	var scope migrationScope
	set := false
	for index := 0; index < len(args); index++ {
		if args[index] == "--json" {
			continue
		}
		if args[index] != "--scope" || index+1 >= len(args) {
			return "", false, errors.New("usage: agentos migrate status [--scope system|user] [--json]")
		}
		if set {
			return "", false, errors.New("migration scope may be specified only once")
		}
		parsed, err := parseMigrationScope(args[index+1])
		if err != nil {
			return "", false, err
		}
		scope, set = parsed, true
		index++
	}
	return scope, set, nil
}

func migrationCommand(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: agentos migrate status [--scope system|user] [--json] | agentos migrate apply --scope system|user [--json]")
	}
	c := migrationConfigFromEnv()
	scope, scoped, err := migrationScopeFlag(args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "status":
		scopes := []migrationScope{migrationScopeSystem, migrationScopeUser}
		if scoped {
			scopes = []migrationScope{scope}
		}
		report := migrationReport{Schema: migrationSchema, Scopes: make([]migrationScopeStatus, 0, len(scopes))}
		for _, current := range scopes {
			status, err := c.status(current)
			if err != nil {
				return err
			}
			report.Scopes = append(report.Scopes, status)
		}
		return printMigrationReport(report)
	case "apply":
		if !scoped {
			return errors.New("agentos migrate apply requires --scope system or --scope user")
		}
		status, applyErr := c.apply(scope)
		if applyErr != nil && status.Scope == "" {
			return applyErr
		}
		if err := printMigrationReport(migrationReport{Schema: migrationSchema, Scopes: []migrationScopeStatus{status}}); err != nil {
			return err
		}
		return applyErr
	default:
		return errors.New("usage: agentos migrate status [--scope system|user] [--json] | agentos migrate apply --scope system|user [--json]")
	}
}
