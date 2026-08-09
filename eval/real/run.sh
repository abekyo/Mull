#!/bin/bash
# Score Selection.rank against cases harvested from a real mull database.
#
# Same constraint as eval/run.sh: everything compiled here has to stay GRDB-free.
# The file list is kept identical on purpose — if the two lists drift, the two
# harnesses are no longer measuring the same code and their numbers stop being
# comparable, which is the failure this whole split exists to avoid.
#
#   ./eval/real/harvest.sh --at "2026-08-08 15:10:00" --name icons --anchor Mull \
#                          --query "アイコンの案どれだっけ"
#   # ...label gold in eval/real/cases/icons.json BY HAND, then:
#   ./eval/real/run.sh
#
# Reports only — no gate. CI has no database and never will.
set -euo pipefail

cd "$(dirname "$0")/../.."
BIN="${TMPDIR:-/tmp}/realeval"

swiftc -o "$BIN" \
  Mull/Core/ProjectNames.swift \
  Mull/Core/Entity.swift \
  Mull/Core/Signal.swift \
  Mull/Core/Mode.swift \
  Mull/Core/EditDistance.swift \
  Mull/Core/ContextBlock.swift \
  Mull/Core/CorrectionCard.swift \
  Mull/Core/CorrectionIndex.swift \
  Mull/Core/Selection.swift \
  Mull/Core/TextScript.swift \
  Mull/Core/Redactor.swift \
  Mull/Core/TestInput.swift \
  Mull/Core/SensitiveText.swift \
  Mull/Core/InstructionText.swift \
  eval/EvalCore.swift \
  eval/real/real_eval.swift

exec "$BIN" "$@"
