package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestStateMigration(t *testing.T) {
	tmp := t.TempDir()
	missing := filepath.Join(tmp, "missing.json")
	if got := stateMigration(missing, 1, "hash"); got != "initial" {
		t.Fatalf("missing state migration = %q, want initial", got)
	}

	path := filepath.Join(tmp, "state.json")
	cases := []struct {
		name string
		data string
		want string
	}{
		{name: "invalid", data: "{", want: "state-invalid"},
		{name: "schema", data: `{"schema":"old","version":1,"config_hash":"hash"}`, want: "state-schema-mismatch"},
		{name: "version", data: `{"schema":"agentos.config-state/v1","version":2,"config_hash":"hash"}`, want: "state-version-mismatch"},
		{name: "desired changed", data: `{"schema":"agentos.config-state/v1","version":1,"config_hash":"old"}`, want: "desired-config-changed"},
		{name: "converged", data: `{"schema":"agentos.config-state/v1","version":1,"config_hash":"hash"}`, want: "none"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(tc.data), 0600); err != nil {
				t.Fatal(err)
			}
			if got := stateMigration(path, 1, "hash"); got != tc.want {
				t.Fatalf("state migration = %q, want %q", got, tc.want)
			}
		})
	}
}

func validConfigForChannelTest(channel string) Config {
	return Config{
		Version: 1,
		Channel: channel,
		Backup:  BackupPolicy{Schedule: "quick"},
		Power:   PowerPolicy{Sleep: "disabled", Hibernate: "disabled"},
	}
}

func TestValidateConfigChannel(t *testing.T) {
	cases := []struct {
		name    string
		channel string
		wantErr string
	}{
		{name: "stable", channel: "stable", wantErr: ""},
		{name: "beta", channel: "beta", wantErr: ""},
		{name: "edge", channel: "edge", wantErr: ""},
		{name: "none", channel: "none", wantErr: ""},
		{name: "invalid", channel: "nightly", wantErr: "channel must be stable, beta, edge, or none"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateConfig(validConfigForChannelTest(tc.channel))
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("validateConfig(channel=%s) = %v, want nil", tc.channel, err)
				}
				return
			}
			if err == nil || err.Error() != tc.wantErr {
				t.Fatalf("validateConfig(channel=%s) = %v, want %q", tc.channel, err, tc.wantErr)
			}
		})
	}
}
