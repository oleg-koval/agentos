package main

import (
	"agentos/core/internal/updatestate"
	"os"
	"path/filepath"
	"testing"
)

func TestDesiredAgentOSPackagesRejectsWrongChannel(t *testing.T) {
	_, err := parseUpdateManifest([]byte(`{"schema":"agentos.release/v2","channel":"beta","version":"1.2.0","repository_url":"https://example.invalid/agentos","packages":[]}`), "stable")
	if err == nil {
		t.Fatal("wrong-channel manifest should fail")
	}
}

func TestAgentOSPackageComparisonUsesManifestVersions(t *testing.T) {
	manifest, err := parseUpdateManifest([]byte(`{"schema":"agentos.release/v2","channel":"stable","version":"1.2.0","repository_url":"https://example.invalid/agentos","packages":[{"name":"agentos-base-0.1.0-2-x86_64.pkg.tar.zst"},{"name":"agentos-keyring-1-1-any.pkg.tar.zst"},{"name":"agentos-runtime-0.4.13-39-x86_64.pkg.tar.zst"},{"name":"agentos-shell-0.4.3-16-x86_64.pkg.tar.zst"}]}`), "stable")
	if err != nil {
		t.Fatal(err)
	}
	installed := map[string]string{"agentos-base": "0.1.0-2", "agentos-keyring": "1-1", "agentos-runtime": "0.4.13-38", "agentos-shell": "0.4.3-16"}
	if !agentOSPackagesNeedUpdate(manifest.Packages, installed) {
		t.Fatal("runtime version difference should be available")
	}
	installed["agentos-runtime"] = "0.4.13-39"
	if agentOSPackagesNeedUpdate(manifest.Packages, installed) {
		t.Fatal("matching package set should be current")
	}
}

func TestUpdateRecordRoundTripAndBoundedFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "update.json")
	record := updatestate.Record{Schema: updatestate.Schema, Status: updatestate.StatusApplyFailed, LastFailure: boundedUpdateFailure(string(make([]byte, 900)))}
	if err := saveUpdateRecord(path, record, 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadUpdateRecord(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Status != updatestate.StatusApplyFailed || len(loaded.LastFailure) > 512 {
		t.Fatalf("record=%#v", loaded)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode=%v err=%v", info.Mode().Perm(), err)
	}
}

func TestKernelUpdateRequiresManualReboot(t *testing.T) {
	if !updateRequiresReboot([]string{"linux 6.10 6.11"}) {
		t.Fatal("kernel update should require reboot")
	}
	if updateRequiresReboot([]string{"curl 1 2", "agentos-runtime 1 2"}) {
		t.Fatal("ordinary packages should not require reboot")
	}
}

func TestCurrentBootIDUsesConfiguredPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "boot-id")
	if err := os.WriteFile(path, []byte("boot-a\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTOS_BOOT_ID_FILE", path)
	if got := currentBootID(); got != "boot-a" {
		t.Fatalf("boot id=%q", got)
	}
}
