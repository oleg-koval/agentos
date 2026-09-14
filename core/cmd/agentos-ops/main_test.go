package main

import (
	"agentos/core/internal/hardware"
	"agentos/core/internal/maintenance"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestRepositoryVerifyLocalSignaturesMissingKeyFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("AGENTOS_SIGNING_KEY_FILE", filepath.Join(dir, "does-not-exist.asc"))
	c := envConfig{repoState: filepath.Join(dir, "repository.json")}
	err := repositoryVerifyLocalSignatures(c)
	if err == nil || !strings.Contains(err.Error(), "signing public key not found") {
		t.Fatalf("got unexpected error: %v", err)
	}
}

func TestReadRegistryRejectsDuplicateIDs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "capabilities.json")
	data := `{"capabilities":[{"id":"one","kind":"capability"},{"id":"one","kind":"agent"}]}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readRegistry(path); err == nil {
		t.Fatal("duplicate capability IDs were accepted")
	}
}

func TestCapabilityIDsValidateAllRequestedBeforeApply(t *testing.T) {
	registry := map[string]capability{"known": {ID: "known", Kind: "capability"}}
	if _, err := capabilityIDs(registry, []string{"known", "missing"}); err == nil {
		t.Fatal("unknown capability was accepted")
	}
}

func TestSnapshotFromOutput(t *testing.T) {
	if got := snapshotFromOutput("Created pre-pacman snapshot: /.snapshots/pre-pacman-20260830-120000\n"); got != "pre-pacman-20260830-120000" {
		t.Fatalf("snapshot = %q", got)
	}
	if got := snapshotFromOutput("snapshot failed\n"); got != "" {
		t.Fatalf("unexpected snapshot = %q", got)
	}
}

func TestNormalizeFingerprint(t *testing.T) {
	if got := normalizeFingerprint(" abcd 1234\n"); got != "ABCD1234" {
		t.Fatalf("fingerprint = %q", got)
	}
}

func TestRepositoryBaseURLSplitsChannelSuffix(t *testing.T) {
	base, previous, err := repositoryBaseURL("https://example.invalid/agentos/beta")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if base != "https://example.invalid/agentos" || previous != "beta" {
		t.Fatalf("got base=%q previous=%q", base, previous)
	}
	if _, _, err := repositoryBaseURL("https://example.invalid/agentos"); err == nil {
		t.Fatal("expected error for a URL with no channel suffix")
	}
}

func TestSigningSubkeyExpiryReadsEarliestSubkey(t *testing.T) {
	dir := t.TempDir()
	fpr := "3060184CFC884D14CB1D54F9CA25144B4E4DBA8E"
	fakeBin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(fakeBin, 0o755); err != nil {
		t.Fatal(err)
	}
	earliestFuture := time.Now().Add(48 * time.Hour).Unix()
	laterFuture := time.Now().Add(720 * time.Hour).Unix()
	script := "#!/usr/bin/env bash\ncat <<EOF\nsub:::::::::::::" +
		"\nsub:u:255:22:AAAA:0:" + strconvItoa(laterFuture) + "::::::::" +
		"\nsub:u:255:22:BBBB:0:" + strconvItoa(earliestFuture) + "::::::::" +
		"\nEOF\n"
	if err := os.WriteFile(filepath.Join(fakeBin, "gpg"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	state := repositoryState{Schema: "agentos.repository/v1", Configured: true, Fingerprint: fpr}
	data, _ := json.Marshal(state)
	statePath := filepath.Join(dir, "repository.json")
	if err := os.WriteFile(statePath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	c := envConfig{repoState: statePath}
	days, err := signingSubkeyExpiry(c)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if days < 1 || days > 2 {
		t.Fatalf("expected roughly 2 days remaining (earliest subkey), got %d", days)
	}
}

func strconvItoa(v int64) string {
	return strconv.FormatInt(v, 10)
}

func TestPrintExpiryHintDetectsExpiredSignature(t *testing.T) {
	if !expiryHintApplies("error: agentos: signature from \"AgentOS\" is expired") {
		t.Fatal("expected expiry hint to fire on an expired-signature message")
	}
	if expiryHintApplies("everything is fine") {
		t.Fatal("did not expect expiry hint to fire on unrelated output")
	}
}

func TestMaintenanceStateReportsImplementedOperationsOnly(t *testing.T) {
	original := collectHardwareState
	t.Cleanup(func() { collectHardwareState = original })
	collectHardwareState = func() hardware.State {
		return hardware.State{Role: "physical", Firmware: hardware.FirmwareState{Status: hardware.StatusReady, Installed: true}}
	}
	state := maintenanceState()
	if !state.Update.Available || state.Update.Status != "ready" {
		t.Fatalf("update=%#v want ready", state.Update)
	}
	if state.Migrations.Available || state.Recovery.Available {
		t.Fatalf("unimplemented operations reported available: %#v", state)
	}
	if !state.Hardware.Available || state.Hardware.Status != maintenance.StatusReady {
		t.Fatalf("hardware=%#v want ready", state.Hardware)
	}
	for _, action := range state.Actions {
		if action.ID == "firmware-enable" && action.Available {
			t.Fatalf("firmware enable=%#v want unavailable when installed", action)
		}
		if (action.ID == "firmware-check" || action.ID == "firmware-apply") && !action.Available {
			t.Fatalf("firmware action=%#v want available", action)
		}
	}
}
