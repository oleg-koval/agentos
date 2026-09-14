package main

import (
	"agentos/core/internal/hardware"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

var collectHardwareState = hardware.CollectSystem

type hardwareOptions struct {
	Operation string
	JSON      bool
	Confirmed bool
}

func parseHardwareArgs(args []string) (hardwareOptions, error) {
	if len(args) == 0 {
		return hardwareOptions{Operation: "inspect"}, nil
	}
	if len(args) == 1 && args[0] == "--json" {
		return hardwareOptions{Operation: "inspect", JSON: true}, nil
	}
	if len(args) == 1 && args[0] == "firmware-enable" {
		return hardwareOptions{Operation: "firmware-enable"}, nil
	}
	if len(args) >= 1 && args[0] == "firmware-check" {
		if len(args) == 1 {
			return hardwareOptions{Operation: "firmware-check"}, nil
		}
		if len(args) == 2 && args[1] == "--json" {
			return hardwareOptions{Operation: "firmware-check", JSON: true}, nil
		}
	}
	if len(args) >= 1 && args[0] == "firmware-apply" {
		if len(args) == 2 && args[1] == "--confirm" {
			return hardwareOptions{Operation: "firmware-apply", Confirmed: true}, nil
		}
		if len(args) == 3 && args[1] == "--confirm" && args[2] == "--json" {
			return hardwareOptions{Operation: "firmware-apply", Confirmed: true, JSON: true}, nil
		}
	}
	return hardwareOptions{}, errors.New("usage: agentos hardware [--json|firmware-enable|firmware-check [--json]|firmware-apply --confirm [--json]]")
}

func renderHardware(state hardware.State, jsonOutput bool) ([]byte, error) {
	if jsonOutput {
		return json.MarshalIndent(state, "", "  ")
	}
	var output strings.Builder
	fmt.Fprintf(&output, "Hardware readiness: %s\n", state.Overall)
	fmt.Fprintf(&output, "Machine role: %s\n", state.Role)
	for _, check := range state.Checks {
		fmt.Fprintf(&output, "- %s: %s", check.ID, check.Status)
		if check.Detail != "" {
			fmt.Fprintf(&output, " (%s)", check.Detail)
		}
		output.WriteByte('\n')
	}
	return []byte(output.String()), nil
}

func hardwareCommand(args []string) error {
	options, err := parseHardwareArgs(args)
	if err != nil {
		return err
	}
	if options.Operation == "firmware-enable" {
		if _, err := os.Stat("/usr/bin/fwupdmgr"); err == nil {
			fmt.Println("Firmware support is already installed.")
			return nil
		}
		return runAndPrint("sudo", "pacman", "-S", "--needed", "fwupd")
	}
	probe := hardware.SystemProbe{}
	if options.Operation == "firmware-check" {
		if err := hardware.RefreshFirmware(probe); err != nil {
			return err
		}
	}
	if options.Operation == "firmware-apply" {
		if !options.Confirmed {
			return errors.New("firmware apply requires --confirm")
		}
		if os.Geteuid() != 0 {
			return errors.New("firmware apply requires sudo")
		}
		result, applyErr := hardware.ApplyFirmware(probe)
		if err := saveFirmwareResult(firmwareResultPath(), result); err != nil {
			return err
		}
		if err := printFirmwareResult(result, options.JSON); err != nil {
			return err
		}
		return applyErr
	}
	state := collectHardwareState()
	if options.Operation == "firmware-check" {
		state = hardware.Collect(probe)
	}
	output, err := renderHardware(state, options.JSON)
	if err != nil {
		return err
	}
	return writeCommandOutput(output)
}

func writeCommandOutput(output []byte) error {
	if _, err := os.Stdout.Write(output); err != nil {
		return err
	}
	if len(output) == 0 || output[len(output)-1] != '\n' {
		fmt.Println()
	}
	return nil
}

func firmwareResultPath() string {
	return env("AGENTOS_FIRMWARE_RESULT_STATE", "/var/lib/agentos/firmware-result.json")
}

func saveFirmwareResult(path string, result hardware.FirmwareResult) error {
	result.Schema = hardware.FirmwareResultSchema
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(path, append(data, '\n'), 0o600)
}

func printFirmwareResult(result hardware.FirmwareResult, jsonOutput bool) error {
	if jsonOutput {
		output, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return err
		}
		return writeCommandOutput(output)
	}
	reboot := "unknown"
	if result.RebootKnown {
		reboot = "no"
		if result.RebootRequired {
			reboot = "yes"
		}
	}
	return writeCommandOutput([]byte(fmt.Sprintf("Firmware update: %s\nReboot required: %s\n%s\n", result.Status, reboot, valueOr(result.Detail, "none"))))
}
