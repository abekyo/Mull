#!/bin/sh
# Synthetic detector-only audit. Production aggregation/database are stubbed.
# Compiles the CURRENT BehaviorPatternEngine; never opens the user's database.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
audit_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mull-pattern-audit.XXXXXX")
trap 'rm -rf "$audit_tmp"' EXIT HUP INT TERM
cp "$script_dir/pattern-audit.swift" "$audit_tmp/main.swift"
swiftc "$repo_dir/Mull/Core/BehaviorPatternEngine.swift" "$audit_tmp/main.swift" -o "$audit_tmp/audit"
"$audit_tmp/audit"
