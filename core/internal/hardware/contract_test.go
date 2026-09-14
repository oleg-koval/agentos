package hardware

import (
	"errors"
	"reflect"
	"testing"
)

type fakeProbe struct {
	arch     string
	env      map[string]string
	paths    map[string]bool
	commands map[string]struct {
		output string
		err    error
	}
	runs []string
}

func (p *fakeProbe) Architecture() string           { return p.arch }
func (p *fakeProbe) Environment(name string) string { return p.env[name] }
func (p *fakeProbe) PathExists(path string) bool    { return p.paths[path] }
func (p *fakeProbe) LookPath(name string) bool      { return p.paths[name] }
func (p *fakeProbe) Run(name string, args ...string) (string, error) {
	key := name
	for _, arg := range args {
		key += " " + arg
	}
	p.runs = append(p.runs, key)
	result, ok := p.commands[key]
	if !ok {
		return "", errors.New("unexpected command")
	}
	return result.output, result.err
}

func readyPhysicalProbe() *fakeProbe {
	return &fakeProbe{
		arch:  "amd64",
		env:   map[string]string{"XDG_SESSION_TYPE": "wayland"},
		paths: map[string]bool{"/sys/firmware/efi": true, "/usr/bin/fwupdmgr": true, "systemd-detect-virt": true, "bootctl": true, "findmnt": true, "nmcli": true},
		commands: map[string]struct {
			output string
			err    error
		}{
			"systemd-detect-virt":                     {output: "none", err: errors.New("exit status 1")},
			"bootctl is-installed":                    {output: "yes"},
			"findmnt --json --output FSTYPE,TARGET /": {output: `{"filesystems":[{"fstype":"btrfs","target":"/"}]}`},
			"nmcli -t -f STATE general":               {output: "connected (global)"},
			"/usr/bin/fwupdmgr get-devices --json --no-unreported-check --no-metadata-check --no-remote-check --no-security-fix":         {output: `{"Devices":[]}`},
			"/usr/bin/fwupdmgr get-updates --json --no-unreported-check --no-metadata-check --no-remote-check --no-security-fix":         {output: `{"Devices":[]}`, err: exitStatus(2)},
			"/usr/bin/fwupdmgr check-reboot-needed --json --no-unreported-check --no-metadata-check --no-remote-check --no-security-fix": {output: `{"Error":{"Code":3,"Message":"No reboot is necessary"}}`, err: exitStatus(2)},
		},
	}
}

func checkByID(t *testing.T, state State, id string) Check {
	t.Helper()
	for _, check := range state.Checks {
		if check.ID == id {
			return check
		}
	}
	t.Fatalf("check %q missing from %#v", id, state.Checks)
	return Check{}
}

func TestCollectPhysicalReadiness(t *testing.T) {
	probe := readyPhysicalProbe()
	state := Collect(probe)
	if state.Schema != Schema || state.Role != "physical" || state.Overall != StatusReady {
		t.Fatalf("state=%#v", state)
	}
	for _, id := range []string{"architecture", "machine-role", "boot-mode", "root-filesystem", "recovery", "connectivity", "graphical-session", "firmware-support"} {
		if got := checkByID(t, state, id).Status; got != StatusReady {
			t.Fatalf("%s=%q want ready", id, got)
		}
	}
	wantRuns := []string{"systemd-detect-virt", "bootctl is-installed", "findmnt --json --output FSTYPE,TARGET /", "nmcli -t -f STATE general", "/usr/bin/fwupdmgr get-devices --json --no-unreported-check --no-metadata-check --no-remote-check --no-security-fix", "/usr/bin/fwupdmgr get-updates --json --no-unreported-check --no-metadata-check --no-remote-check --no-security-fix", "/usr/bin/fwupdmgr check-reboot-needed --json --no-unreported-check --no-metadata-check --no-remote-check --no-security-fix"}
	if !reflect.DeepEqual(probe.runs, wantRuns) {
		t.Fatalf("commands=%q want %q", probe.runs, wantRuns)
	}
}

func TestCollectVPSMarksPhysicalChecksUnsupported(t *testing.T) {
	probe := readyPhysicalProbe()
	probe.commands["systemd-detect-virt"] = struct {
		output string
		err    error
	}{output: "kvm"}
	probe.commands["findmnt --json --output FSTYPE,TARGET /"] = struct {
		output string
		err    error
	}{output: `{"filesystems":[{"fstype":"ext4","target":"/"}]}`}
	state := Collect(probe)
	if state.Role != "vps" || state.Overall != StatusReady {
		t.Fatalf("state=%#v", state)
	}
	for _, id := range []string{"boot-mode", "recovery", "graphical-session", "firmware-support"} {
		if got := checkByID(t, state, id).Status; got != StatusUnsupported {
			t.Fatalf("%s=%q want unsupported", id, got)
		}
	}
	if checkByID(t, state, "root-filesystem").Status != StatusReady {
		t.Fatal("a detected VPS root filesystem should remain informational")
	}
}

func TestCollectMalformedOrMissingEvidenceNeverReportsReady(t *testing.T) {
	probe := readyPhysicalProbe()
	probe.commands["findmnt --json --output FSTYPE,TARGET /"] = struct {
		output string
		err    error
	}{output: `{not-json`}
	probe.paths["nmcli"] = false
	probe.paths["/usr/bin/fwupdmgr"] = false
	delete(probe.env, "XDG_SESSION_TYPE")
	state := Collect(probe)
	if state.Overall != StatusWarning {
		t.Fatalf("overall=%q want warning", state.Overall)
	}
	for _, id := range []string{"root-filesystem", "connectivity", "firmware-support"} {
		if got := checkByID(t, state, id).Status; got != StatusUnavailable {
			t.Fatalf("%s=%q want unavailable", id, got)
		}
	}
	if got := checkByID(t, state, "recovery").Status; got != StatusUnavailable {
		t.Fatalf("recovery=%q want unavailable", got)
	}
}

func TestCollectBlocksUnsupportedArchitectureAndLegacyBoot(t *testing.T) {
	probe := readyPhysicalProbe()
	probe.arch = "arm64"
	probe.paths["/sys/firmware/efi"] = false
	state := Collect(probe)
	if state.Overall != StatusBlocked {
		t.Fatalf("overall=%q want blocked", state.Overall)
	}
	if checkByID(t, state, "architecture").Status != StatusBlocked || checkByID(t, state, "boot-mode").Status != StatusBlocked {
		t.Fatalf("checks=%#v", state.Checks)
	}
}
