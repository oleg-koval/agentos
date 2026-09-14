package hardware

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const FirmwareResultSchema = "agentos.firmware-result/v1"
const firmwareManagerPath = "/usr/bin/fwupdmgr"

type FirmwareResultStatus string

const (
	FirmwareResultSucceeded      FirmwareResultStatus = "succeeded"
	FirmwareResultFailed         FirmwareResultStatus = "failed"
	FirmwareResultRebootRequired FirmwareResultStatus = "reboot-required"
)

type FirmwareState struct {
	Status         Status `json:"status"`
	Installed      bool   `json:"installed"`
	Devices        int    `json:"devices"`
	Updates        int    `json:"updates"`
	RebootRequired bool   `json:"reboot_required"`
	Detail         string `json:"detail,omitempty"`
}

type FirmwareResult struct {
	Schema         string               `json:"schema"`
	Status         FirmwareResultStatus `json:"status"`
	AttemptedAt    string               `json:"attempted_at"`
	RebootKnown    bool                 `json:"reboot_known"`
	RebootRequired bool                 `json:"reboot_required"`
	Detail         string               `json:"detail,omitempty"`
}

var firmwarePassiveFlags = []string{
	"--json",
	"--no-unreported-check",
	"--no-metadata-check",
	"--no-remote-check",
	"--no-security-fix",
}

func firmwareCommand(name string, additional ...string) []string {
	command := []string{firmwareManagerPath, name}
	command = append(command, firmwarePassiveFlags...)
	return append(command, additional...)
}

func firmwareDevicesCommand() []string { return firmwareCommand("get-devices") }
func firmwareUpdatesCommand() []string { return firmwareCommand("get-updates") }
func firmwareRebootCommand() []string  { return firmwareCommand("check-reboot-needed") }
func firmwareRefreshCommand() []string {
	return firmwareCommand("refresh", "--no-reboot-check")
}
func firmwareApplyCommand() []string {
	return firmwareCommand("update", "--no-reboot-check")
}

func runFirmwareCommand(probe Probe, command []string) (string, error) {
	return probe.Run(command[0], command[1:]...)
}

func commandSucceeded(err error) bool {
	if err == nil {
		return true
	}
	var status interface{ ExitCode() int }
	return errors.As(err, &status) && status.ExitCode() == 2
}

type fwupdDevice struct {
	Name     string `json:"Name"`
	DeviceID string `json:"DeviceId"`
	Releases []struct {
		Version string `json:"Version"`
	} `json:"Releases"`
}

func parseFwupdDevices(data string, countUpdates bool) (int, error) {
	var envelope struct {
		Devices json.RawMessage `json:"Devices"`
	}
	if json.Unmarshal([]byte(data), &envelope) != nil || len(envelope.Devices) == 0 || string(envelope.Devices) == "null" {
		return 0, errors.New("invalid fwupd JSON")
	}
	var devices []fwupdDevice
	if json.Unmarshal(envelope.Devices, &devices) != nil {
		return 0, errors.New("invalid fwupd device list")
	}
	count := 0
	for _, device := range devices {
		if strings.TrimSpace(device.Name) == "" || strings.TrimSpace(device.DeviceID) == "" {
			return 0, errors.New("incomplete fwupd device")
		}
		if !countUpdates {
			count++
			continue
		}
		if len(device.Releases) == 0 {
			continue
		}
		for _, release := range device.Releases {
			if strings.TrimSpace(release.Version) == "" {
				return 0, errors.New("incomplete fwupd release")
			}
		}
		count++
	}
	return count, nil
}

func rebootRequired(probe Probe) (bool, error) {
	_, err := runFirmwareCommand(probe, firmwareRebootCommand())
	if err == nil {
		return true, nil
	}
	var status interface{ ExitCode() int }
	if errors.As(err, &status) && status.ExitCode() == 2 {
		return false, nil
	}
	return false, errors.New("firmware reboot state unavailable")
}

func collectFirmware(probe Probe, role string, roleStatus Status) (Check, FirmwareState) {
	state := FirmwareState{Status: StatusUnavailable}
	if roleStatus != StatusReady {
		state.Detail = "machine role unavailable"
		return Check{ID: "firmware-support", Status: state.Status, Detail: state.Detail}, state
	}
	if role == "vps" {
		state.Status = StatusUnsupported
		state.Detail = "firmware is managed by the VPS provider"
		return Check{ID: "firmware-support", Status: state.Status, Detail: state.Detail}, state
	}
	if !probe.PathExists(firmwareManagerPath) {
		state.Detail = "fwupd is not installed; enable on demand"
		return Check{ID: "firmware-support", Status: state.Status, Detail: state.Detail}, state
	}
	state.Installed = true
	devicesJSON, devicesErr := runFirmwareCommand(probe, firmwareDevicesCommand())
	updatesJSON, updatesErr := runFirmwareCommand(probe, firmwareUpdatesCommand())
	if !commandSucceeded(devicesErr) || !commandSucceeded(updatesErr) {
		state.Detail = "fwupd discovery unavailable"
		return Check{ID: "firmware-support", Status: state.Status, Detail: state.Detail}, state
	}
	devices, err := parseFwupdDevices(devicesJSON, false)
	if err != nil {
		state.Detail = "invalid fwupd device result"
		return Check{ID: "firmware-support", Status: state.Status, Detail: state.Detail}, state
	}
	updates, err := parseFwupdDevices(updatesJSON, true)
	if err != nil {
		state.Detail = "invalid fwupd update result"
		return Check{ID: "firmware-support", Status: state.Status, Detail: state.Detail}, state
	}
	reboot, err := rebootRequired(probe)
	if err != nil {
		state.Detail = "firmware reboot state unavailable"
		return Check{ID: "firmware-support", Status: state.Status, Detail: state.Detail}, state
	}
	state.Status = StatusReady
	state.Devices = devices
	state.Updates = updates
	state.RebootRequired = reboot
	state.Detail = fmt.Sprintf("%d device(s); %d update(s)", devices, updates)
	if updates > 0 || reboot {
		state.Status = StatusWarning
	}
	if reboot {
		state.Detail += "; reboot required"
	}
	return Check{ID: "firmware-support", Status: state.Status, Detail: state.Detail}, state
}

func RefreshFirmware(probe Probe) error {
	if !probe.PathExists(firmwareManagerPath) {
		return errors.New("fwupd is not installed")
	}
	_, err := runFirmwareCommand(probe, firmwareRefreshCommand())
	if !commandSucceeded(err) {
		return errors.New("firmware metadata refresh failed")
	}
	return nil
}

func ApplyFirmware(probe Probe) (FirmwareResult, error) {
	result := FirmwareResult{Schema: FirmwareResultSchema, Status: FirmwareResultFailed, AttemptedAt: time.Now().UTC().Format(time.RFC3339)}
	if !probe.PathExists(firmwareManagerPath) {
		result.Detail = "fwupd is not installed"
		return result, errors.New(result.Detail)
	}
	_, err := runFirmwareCommand(probe, firmwareApplyCommand())
	if !commandSucceeded(err) {
		result.Detail = "firmware update failed"
		return result, errors.New(result.Detail)
	}
	result.Status = FirmwareResultSucceeded
	reboot, rebootErr := rebootRequired(probe)
	if rebootErr != nil {
		result.Detail = "firmware updated; reboot requirement unavailable"
		return result, rebootErr
	}
	result.RebootKnown = true
	result.RebootRequired = reboot
	if reboot {
		result.Status = FirmwareResultRebootRequired
		result.Detail = "firmware updated; reboot required"
	} else {
		result.Detail = "firmware update completed"
	}
	return result, nil
}
