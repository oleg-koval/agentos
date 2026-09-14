package hardware

import (
	"encoding/json"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

const Schema = "agentos.hardware/v1"

type Status string

const (
	StatusReady       Status = "ready"
	StatusWarning     Status = "warning"
	StatusBlocked     Status = "blocked"
	StatusUnsupported Status = "unsupported"
	StatusUnavailable Status = "unavailable"
)

type Check struct {
	ID     string `json:"id"`
	Status Status `json:"status"`
	Detail string `json:"detail,omitempty"`
}

type State struct {
	Schema   string        `json:"schema"`
	Role     string        `json:"role"`
	Overall  Status        `json:"overall"`
	Checks   []Check       `json:"checks"`
	Firmware FirmwareState `json:"firmware"`
}

type Probe interface {
	Architecture() string
	Environment(string) string
	PathExists(string) bool
	LookPath(string) bool
	Run(string, ...string) (string, error)
}

type SystemProbe struct{}

func (SystemProbe) Architecture() string           { return runtime.GOARCH }
func (SystemProbe) Environment(name string) string { return os.Getenv(name) }
func (SystemProbe) PathExists(path string) bool    { _, err := os.Stat(path); return err == nil }
func (SystemProbe) LookPath(name string) bool      { _, err := exec.LookPath(name); return err == nil }
func (SystemProbe) Run(name string, args ...string) (string, error) {
	output, err := exec.Command(name, args...).CombinedOutput()
	return strings.TrimSpace(string(output)), err
}

func CollectSystem() State { return Collect(SystemProbe{}) }

func Collect(probe Probe) State {
	checks := make([]Check, 0, 8)
	architecture := probe.Architecture()
	architectureDetail := architecture
	if architecture == "amd64" {
		architectureDetail = "x86_64"
	}
	architectureStatus := StatusReady
	if architecture != "amd64" {
		architectureStatus = StatusBlocked
	}
	checks = append(checks, Check{ID: "architecture", Status: architectureStatus, Detail: architectureDetail})

	role, virtualization, roleStatus := detectRole(probe)
	checks = append(checks, Check{ID: "machine-role", Status: roleStatus, Detail: virtualization})

	checks = append(checks, bootCheck(probe, role, roleStatus))
	root, filesystem := rootFilesystemCheck(probe)
	checks = append(checks, root)
	checks = append(checks, recoveryCheck(role, roleStatus, root.Status, filesystem))
	checks = append(checks, connectivityCheck(probe))
	checks = append(checks, graphicalSessionCheck(probe, role, roleStatus))
	firmwareCheck, firmware := collectFirmware(probe, role, roleStatus)
	checks = append(checks, firmwareCheck)

	return State{Schema: Schema, Role: role, Overall: overallStatus(checks), Checks: checks, Firmware: firmware}
}

func detectRole(probe Probe) (string, string, Status) {
	if !probe.LookPath("systemd-detect-virt") {
		return "unknown", "virtualization detector unavailable", StatusUnavailable
	}
	virtualization, err := probe.Run("systemd-detect-virt")
	virtualization = normalizedToken(virtualization)
	if virtualization == "none" {
		return "physical", "bare metal", StatusReady
	}
	if err != nil || virtualization == "" {
		return "unknown", "virtualization could not be determined", StatusUnavailable
	}
	return "vps", "virtualized: " + virtualization, StatusReady
}

func bootCheck(probe Probe, role string, roleStatus Status) Check {
	if roleStatus != StatusReady {
		return Check{ID: "boot-mode", Status: StatusUnavailable, Detail: "machine role unavailable"}
	}
	if role == "vps" {
		return Check{ID: "boot-mode", Status: StatusUnsupported, Detail: "not applicable on a VPS"}
	}
	if !probe.PathExists("/sys/firmware/efi") {
		return Check{ID: "boot-mode", Status: StatusBlocked, Detail: "legacy boot; UEFI required"}
	}
	if !probe.LookPath("bootctl") {
		return Check{ID: "boot-mode", Status: StatusUnavailable, Detail: "UEFI detected; bootctl unavailable"}
	}
	if _, err := probe.Run("bootctl", "is-installed"); err != nil {
		return Check{ID: "boot-mode", Status: StatusWarning, Detail: "UEFI detected; systemd-boot not confirmed"}
	}
	return Check{ID: "boot-mode", Status: StatusReady, Detail: "UEFI with systemd-boot"}
}

func rootFilesystemCheck(probe Probe) (Check, string) {
	if !probe.LookPath("findmnt") {
		return Check{ID: "root-filesystem", Status: StatusUnavailable, Detail: "findmnt unavailable"}, ""
	}
	output, err := probe.Run("findmnt", "--json", "--output", "FSTYPE,TARGET", "/")
	if err != nil {
		return Check{ID: "root-filesystem", Status: StatusUnavailable, Detail: "root filesystem could not be inspected"}, ""
	}
	var result struct {
		Filesystems []struct {
			Filesystem string `json:"fstype"`
			Target     string `json:"target"`
		} `json:"filesystems"`
	}
	if json.Unmarshal([]byte(output), &result) != nil || len(result.Filesystems) != 1 {
		return Check{ID: "root-filesystem", Status: StatusUnavailable, Detail: "invalid findmnt result"}, ""
	}
	filesystem := normalizedToken(result.Filesystems[0].Filesystem)
	if filesystem == "" || result.Filesystems[0].Target != "/" {
		return Check{ID: "root-filesystem", Status: StatusUnavailable, Detail: "incomplete findmnt result"}, ""
	}
	return Check{ID: "root-filesystem", Status: StatusReady, Detail: filesystem}, filesystem
}

func recoveryCheck(role string, roleStatus, rootStatus Status, filesystem string) Check {
	if roleStatus != StatusReady {
		return Check{ID: "recovery", Status: StatusUnavailable, Detail: "machine role unavailable"}
	}
	if role == "vps" {
		return Check{ID: "recovery", Status: StatusUnsupported, Detail: "use provider recovery on a VPS"}
	}
	if rootStatus != StatusReady {
		return Check{ID: "recovery", Status: StatusUnavailable, Detail: "root filesystem unavailable"}
	}
	if filesystem != "btrfs" {
		return Check{ID: "recovery", Status: StatusBlocked, Detail: "Btrfs root required for AgentOS snapshots"}
	}
	return Check{ID: "recovery", Status: StatusReady, Detail: "Btrfs root supports recovery snapshots"}
}

func connectivityCheck(probe Probe) Check {
	if !probe.LookPath("nmcli") {
		return Check{ID: "connectivity", Status: StatusUnavailable, Detail: "NetworkManager status unavailable"}
	}
	output, err := probe.Run("nmcli", "-t", "-f", "STATE", "general")
	state := normalizedToken(output)
	if err != nil || state == "" {
		return Check{ID: "connectivity", Status: StatusUnavailable, Detail: "NetworkManager status unavailable"}
	}
	if strings.HasPrefix(state, "connected") {
		return Check{ID: "connectivity", Status: StatusReady, Detail: state}
	}
	return Check{ID: "connectivity", Status: StatusWarning, Detail: state}
}

func graphicalSessionCheck(probe Probe, role string, roleStatus Status) Check {
	if roleStatus != StatusReady {
		return Check{ID: "graphical-session", Status: StatusUnavailable, Detail: "machine role unavailable"}
	}
	if role == "vps" {
		return Check{ID: "graphical-session", Status: StatusUnsupported, Detail: "not required on a VPS"}
	}
	session := normalizedToken(probe.Environment("XDG_SESSION_TYPE"))
	if session == "wayland" {
		return Check{ID: "graphical-session", Status: StatusReady, Detail: "Wayland session"}
	}
	if session == "" {
		return Check{ID: "graphical-session", Status: StatusWarning, Detail: "no graphical session detected"}
	}
	return Check{ID: "graphical-session", Status: StatusWarning, Detail: session + " session; Wayland expected"}
}

func normalizedToken(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if index := strings.IndexByte(value, '\n'); index >= 0 {
		value = value[:index]
	}
	if len(value) > 80 {
		value = value[:80]
	}
	return value
}

func overallStatus(checks []Check) Status {
	overall := StatusReady
	for _, check := range checks {
		if check.Status == StatusBlocked {
			return StatusBlocked
		}
		if check.Status == StatusWarning || check.Status == StatusUnavailable {
			overall = StatusWarning
		}
	}
	return overall
}
