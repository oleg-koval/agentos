package updatestate

const Schema = "agentos.update/v1"

type Status string

const (
	StatusNotChecked     Status = "not-checked"
	StatusChecking       Status = "checking"
	StatusUpToDate       Status = "up-to-date"
	StatusAvailable      Status = "available"
	StatusCheckFailed    Status = "check-failed"
	StatusApplyFailed    Status = "apply-failed"
	StatusSucceeded      Status = "succeeded"
	StatusRebootRequired Status = "reboot-required"
)

type Record struct {
	Schema          string `json:"schema"`
	Status          Status `json:"status"`
	Channel         string `json:"channel"`
	CurrentVersion  string `json:"current_version"`
	TargetVersion   string `json:"target_version,omitempty"`
	CheckedAt       string `json:"checked_at,omitempty"`
	LastSuccessAt   string `json:"last_success_at,omitempty"`
	LastFailure     string `json:"last_failure,omitempty"`
	SnapshotID      string `json:"snapshot_id,omitempty"`
	MigrationStatus string `json:"migration_status,omitempty"`
	RebootRequired  bool   `json:"reboot_required"`
	BootID          string `json:"boot_id,omitempty"`
	ArchPending     int    `json:"arch_pending"`
}

func ValidStatus(status Status) bool {
	switch status {
	case StatusNotChecked, StatusChecking, StatusUpToDate, StatusAvailable, StatusCheckFailed, StatusApplyFailed, StatusSucceeded, StatusRebootRequired:
		return true
	default:
		return false
	}
}
