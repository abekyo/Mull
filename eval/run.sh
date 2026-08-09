#!/bin/bash
# Build and run the selection-layer eval harness (SELECTION-LAYER.md §6).
#
# The harness must keep compiling WITHOUT GRDB — that is what makes it run in
# seconds instead of needing the app and a host test bundle. So this list is a
# standing constraint, not a convenience: every file here, and everything they
# reach for, has to stay GRDB-free. It has silently rotted twice (SELECTION-LAYER §6.4),
# which is why CI runs this script on every push.
set -euo pipefail

cd "$(dirname "$0")/.."
BIN="${TMPDIR:-/tmp}/seleval"

swiftc -o "$BIN" \
  Mull/Core/ProjectNames.swift \
  Mull/Core/Entity.swift \
  Mull/Core/Signal.swift \
  Mull/Core/Mode.swift \
  Mull/Core/EditDistance.swift \
  Mull/Core/ContextBlock.swift \
  Mull/Core/CorrectionCard.swift \
  Mull/Core/CorrectionIndex.swift \
  Mull/Core/NearDuplicate.swift \
  Mull/Core/Selection.swift \
  Mull/Core/TextScript.swift \
  Mull/Core/Redactor.swift \
  Mull/Core/TestInput.swift \
  Mull/Core/SensitiveText.swift \
  Mull/Core/InstructionText.swift \
  eval/EvalCore.swift \
  eval/selection_eval.swift

exec "$BIN" "$@"
