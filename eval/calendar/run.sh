#!/bin/bash
# Score the titles the calendar mirror would write, against days harvested from a real
# mull database.
#
#   ./eval/calendar/harvest.sh --on 2026-08-13
#   ./eval/calendar/run.sh
#
# Same constraint as eval/run.sh and eval/real/run.sh: everything compiled here has to
# stay GRDB-free and EventKit-free. That constraint is the whole reason
# Mull/Core/BlockSegmentation.swift and Mull/Core/CalendarEventHandle.swift exist as
# separate files — before the split, reaching the mirror's decisions meant importing a
# database and a calendar, and the text a person reads every day was the one output in
# mull that no harness could score.
#
# Reports only — no gate. CI has no database and never will. The gate for these rules
# is Tests/CalendarMirrorTests.swift, which is labelled by hand and runs everywhere.
set -euo pipefail

cd "$(dirname "$0")/../.."
BIN="${TMPDIR:-/tmp}/caleval"

swiftc -o "$BIN" \
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
  Mull/Core/BlockSegmentation.swift \
  Mull/Core/CalendarMirror.swift \
  eval/calendar/calendar_eval.swift

exec "$BIN" "$@"
