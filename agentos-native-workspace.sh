#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then
  echo 'Run agentos-native-workspace as the graphical workstation user.' >&2
  exit 1
fi

qml6_bin="$(command -v qml6 || true)"
[[ -n "$qml6_bin" ]] || {
  echo 'qml6 is not installed; install the qt6-declarative package.' >&2
  exit 127
}

qml_file="${AGENTOS_NATIVE_WORKSPACE_QML:-/usr/share/agentos/native-shell/Main.qml}"
[[ -f "$qml_file" ]] || { echo "Native Workspace QML is missing: $qml_file" >&2; exit 1; }
exec "$qml6_bin" "$qml_file" -- "$@"
