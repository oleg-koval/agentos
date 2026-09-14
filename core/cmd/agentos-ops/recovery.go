package main

import (
	"agentos/core/internal/recovery"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

var collectRecoveryState = recovery.CollectSystem
var recoveryEUID = os.Geteuid
var runRecoveryMutation = func(args ...string) error {
	return runAndPrint("/usr/bin/rollback-workstation", args...)
}

type recoveryOptions struct {
	Operation string
	PointID   string
	JSON      bool
}

func parseRecoveryArgs(args []string) (recoveryOptions, error) {
	if len(args) == 0 {
		return recoveryOptions{Operation: "inspect"}, nil
	}
	if len(args) == 1 && args[0] == "--json" {
		return recoveryOptions{Operation: "inspect", JSON: true}, nil
	}
	if len(args) >= 1 && args[0] == "stage" {
		if (len(args) == 3 || len(args) == 4) && recovery.ValidPointID(args[1]) && args[2] == "--confirm" && (len(args) == 3 || args[3] == "--json") {
			return recoveryOptions{Operation: "stage", PointID: args[1], JSON: len(args) == 4}, nil
		}
	}
	if len(args) >= 1 && args[0] == "cancel" {
		if (len(args) == 2 || len(args) == 3) && args[1] == "--confirm" && (len(args) == 2 || args[2] == "--json") {
			return recoveryOptions{Operation: "cancel", JSON: len(args) == 3}, nil
		}
	}
	return recoveryOptions{}, errors.New("usage: agentos recovery [--json|stage RECOVERY_POINT_ID --confirm [--json]|cancel --confirm [--json]]")
}

func renderRecovery(state recovery.State, jsonOutput bool) ([]byte, error) {
	if jsonOutput {
		return json.MarshalIndent(state, "", "  ")
	}
	var output strings.Builder
	fmt.Fprintf(&output, "Recovery: %s\n", state.Status)
	if state.CurrentRoot != "" {
		fmt.Fprintf(&output, "Current root: %s\n", state.CurrentRoot)
	}
	fmt.Fprintf(&output, "Next boot: %s\n", state.NextBoot)
	if state.Staged != nil {
		fmt.Fprintf(&output, "Staged from: %s\n", state.Staged.SourceID)
	}
	output.WriteString("Recovery points:\n")
	for _, point := range state.Points {
		kind := "root-only"
		if point.BootSafe {
			kind = "boot-safe"
		}
		fmt.Fprintf(&output, "- %s (%s)\n", point.ID, kind)
	}
	return []byte(output.String()), nil
}

func recoveryCommand(args []string) error {
	options, err := parseRecoveryArgs(args)
	if err != nil {
		return err
	}
	state := collectRecoveryState()
	if options.Operation == "inspect" {
		output, err := renderRecovery(state, options.JSON)
		if err != nil {
			return err
		}
		return writeCommandOutput(output)
	}
	if recoveryEUID() != 0 {
		return errors.New("recovery mutation requires sudo")
	}
	if state.Status != recovery.StatusReady {
		return errors.New("recovery state is unavailable")
	}
	switch options.Operation {
	case "stage":
		if !state.CanStage(options.PointID) {
			return errors.New("recovery point is not boot-safe or a rollback is already staged")
		}
		if err := runRecoveryMutation("stage", options.PointID); err != nil {
			return err
		}
	case "cancel":
		if state.Staged == nil {
			return errors.New("no rollback is staged")
		}
		if err := runRecoveryMutation("cancel"); err != nil {
			return err
		}
	}
	output, err := renderRecovery(collectRecoveryState(), options.JSON)
	if err != nil {
		return err
	}
	return writeCommandOutput(output)
}
