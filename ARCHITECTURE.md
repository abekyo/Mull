# Architecture

**What you may not break, where the boundaries are, and where each decision is written down.**
This is the file to read before proposing a design change.

The reasoning behind these decisions is in Japanese, in the documents listed under
[Where decisions live](#where-decisions-live). This file does not translate them. It states the
contract they produced, so that you can propose a change without reading Japanese, and it points
at the right document when you need the argument rather than the rule.

Every line below is one of two things: **an invariant with a named enforcer**, or **a pointer**.
There is deliberately no explanatory prose here, because a paragraph that exists in two languages
drifts and nobody diffs across languages. See [PITFALLS.md](PITFALLS.md) §7 for what that costs
in this codebase.

---

## The shape

```
  capture ──▶ light index ──▶ selection ──▶ MCP ──▶ your agent
  (widest)    entity/type/     (rank to      13 tools
              salience/        the current   5 resources
              session/mode     need)              │
                                                  │
       ~/mull/*.md ◀── curation ◀── the agent writes back
            │          (Curator, block-level, provenance-tagged)
            │
            └── you edit a block ──▶ Correction Card ──▶ rules.md ──▶ next session
```

Two directions matter. Left to right is retrieval and is what most tools do. Bottom is the
correction loop and is the part that is specific to mull: see
[Corrections](README.md#corrections) in the README for what it is and
[HARNESS.md](HARNESS.md) for how it is built.

---

## Invariants

A change that breaks one of these is not a refactor. If you believe one should change, open an
issue naming the invariant rather than sending a diff.

| # | Invariant | Held by |
|---|---|---|
| 1 | Curator never rewrites a block a human edited. An edited `agent` block is promoted to `human` and left alone from then on. | `CuratorTests.testGenuineHumanEditIsStillProtected`, `testSweepNeverTouchesHumanOrPinnedBlocks`, `testRetractKeepsPinnedAndHumanBlocks` |
| 2 | No MCP tool writes `me.pinned.md`, by any spelling of the path, through any tool. | `MCPServerTests.testWriteNoteRefusesTheUsersOwnFileForItsOwnReason`, `testCurateAlsoRefusesTheUsersOwnFile`, `testCurateRefusesTheUsersOwnFileByAnySpelling` |
| 3 | Content classified as sensitive never reaches an agent, however well it scores. | `SelectionTests.testSensitiveTextIsNeverReturnedNoMatterHowWellItScores`, `testSensitiveTextIsSuppressedEvenUnderAMatchingFacet`, `MCPServerTests.testSearchHistoryNeverLeaksSensitiveText` |
| 4 | The MCP server holds a read-only database handle. It cannot write, migrate, or create the database. | `DatabaseBoundaryTests.testReadOnlyHandleCannotWrite`, `testReadOnlyDoesNotMigrate`, `testMCPServerRunsOnAReadOnlyHandle` |
| 5 | The capture surface is append-only. | `DatabaseBoundaryTests.testCaptureSurfaceIsAppendOnly` |
| 6 | Capture stops for secure input fields, concealed clipboard copies, private browsing windows, excluded apps, mull's own output, and while paused. | [`RecordingServiceTests`](Tests/RecordingServiceTests.swift), one test per case |
| 7 | Text an agent sees carries no emoji and no decorative glyphs. | `ShippedVocabularyTests.testNoShippedStringLiteralCarriesAnEmoji` |
| 8 | Captured text is handed to the agent as quoted data, never as instruction. | [`PromptSafetyTests`](Tests/PromptSafetyTests.swift), `MCPServerTests.testServerInstructionsSayCapturedTextIsDataNotInstructions` |
| 9 | Who owns a vault file is decided in one place (`VaultOwnership`), and the Files tab and the MCP server both ask it. | [`VaultOwnershipTests`](Tests/VaultOwnershipTests.swift), in particular `testProvenanceAgreesAboutWhichDirectoriesAreCurated` |
| 10 | A Correction Card ships sections 4, 5 and 8 blank. mull records observation; interpretation is the agent's and the user's. | `CorrectionLoopTests.testRenderedCardLeavesInterpretationBlank` |
| 11 | `rules.md` is `.shared`, not mull-owned: the user may type into it, an agent may only `curate`, and a rewritten rule is `human` forever. | `RuleBookTests.testRulesFileIsSharedNotMullOwned` |
| 12 | `eval/` compiles without GRDB and runs in seconds. | CI ([`.github/workflows/eval.yml`](.github/workflows/eval.yml)) |
| 13 | `Selection.rank` beats dump-everything, recency-only and entity-only on the labeled set, or the harness exits `GATE: fail`. | `./eval/run.sh` |
| 14 | The pasted context block carries the user's own material and not unrelated consumption. | [`ContextComposerTests`](Tests/ContextComposerTests.swift), one labeled fixture |
| 15 | The territory (`_raw`, the event table) is never replaced by a summary. Map nodes point into it. | prose. Not enforced. |
| 16 | `Mull/Core` contains no SwiftUI and no AppKit. | prose, recorded as unenforced in `project.yml`. Not enforced by the compiler. |

Rows 15 and 16 say "prose" on purpose. An invariant enforced by a test is a fact; an invariant
enforced by a document is a hope. Converting one of those two into a test is a welcome change.

---

## Layer boundaries

| Layer | Owns | Location | May not |
|---|---|---|---|
| Capture | Getting signal off the machine losslessly | `Mull/Services/RecordingService.swift`, `RawStore.swift` | Interpret, summarize, or drop content it merely finds uninteresting |
| Index | Cheap handles computed at capture time: `entity`, `contentType`, `salience`, `session`, `mode` | `Mull/Core/Signal.swift`, `Entity.swift`, `Mode.swift` | Replace the original text |
| Selection | Ranking a need against candidates | `Mull/Core/Selection.swift` | Read the vault, import GRDB indirectly, or return sensitive text |
| Curation | Merging writes into markdown without destroying human edits | `Mull/Core/Curator.swift`, `ContextBlock.swift` | Write `me.pinned.md` content, or resurrect a deleted block |
| Correction | Recording what was corrected and turning it into rules | `Mull/Core/CorrectionCard.swift`, `CorrectionIndex.swift`, `RuleBook.swift` | Fill in why the user made an edit |
| Serving | The MCP surface: 13 tools, 5 resources | `Mull/Core/MCPServer.swift`, `MullMCP/` | Write to the database |
| UI | Inspecting and correcting what mull believes | `Mull/Views/` | Be required for any of the above to work |

The app and `MullMCP` are **separate processes on one SQLite file**. Anything that writes needs a
cross-process lock, not an in-process one. [PITFALLS.md](PITFALLS.md) §3 has the two incidents
that established this.

---

## Where decisions live

These documents are in Japanese. Each row says what it decides, so you can tell whether you need
it before asking for a translation.

| To change... | The decision is in | Language |
|---|---|---|
| Whether a feature should exist at all | [CLAUDE.md](CLAUDE.md) §0 (the four situations mull is for, and which of them work today) | 日本語 |
| What is captured, and from where | [CLAUDE.md](CLAUDE.md) §6 | 日本語 |
| What mull may output, and what each file is for | [CLAUDE.md](CLAUDE.md) §7 (the output contract: who reads it, what changes) | 日本語 |
| The `me.pinned.md` promise, exactly | [CLAUDE.md](CLAUDE.md) §7.4 (this section is canonical; other files point at it) | 日本語 |
| Ranking weights, the eval, the baselines | [SELECTION-LAYER.md](SELECTION-LAYER.md) §4 and §6 | 日本語 |
| The correction loop and the Correction Card schema | [HARNESS.md](HARNESS.md) 第II部 | 日本語 |
| The data model: territory, map, mode, the five laws | [MAP-ARCHITECTURE.md](MAP-ARCHITECTURE.md) | 日本語 |
| Why the architecture is shaped this way at all | [DIRECTION.md](DIRECTION.md) | 日本語 |
| Recurring defects and the invariant each one left | [PITFALLS.md](PITFALLS.md) | English |
| The threat model and the privacy boundary | [SECURITY.md](SECURITY.md) | English |

When one of those disagrees with this file, **the Japanese document is right and this file is
stale.** Say so in an issue; it is a defect either way.

---

## Proposing a change

1. Name the invariant or the boundary you want to move, using the numbers above.
2. Say which situation in [CLAUDE.md](CLAUDE.md) §0 it serves. A change that serves none of the
   four is out of scope by construction, and saying so is not a judgment about the idea.
3. If it touches ranking, run `./eval/run.sh` and put both numbers in the issue. A ranking change
   without a before and after cannot be reviewed.
4. Open the issue in English. Answers come in English.

You do not need Japanese for steps 1 through 4. If a decision you want to argue with is only
readable in Japanese, ask in the issue and it will be translated there, which puts the translation
next to the argument instead of in a second copy of the document.
