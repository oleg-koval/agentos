package maintenance

const Schema = "agentos.maintenance/v1"

type Status string

const (
	StatusUnavailable    Status = "unavailable"
	StatusReady          Status = "ready"
	StatusLaunched       Status = "launched"
	StatusSucceeded      Status = "succeeded"
	StatusFailed         Status = "failed"
	StatusRebootRequired Status = "reboot-required"
)

type Operation struct {
	Status         Status `json:"status"`
	Available      bool   `json:"available"`
	RequiresReboot bool   `json:"requires_reboot"`
	Pending        int    `json:"pending,omitempty"`
	Failed         int    `json:"failed,omitempty"`
	Revision       string `json:"revision,omitempty"`
}

type Action struct {
	ID             string   `json:"id"`
	Operation      string   `json:"operation"`
	Available      bool     `json:"available"`
	RequiresAuth   bool     `json:"requires_auth"`
	RequiresReboot bool     `json:"requires_reboot"`
	Parameters     []string `json:"parameters"`
}

type State struct {
	Schema     string    `json:"schema"`
	Update     Operation `json:"update"`
	Migrations Operation `json:"migrations"`
	Hardware   Operation `json:"hardware"`
	Recovery   Operation `json:"recovery"`
	Actions    []Action  `json:"actions"`
}

type Availability struct {
	Update         bool
	Migrations     bool
	Hardware       bool
	FirmwareEnable bool
	Firmware       bool
	Recovery       bool
	RecoveryStage  bool
	RecoveryCancel bool
}

func NewState(available Availability) State {
	return State{
		Schema:     Schema,
		Update:     operation(available.Update),
		Migrations: operation(available.Migrations),
		Hardware:   operation(available.Hardware),
		Recovery:   operation(available.Recovery),
		Actions: []Action{
			{ID: "update-check", Operation: "update", Available: available.Update, Parameters: []string{}},
			{ID: "update-apply", Operation: "update", Available: available.Update, RequiresAuth: true, Parameters: []string{}},
			{ID: "migration-apply-user", Operation: "migrations", Available: available.Migrations, Parameters: []string{}},
			{ID: "firmware-enable", Operation: "hardware", Available: available.FirmwareEnable, RequiresAuth: true, Parameters: []string{}},
			{ID: "firmware-check", Operation: "hardware", Available: available.Firmware, Parameters: []string{}},
			{ID: "firmware-apply", Operation: "hardware", Available: available.Firmware, RequiresAuth: true, Parameters: []string{}},
			{ID: "recovery-stage", Operation: "recovery", Available: available.RecoveryStage, RequiresAuth: true, Parameters: []string{"recovery_point_id"}},
			{ID: "recovery-cancel", Operation: "recovery", Available: available.RecoveryCancel, RequiresAuth: true, Parameters: []string{}},
		},
	}
}

func operation(available bool) Operation {
	status := StatusUnavailable
	if available {
		status = StatusReady
	}
	return Operation{Status: status, Available: available}
}

func ValidStatus(status Status) bool {
	switch status {
	case StatusUnavailable, StatusReady, StatusLaunched, StatusSucceeded, StatusFailed, StatusRebootRequired:
		return true
	default:
		return false
	}
}
