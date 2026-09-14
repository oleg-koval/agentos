package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeMigration(t *testing.T, root string, scope migrationScope, id, body string) {
	t.Helper()
	dir := filepath.Join(root, string(scope))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, id+".sh"), []byte("#!/usr/bin/env bash\nset -euo pipefail\n"+body+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func testMigrationConfig(t *testing.T) migrationConfig {
	t.Helper()
	root := t.TempDir()
	return migrationConfig{
		definitionsRoot: filepath.Join(root, "definitions"),
		systemStateRoot: filepath.Join(root, "system-state"),
		userStateRoot:   filepath.Join(root, "user-state"),
		trustedOwner:    os.Geteuid(),
	}
}

func migrationStatuses(status migrationScopeStatus) map[string]migrationStatus {
	result := map[string]migrationStatus{}
	for _, migration := range status.Migrations {
		result[migration.ID] = migration.Status
	}
	return result
}

func TestMigrationApplyRunsInOrderAndRerunIsNoop(t *testing.T) {
	c := testMigrationConfig(t)
	logPath := filepath.Join(t.TempDir(), "migration.log")
	t.Setenv("MIGRATION_TEST_LOG", logPath)
	writeMigration(t, c.definitionsRoot, migrationScopeUser, "20260906-002-second", `printf 'second\n' >> "$MIGRATION_TEST_LOG"`)
	writeMigration(t, c.definitionsRoot, migrationScopeUser, "20260906-001-first", `printf 'first\n' >> "$MIGRATION_TEST_LOG"`)

	status, err := c.apply(migrationScopeUser)
	if err != nil {
		t.Fatal(err)
	}
	if got := migrationStatuses(status); !reflect.DeepEqual(got, map[string]migrationStatus{"20260906-001-first": migrationApplied, "20260906-002-second": migrationApplied}) {
		t.Fatalf("statuses=%#v", got)
	}
	if _, err := c.apply(migrationScopeUser); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(data); got != "first\nsecond\n" {
		t.Fatalf("execution order=%q", got)
	}
}

func TestMigrationFailureStopsQueueAndResumeRetriesPending(t *testing.T) {
	c := testMigrationConfig(t)
	work := t.TempDir()
	logPath := filepath.Join(work, "migration.log")
	failPath := filepath.Join(work, "fail")
	t.Setenv("MIGRATION_TEST_LOG", logPath)
	t.Setenv("MIGRATION_TEST_FAIL", failPath)
	if err := os.WriteFile(failPath, []byte("fail"), 0o600); err != nil {
		t.Fatal(err)
	}
	writeMigration(t, c.definitionsRoot, migrationScopeSystem, "20260906-001-first", `printf 'first\n' >> "$MIGRATION_TEST_LOG"`)
	writeMigration(t, c.definitionsRoot, migrationScopeSystem, "20260906-002-maybe-fail", `[[ ! -e "$MIGRATION_TEST_FAIL" ]] || { printf 'private detail' >&2; exit 42; }; printf 'second\n' >> "$MIGRATION_TEST_LOG"`)
	writeMigration(t, c.definitionsRoot, migrationScopeSystem, "20260906-003-third", `printf 'third\n' >> "$MIGRATION_TEST_LOG"`)

	status, err := c.apply(migrationScopeSystem)
	if err == nil || strings.Contains(err.Error(), "private detail") {
		t.Fatalf("error=%v want bounded redacted failure", err)
	}
	want := map[string]migrationStatus{"20260906-001-first": migrationApplied, "20260906-002-maybe-fail": migrationFailed, "20260906-003-third": migrationPending}
	if got := migrationStatuses(status); !reflect.DeepEqual(got, want) {
		t.Fatalf("statuses=%#v want %#v", got, want)
	}
	if err := os.Remove(failPath); err != nil {
		t.Fatal(err)
	}
	status, err = c.apply(migrationScopeSystem)
	if err != nil {
		t.Fatal(err)
	}
	for id, got := range migrationStatuses(status) {
		if got != migrationApplied {
			t.Fatalf("%s=%s want applied", id, got)
		}
	}
	data, _ := os.ReadFile(logPath)
	if got := string(data); got != "first\nsecond\nthird\n" {
		t.Fatalf("resume execution=%q", got)
	}
}

func TestMigrationDiscoveryRejectsInvalidAndUntrustedDefinitions(t *testing.T) {
	t.Run("invalid ID", func(t *testing.T) {
		c := testMigrationConfig(t)
		writeMigration(t, c.definitionsRoot, migrationScopeUser, "not-ordered", "true")
		if _, err := c.status(migrationScopeUser); err == nil || !strings.Contains(err.Error(), "invalid migration ID") {
			t.Fatalf("error=%v", err)
		}
	})
	t.Run("symlink", func(t *testing.T) {
		c := testMigrationConfig(t)
		dir := filepath.Join(c.definitionsRoot, string(migrationScopeUser))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(t.TempDir(), "target.sh")
		if err := os.WriteFile(target, []byte("true\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, filepath.Join(dir, "20260906-001-linked.sh")); err != nil {
			t.Fatal(err)
		}
		if _, err := c.status(migrationScopeUser); err == nil || !strings.Contains(err.Error(), "regular package-owned file") {
			t.Fatalf("error=%v", err)
		}
	})
	t.Run("writable by group", func(t *testing.T) {
		c := testMigrationConfig(t)
		writeMigration(t, c.definitionsRoot, migrationScopeUser, "20260906-001-writable", "true")
		path := filepath.Join(c.definitionsRoot, string(migrationScopeUser), "20260906-001-writable.sh")
		if err := os.Chmod(path, 0o664); err != nil {
			t.Fatal(err)
		}
		if _, err := c.status(migrationScopeUser); err == nil || !strings.Contains(err.Error(), "must be package-owned and not group/world writable") {
			t.Fatalf("error=%v", err)
		}
	})
	t.Run("wrong owner", func(t *testing.T) {
		c := testMigrationConfig(t)
		writeMigration(t, c.definitionsRoot, migrationScopeUser, "20260906-001-owner", "true")
		c.trustedOwner = os.Geteuid() + 1
		if _, err := c.status(migrationScopeUser); err == nil || !strings.Contains(err.Error(), "directory must be package-owned") {
			t.Fatalf("error=%v", err)
		}
	})
}

func TestMigrationScopesAndLocksAreIndependent(t *testing.T) {
	c := testMigrationConfig(t)
	writeMigration(t, c.definitionsRoot, migrationScopeSystem, "20260906-001-system", "true")
	writeMigration(t, c.definitionsRoot, migrationScopeUser, "20260906-001-user", "true")
	lock, err := acquireMigrationLock(c.systemStateRoot, migrationScopeSystem)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if _, err := c.apply(migrationScopeSystem); err == nil || !strings.Contains(err.Error(), "already active") {
		t.Fatalf("system lock error=%v", err)
	}
	if _, err := c.apply(migrationScopeUser); err != nil {
		t.Fatalf("user scope should be independent: %v", err)
	}
	system, err := c.status(migrationScopeSystem)
	if err != nil {
		t.Fatal(err)
	}
	if got := migrationStatuses(system)["20260906-001-system"]; got != migrationPending {
		t.Fatalf("system migration=%s want pending", got)
	}
}

func TestMigrationPreservesUnrelatedState(t *testing.T) {
	c := testMigrationConfig(t)
	unrelated := filepath.Join(t.TempDir(), "custom.conf")
	if err := os.WriteFile(unrelated, []byte("owner setting\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	writeMigration(t, c.definitionsRoot, migrationScopeUser, "20260906-001-noop", "true")
	if _, err := c.apply(migrationScopeUser); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(unrelated)
	if err != nil || string(data) != "owner setting\n" {
		t.Fatalf("unrelated state changed: data=%q err=%v", data, err)
	}
}

func TestMigrationScopeFlagFailsClosed(t *testing.T) {
	for _, args := range [][]string{{"--scope"}, {"--scope", "other"}, {"--scope", "user", "extra"}, {"--scope", "user", "--scope", "system"}} {
		if _, _, err := migrationScopeFlag(args); err == nil {
			t.Fatalf("args=%q should fail", args)
		}
	}
	if scope, set, err := migrationScopeFlag([]string{"--json", "--scope", "user"}); err != nil || !set || scope != migrationScopeUser {
		t.Fatalf("scope=%q set=%v err=%v", scope, set, err)
	}
}

func TestMigrationStatePermissionsMatchScope(t *testing.T) {
	c := testMigrationConfig(t)
	writeMigration(t, c.definitionsRoot, migrationScopeSystem, "20260906-001-system", "true")
	writeMigration(t, c.definitionsRoot, migrationScopeUser, "20260906-001-user", "true")
	for _, scope := range []migrationScope{migrationScopeSystem, migrationScopeUser} {
		if _, err := c.apply(scope); err != nil {
			t.Fatal(err)
		}
		dirMode, fileMode := migrationStateModes(scope)
		root := c.stateRoot(scope)
		info, err := os.Stat(root)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != dirMode {
			t.Fatalf("%s state dir mode=%v want %v", scope, info.Mode().Perm(), dirMode)
		}
		info, err = os.Stat(filepath.Join(root, "state.json"))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != fileMode {
			t.Fatalf("%s state file mode=%v want %v", scope, info.Mode().Perm(), fileMode)
		}
	}
}
