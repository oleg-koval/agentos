#!/usr/bin/env bash
set -euo pipefail

systemctl reset-failed workstation-health-check.service
