package hardware

import (
	"errors"
	"reflect"
	"testing"
)

type exitStatus int

func (status exitStatus) Error() string { return "command exited" }
func (status exitStatus) ExitCode() int { return int(status) }

func TestCollectFirmwareParsesOfficialJSON(t *testing.T) {
	probe := readyPhysicalProbe()
	probe.commands[commandKey(firmwareDevicesCommand())] = struct {
		output string
		err    error
	}{output: `{"Devices":[{"Name":"System Firmware","DeviceId":"device-a","Version":"1.0"},{"Name":"Dock","DeviceId":"device-b","Version":"2.0"}]}`}
	probe.commands[commandKey(firmwareUpdatesCommand())] = struct {
		output string
		err    error
	}{output: `{"Devices":[{"Name":"System Firmware","DeviceId":"device-a","Version":"1.0","Releases":[{"Version":"1.1"}]}]}`}
	probe.commands[commandKey(firmwareRebootCommand())] = struct {
		output string
		err    error
	}{output: `{}`}

	state := Collect(probe)
	if !state.Firmware.Installed || state.Firmware.Devices != 2 || state.Firmware.Updates != 1 || !state.Firmware.RebootRequired {
		t.Fatalf("firmware=%#v", state.Firmware)
	}
	if state.Firmware.Status != StatusWarning || checkByID(t, state, "firmware-support").Status != StatusWarning {
		t.Fatalf("state=%#v", state)
	}
}

func TestCollectFirmwareFailsClosedOnMalformedJSON(t *testing.T) {
	probe := readyPhysicalProbe()
	probe.commands[commandKey(firmwareDevicesCommand())] = struct {
		output string
		err    error
	}{output: `{"Devices":[{}]}`}

	state := Collect(probe)
	if !state.Firmware.Installed || state.Firmware.Status != StatusUnavailable {
		t.Fatalf("firmware=%#v", state.Firmware)
	}
	if got := checkByID(t, state, "firmware-support").Status; got != StatusUnavailable {
		t.Fatalf("firmware-support=%q", got)
	}
}

func TestRefreshFirmwareUsesOnlyFixedRefreshCommand(t *testing.T) {
	probe := readyPhysicalProbe()
	probe.runs = nil
	probe.commands[commandKey(firmwareRefreshCommand())] = struct {
		output string
		err    error
	}{output: `{}`}
	if err := RefreshFirmware(probe); err != nil {
		t.Fatal(err)
	}
	if want := []string{commandKey(firmwareRefreshCommand())}; !reflect.DeepEqual(probe.runs, want) {
		t.Fatalf("commands=%q want %q", probe.runs, want)
	}
}

func TestApplyFirmwareRequiresFixedSafeCommandAndRecordsReboot(t *testing.T) {
	probe := readyPhysicalProbe()
	probe.runs = nil
	probe.commands[commandKey(firmwareApplyCommand())] = struct {
		output string
		err    error
	}{output: `{"Devices":[{"Name":"System Firmware","DeviceId":"device-a"}]}`}
	probe.commands[commandKey(firmwareRebootCommand())] = struct {
		output string
		err    error
	}{output: `{}`}

	result, err := ApplyFirmware(probe)
	if err != nil {
		t.Fatal(err)
	}
	if result.Schema != FirmwareResultSchema || result.Status != FirmwareResultRebootRequired || !result.RebootKnown || !result.RebootRequired || result.AttemptedAt == "" {
		t.Fatalf("result=%#v", result)
	}
	want := []string{commandKey(firmwareApplyCommand()), commandKey(firmwareRebootCommand())}
	if !reflect.DeepEqual(probe.runs, want) {
		t.Fatalf("commands=%q want %q", probe.runs, want)
	}
}

func TestApplyFirmwareRecordsFailureWithoutRebootProbe(t *testing.T) {
	probe := readyPhysicalProbe()
	probe.runs = nil
	probe.commands[commandKey(firmwareApplyCommand())] = struct {
		output string
		err    error
	}{output: `{"Error":{"Message":"write failed"}}`, err: errors.New("failed")}

	result, err := ApplyFirmware(probe)
	if err == nil || result.Status != FirmwareResultFailed || result.RebootKnown {
		t.Fatalf("result=%#v err=%v", result, err)
	}
	if len(probe.runs) != 1 || probe.runs[0] != commandKey(firmwareApplyCommand()) {
		t.Fatalf("commands=%q", probe.runs)
	}
}

func TestFirmwareCommandsPreserveSafetyAndExternalBoundaries(t *testing.T) {
	for _, command := range [][]string{firmwareDevicesCommand(), firmwareUpdatesCommand(), firmwareRebootCommand(), firmwareRefreshCommand(), firmwareApplyCommand()} {
		for _, argument := range command {
			switch argument {
			case "--force", "--allow-older", "--allow-reinstall", "--allow-branch-switch", "--no-safety-check", "--assume-yes", "enable-remote", "report-devices", "report-history", "reboot", "shutdown":
				t.Fatalf("unsafe argument %q in %q", argument, command)
			}
		}
	}
}

func commandKey(command []string) string {
	key := command[0]
	for _, arg := range command[1:] {
		key += " " + arg
	}
	return key
}
