#!/usr/bin/env bash
# Export committed source only, without Git history or local QA output.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: export-source.sh COMMIT NEW_DIRECTORY' >&2; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
commit="$(git -C "$repo_root" rev-parse --verify "$1^{commit}")"
[[ ! -e "$2" && ! -L "$2" ]] || { echo 'Export destination must not exist.' >&2; exit 2; }
mkdir -p "$2"
git -C "$repo_root" archive --format=tar "$commit" | tar -xf - -C "$2"
printf '%s\n' "$commit" > "$2/release/source-commit"
printf 'Exported committed source %s\n' "$commit"
