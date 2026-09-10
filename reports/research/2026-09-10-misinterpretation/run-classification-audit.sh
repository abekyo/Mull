#!/usr/bin/env bash
# Run from the repository root. Synthetic inputs only; no database or user data.
# These are diagnostic observations, not assertions that current behavior is correct.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$repo_root"
audit_dir="reports/research/2026-09-10-misinterpretation"
audit_tmp="$(mktemp -d "${TMPDIR:-/tmp}/mull-classification-audit.XXXXXX")"
trap 'rm -rf "$audit_tmp"' EXIT
swiftc -o "$audit_tmp/classification-audit" \
  Mull/Core/ProjectNames.swift \
  Mull/Core/TextScript.swift \
  Mull/Core/TestInput.swift \
  Mull/Core/SensitiveText.swift \
  Mull/Core/InstructionText.swift \
  Mull/Core/Redactor.swift \
  Mull/Core/Preferences.swift \
  Mull/Core/UserLanguage.swift \
  Mull/Core/VaultText.swift \
  Mull/Core/TimeFormatting.swift \
  Mull/Core/EditDistance.swift \
  Mull/Core/ContextBlock.swift \
  Mull/Core/CorrectionCard.swift \
  Mull/Core/CalendarEventHandle.swift \
  Mull/Core/BlockAttribution.swift \
  Mull/Core/BlockSegmentation.swift \
  Mull/Core/CalendarMirror.swift \
  "$audit_dir/classification-audit.swift"
"$audit_tmp/classification-audit"
