package recovery

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCollectDistinguishesRootOnlyAndBootSafePoints(t *testing.T) {
	paths := fixturePaths(t)
	rootOnly := "pre-pacman-20260907-090000"
	bootSafe := "pre-pacman-20260907-100000"
	mustMkdir(t, filepath.Join(paths.SnapshotDir, rootOnly))
	mustMkdir(t, filepath.Join(paths.SnapshotDir, bootSafe))
	writeBootBundle(t, paths, bootSafe)

	state := Collect(paths, "@")
	if state.Schema != Schema || state.Status != StatusReady || state.CurrentRoot != "@" {
		t.Fatalf("state=%#v", state)
	}
	if len(state.Points) != 2 || state.Points[0].ID != bootSafe || !state.Points[0].BootSafe || state.Points[1].ID != rootOnly || state.Points[1].BootSafe {
		t.Fatalf("points=%#v", state.Points)
	}
	if !state.CanStage(bootSafe) || state.CanStage(rootOnly) {
		t.Fatalf("stageability=%#v", state.Points)
	}
}

func TestCollectReportsStagedAndCurrentRollbackState(t *testing.T) {
	paths := fixturePaths(t)
	id := "pre-pacman-20260907-100000"
	mustMkdir(t, filepath.Join(paths.SnapshotDir, id))
	writeBootBundle(t, paths, id)
	mustWrite(t, paths.StateFile, "ROLLBACK_SUBVOL=@rollback-20260907-110000\nSOURCE_SNAPSHOT="+id+"\nRECOVERY_ENTRY=agentos-rollback.conf\nSTAGED_AT=2026-09-07T11:00:00+00:00\n")

	staged := Collect(paths, "@")
	if staged.Staged == nil || staged.Staged.SourceID != id || staged.NextBoot != NextBootRollbackOnce || staged.CurrentRollback {
		t.Fatalf("staged=%#v", staged)
	}
	current := Collect(paths, "@rollback-20260907-110000")
	if !current.CurrentRollback || current.NextBoot != NextBootNormal {
		t.Fatalf("current=%#v", current)
	}
}

func TestCollectFailsClosedOnMalformedOrUnsafeStagedState(t *testing.T) {
	for _, content := range []string{
		"SOURCE_SNAPSHOT=../../etc\nROLLBACK_SUBVOL=@rollback-test\n",
		"SOURCE_SNAPSHOT=pre-pacman-20260907-100000\nROLLBACK_SUBVOL=bad target\n",
		"SOURCE_SNAPSHOT=pre-pacman-20260907-100000\nROLLBACK_SUBVOL=@rollback-test\nUNKNOWN=value\n",
	} {
		t.Run(content, func(t *testing.T) {
			paths := fixturePaths(t)
			mustWrite(t, paths.StateFile, content)
			state := Collect(paths, "@")
			if state.Status != StatusUnavailable || state.Staged != nil || state.CanStage("pre-pacman-20260907-100000") {
				t.Fatalf("state=%#v", state)
			}
		})
	}
}

func TestCollectFailsClosedWhenBootManifestDoesNotMatch(t *testing.T) {
	paths := fixturePaths(t)
	id := "pre-pacman-20260907-100000"
	mustMkdir(t, filepath.Join(paths.SnapshotDir, id))
	writeBootBundle(t, paths, id)
	mustWrite(t, filepath.Join(paths.BootSnapshotDir, id, "vmlinuz-linux"), "tampered")
	state := Collect(paths, "@")
	if len(state.Points) != 1 || state.Points[0].BootSafe {
		t.Fatalf("points=%#v", state.Points)
	}
}

func TestCollectRejectsBootManifestSymlinkEscape(t *testing.T) {
	paths := fixturePaths(t)
	id := "pre-pacman-20260907-100000"
	mustMkdir(t, filepath.Join(paths.SnapshotDir, id))
	bundle := filepath.Join(paths.BootSnapshotDir, id)
	mustMkdir(t, filepath.Join(bundle, "loader", "entries"))
	mustWrite(t, filepath.Join(bundle, "loader", "entries", "arch.conf"), "title Arch\n")
	outside := filepath.Join(t.TempDir(), "outside")
	mustWrite(t, outside, "kernel")
	if err := os.Symlink(filepath.Dir(outside), filepath.Join(bundle, "escape")); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(bundle, "MANIFEST.sha256"), "6923dd1bc0460082c5d55a831908c24a282860b7f1cd6c2b79cf1bc8857c639c  ./escape/outside\n")
	state := Collect(paths, "@")
	if len(state.Points) != 1 || state.Points[0].BootSafe {
		t.Fatalf("points=%#v", state.Points)
	}
}

func TestValidPointIDRejectsPathsAndLoosePrefixes(t *testing.T) {
	for _, id := range []string{"pre-pacman-20260907-100000", "pre-pacman-20260907-100000-123-456"} {
		if !ValidPointID(id) {
			t.Fatalf("valid ID rejected: %q", id)
		}
	}
	for _, id := range []string{"", "pre-pacman-", "../pre-pacman-20260907-100000", "pre-pacman-20260907-100000/x", "pre-pacman-20260907-100000;reboot"} {
		if ValidPointID(id) {
			t.Fatalf("invalid ID accepted: %q", id)
		}
	}
}

func fixturePaths(t *testing.T) Paths {
	t.Helper()
	root := t.TempDir()
	paths := Paths{
		SnapshotDir:     filepath.Join(root, "snapshots"),
		BootSnapshotDir: filepath.Join(root, "snapshots", "boot"),
		StateFile:       filepath.Join(root, "state", "rollback.env"),
	}
	mustMkdir(t, paths.SnapshotDir)
	return paths
}

func writeBootBundle(t *testing.T, paths Paths, id string) {
	t.Helper()
	bundle := filepath.Join(paths.BootSnapshotDir, id)
	mustMkdir(t, filepath.Join(bundle, "loader", "entries"))
	mustWrite(t, filepath.Join(bundle, "loader", "entries", "arch.conf"), "title Arch\nlinux /vmlinuz-linux\n")
	mustWrite(t, filepath.Join(bundle, "vmlinuz-linux"), "kernel")
	mustWrite(t, filepath.Join(bundle, "MANIFEST.sha256"), "6923dd1bc0460082c5d55a831908c24a282860b7f1cd6c2b79cf1bc8857c639c  ./vmlinuz-linux\n")
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	mustMkdir(t, filepath.Dir(path))
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
