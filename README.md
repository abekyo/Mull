# mull

mull records what you actually do on your Mac: what you type, what you copy, and what files
and pages you have open. Your coding agent can then look it up.

Without mull:

```
you     fix the login bug
agent   Which file? What framework? What have you tried already?
```

With mull:

```
you     fix the login bug
agent   (checks mull) You were in AuthService.swift an hour ago and copied a 401
        from the console at 15:04. Starting there.
```

It runs as an MCP server, so Claude Code, Cursor, or any other MCP client can query it.
Everything stays on your Mac. No account, no server, no telemetry.

```bash
claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
```

---

## What it is good for

| Situation | Without mull | With mull | Works today |
|---|---|---|---|
| It is Monday and you forget where Friday ended | You dig through `git log` and old tabs | The agent reads Friday's actual work | yes |
| You retype the same setup every session | "Swift", "GRDB", "macOS 14", again | The agent already has it | partly |
| The agent repeats a mistake you fixed last week | You fix it again, and again | Your fix became a rule the agent reads | yes |
| The project has scattered in your head | You work on whatever is nearest | You can pull up what you decided and why | partly |

`partly` on the second one is measured, not modest. A real copied block was about one tenth
useful: the rest was unrelated video titles, sentence fragments listed as projects, and entries
worth a minute. Three filters now cut that, and one labeled fixture holds them in place, which is
not the same as a scored corpus.

The first two are things ActivityWatch, Screenpipe and Mem0 also do. The third is specific to
mull and is described under [Corrections](#corrections). The fourth is only half a tool problem:
mull can show you past decisions, but it cannot tell you what to do next.

---

## Why not just let the agent read your disk?

It can. Claude Code already reads files. The problem is that it searches from scratch every
time, which is slow, expensive, and noisy.

What is missing is not access. It is a short, correct answer to "what matters right now". mull
builds its index while you work, so the answer is a few lines instead of a directory walk.

There is also material here that no other memory tool has. ChatGPT and Claude remember what you
said in the chat. Copilot remembers your commits. Mem0 and Zep remember what an app chose to
send them. None of them saw the error you copied at 15:04, or what was on screen when you made
a decision last Tuesday.

> Your agent knows what you told it. mull knows what you did.

---

## Does giving an agent context actually help?

Not automatically. [arXiv 2602.11988](https://arxiv.org/abs/2602.11988) (ETH Zurich, 2026) found
that *"providing context files does not generally improve task success rates, while increasing
inference cost by over 20% on average."*

That study measured dumping a pile of context in. mull makes a narrower claim: pick a few items
based on what the user is doing right now, and it does help. That claim is testable, so there is
a test for it. [`eval/selection_eval.swift`](eval/selection_eval.swift) holds 32 labeled cases
(a need, and the slice that should come back) and scores precision, recall and MRR against three
baselines: dump everything, most recent only, same project only.

```bash
./eval/run.sh
```

If mull cannot beat "dump everything" here, the premise is wrong and you should not use it.

### Run it on your own log

The 32 cases were written by the same person who wrote the ranker, which limits what they prove:
the distractors are ones that ranker already handles. So there is a second harness that pulls its
events from a real mull database instead:

```bash
./eval/real/harvest.sh --at "2026-08-08 15:10:00" --window 25 \
                       --name icons --anchor MyProject --query "which icon draft was it"
# ...label the gold ids by hand in eval/real/cases/icons.json — BEFORE running anything...
./eval/real/run.sh
```

Harvested cases are gitignored and never leave your machine. Only the tooling ships. Label the
correct answers before you look at what the ranker returned, or you will just agree with it.

### Results (2026-08-09)

Both harnesses run. CI runs the synthetic one on every push.

| | mull | dump everything | recent only | same project only |
|---|---|---|---|---|
| Synthetic, 32 cases | **F1 0.919** | 0.624 | 0.648 | 0.659 |
| Real log, 4 windows / 1,493 events | **F1 0.220** | 0.020 | 0.045 | 0.045 |

You can reproduce the first row: `./eval/run.sh`, same cases, same numbers. **You cannot
reproduce the second.** That corpus is raw keystrokes and clipboard from one machine, it is
gitignored, and it will never ship. Treat 0.220 as a report, not as evidence, and produce your
own with `eval/real/`.

The drop from 0.919 to 0.220 is the interesting part. It is what a real 25-minute window does to
a ranker tuned on invented ones. Four failures account for most of it, and they are now cases
29 to 32 in the synthetic set so CI can see them:

| failure | what happens |
|---|---|
| `duplicate-flood` | Window titles are polled every 5 seconds. Six of eight slots went to six identical copies of one title. Nothing deduplicates. |
| `query-echo` | The clipboard holds the question the user just pasted into an agent. It matches its own query perfectly and ranks first, so the agent gets its own question back as context. |
| `subsumption` | The same note drafted three times, each longer than the last. All three rank, and the complete one came third. |
| `entity-junk-profile` | `Entity.from` reads the trailing title segment, so a browser tab is filed under the browser profile instead of the project, and loses the anchor. |

None of these show up in an invented corpus. `query-echo` cannot: nobody writes their own query
into a test fixture.

What has been measured is that mull beats naive injection. Whether it beats Mem0, or plain
`grep`, has not been measured. Those baselines are not in the harness yet.

---

## MCP tools

The server exposes 13 tools, some read and some write. Start with `whats_active_now` and base
the rest on what it returns.

| Tool | What it does |
|------|-------------|
| `whats_active_now` | Active app, project, session, and recent notable actions. The anchor for everything else |
| `search` | Ranked, now-anchored retrieval: `recency + entity match + BM25 + salience` |
| `get_user_context` | Three-layer context (`profile` / `standard` / `full`) |
| `get_relevant` | Facet-scoped selection for a topic |
| `get_projects` | Current entities and their state |
| `get_knowledge` | Extracted decisions and their reasoning |
| `search_history` | Raw event search |
| `calendar` | Planned (EventKit) beside actual (observed activity) |
| `list_files` / `read_file` | Browse and read the vault |
| `write_note` | Write a note into the vault |
| `curate` | Merge a block into an existing file, leaving your own edits alone |
| `get_corrections` | Corrections you made that no rule has been drawn from yet. This is how `rules.md` fills up |

All writes go through the Curator, which merges one block at a time, so an agent can only touch
the block it owns.

`me.pinned.md` is a special case: it is yours, and no MCP tool writes to it at all, not
`write_note` and not `curate`. Anything in that file is handed to assistants as something *you*
said about yourself, so a line an agent slipped in would be that agent putting words in your
mouth. mull itself writes to it in two bounded ways: creating the initial template, and replacing
a marked-off section holding answers you saved in Settings. Neither touches a line you wrote.
[CLAUDE.md](CLAUDE.md) §7.4 has the exact promise.

Everything the server returns is labeled to the agent as a recording rather than an instruction.
A lot of what mull captures was written by other people: the clipboard holds whatever you copied,
the window channel holds whatever was on screen. So a page you merely had open can put a sentence
in front of your agent. Lines that look like instructions are marked as such. That is a road sign,
not a wall. See [SECURITY.md](SECURITY.md).

### The selection pipeline

```
1. anchor      — fill missing entity/since from whats_active_now()
2. recall      — hybrid candidate search (recency + entity + FTS + salience) → top-K
3. precision   — rank to the current need, compress to a token budget
                 (include / summarize / drop, per item)
4. assemble    — return with provenance: time, entity, source
5. log         — record what was used, and what a human later corrected
```

Step 5 is the part nobody else has. See [Corrections](#corrections-are-the-moat).

---

## What it captures

Capture is deliberately wide. You can rebuild an index whenever you like, but you cannot
re-record yesterday, so this is the one place where being thorough now actually matters.

| Signal | Method | Notes |
|--------|--------|-------|
| Keystrokes | CGEvent tap | Everything typed, IME romaji included, 3s flush |
| Clipboard | NSPasteboard polling (0.5s) | Post-IME, high signal, up to 40,000 chars |
| Window titles | Accessibility API (5s) | Which file / page / tab |
| Window body | Accessibility API (30s) | The work itself, not just its title |
| Browser URLs | AppleScript | Safari, Chrome, Arc, Brave, Edge |
| App switches | NSWorkspace | Time allocation |
| Calendar | EventKit | Today's schedule |
| Email | AppleScript, Mail.app (opt-in) | Subject and sender only, never the body |

Not captured, on purpose: screen OCR and screenshots (Screenpipe does that; it is heavy and
noisy), and audio (Granola and Omi do that, and recording other people raises a consent problem
mull does not want).

### Light indexing, not summarization

Each event gets a few retrieval handles when it is captured. The content itself is never
replaced by them.

| Field | Derived from | Used for |
|---|---|---|
| `entity` | window title head segment, git repo, clipboard paths | the strongest axis |
| `contentType` | note / error / decision / code / web / file | faceting |
| `salience` | 0 to 1. A copied error scores high, a stray keystroke low | ranking, budget |
| `session` | gap < N minutes | "this chunk of work" |
| `mode` | produce / consume / decide / think / research / communicate | meaning |

A summary throws away the original. A handle does not, so mull only adds handles.

---

## Corrections

mull writes markdown files. When you edit one, mull notices, and keeps a record of what it wrote,
what you kept, and what you were doing at the time. That record is used twice.

```
you edit a file mull wrote
        │
        ├── the ledger adjusts ranking weights, so search gets better
        │
        └── your agent calls get_corrections, works out why you made that edit,
            and writes a rule into ~/mull/rules.md
                    │
                    └── every later session reads rules.md
```

Here is why that matters. mull can watch you all day and learn that you use Xcode. It will never
learn "stop giving me option lists, give one recommendation." That kind of rule does not exist
anywhere in the recording. It appears only at the moment you correct something.

mull fills in the observable parts of the record: the diff, the timestamps, what was on screen.
It does not fill in why you made the edit. A guess there would read exactly like a real rule and
be wrong, and it would then be applied to every future session. Your agent does that part.

Screenpipe, ManicTime and Timing all capture activity too. None of them collect this signal,
because none of them put their output in a file you can edit. mull's output is plain markdown
tagged with who wrote each block (`agent`, `human`, `pinned`), and the automatic layer cannot
overwrite a block you touched. That applies to `rules.md` as well: a rule you rewrite is yours.

---

## The vault

Everything mull knows lives in `~/mull/` as plain markdown, readable by you, by mull, and by
any tool (git, Obsidian, iCloud, another AI):

```
~/mull/
├── me.md / now.md / full.md    — three-layer context (auto-generated)
├── rules.md                    — how you want an agent to work, from your corrections
├── me.pinned.md                — yours; edited at the foot of About Me (§7.4)
├── MEMORY.md                   — index of what mull has learned
├── projects/                   — one briefing per project (written by mull)
├── corrections/                — where you corrected mull, and what it should have said
├── inbox.md                    — quick capture from the menu bar
├── notes/                      — yours. Make whatever folders you want in here
└── daily/                      — one file per day
```

| File | Who reads it | What changes because of it |
|------|---|---|
| `rules.md` | your agent, every session | **it works the way you corrected it to** |
| `me.md` | your agent | you stop re-explaining your setup |
| `now.md` | your agent | it can pick up where you left off |
| `full.md` | your agent, on request | — *(see [CLAUDE.md](CLAUDE.md) §7: this one cannot answer the question, and is under review)* |

`me.md` is held to a strict rule: **it may only contain lines you can trace back to a specific
record.** Guessing someone's job from their app list is a claim, not an observation. Inferences
about role, tech stack, and domain were removed in 2026-07 for exactly this reason.

---

## Install

### Requirements

- macOS 14.0+ (Sonoma), Apple Silicon
- [Ollama](https://ollama.com/) — optional, only for local LLM summaries

### Download

There is no published release yet, so build from source below. The release pipeline exists
and is scripted ([Cutting a release](#cutting-a-release)); nothing has been cut from it. When a
build does ship it will be a signed, notarized `Mull.dmg`, so it opens on a double-click with
no right-click dance and no `xattr -d` incantation.

On first launch mull walks you through the permissions it needs, shows you what it can already
see, and offers to connect itself to whichever of Claude Code, Claude Desktop and Cursor it
finds on the machine. `MullMCP` ships inside the app bundle, so there is no second thing to
install and no path to paste.

### Build from source

You do not need to build it in order to read it. But reading it and then running your own build is the
whole argument for this being open source (see [Why this is open source](#why-this-is-open-source)).

```bash
git clone https://github.com/abekyo/Mull.git
cd Mull

# Optional: keep macOS permission grants stable across rebuilds
cp Local.xcconfig.example Local.xcconfig
security find-identity -v -p codesigning   # paste a hash into Local.xcconfig

brew install xcodegen   # if needed
xcodegen generate
open Mull.xcodeproj     # build the Mull scheme
```

Requires Xcode 16+. `Local.xcconfig` is gitignored and genuinely optional. Without it the
build signs ad-hoc, which works but makes macOS re-prompt for permissions after every rebuild.

There is deliberately no `swift build`: the app needs a resource bundle, an entitlements file
and an Info.plist, none of which SwiftPM handles for a macOS app. A SwiftPM build of
`MullMCP` *alone* would be a trap, because capture lives in the app. The server would start,
answer every tool call, and have an empty database to answer them from.

### Cutting a release

```bash
./scripts/release.sh
```

Builds Release, signs with a Developer ID certificate, notarizes, staples, and runs the same
Gatekeeper assessment users' machines will run. It checks its prerequisites first and refuses
early rather than failing twenty minutes into a submission. Notarization needs a Developer
ID Application certificate specifically, and an Apple Development certificate is rejected no
matter what else is configured. Set `MULL_DEVELOPER_ID_IDENTITY`, `MULL_TEAM_ID` and
`MULL_NOTARY_PROFILE` in `Local.xcconfig` (see `Local.xcconfig.example`).

> The name on that certificate appears in the Gatekeeper dialog on every user's machine.
> Whatever you enrol under is what ships.

### Permissions

| Permission | What it enables | Required? |
|-----------|-------------|-----------|
| **Input Monitoring** | Keystroke capture | Yes |
| **Accessibility** | Window titles and focused-window text | Yes |
| **Calendar** | Today's schedule | Optional |
| **Automation** | Browser URLs, Mail subjects | Optional, prompted on first use |

Installed from the .dmg, mull asks for these itself during onboarding and links straight to the
right System Settings pane. Clipboard monitoring needs no permission at all.

> **Running from Xcode:** add Xcode to Input Monitoring, not mull. mull runs as a child
> process of Xcode.

### Wiring it to an agent

```bash
# Claude Code
claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
```

Or reference the files directly from any project's `CLAUDE.md`:

```markdown
Read ~/mull/me.md and ~/mull/now.md for context about who I am.
```

---

## Privacy

There is no mull server. No account, no sync, no usage statistics. There is not even a telemetry
toggle, because there is nothing to toggle.

- LLM use is off by default. Nothing leaves the machine until you choose a provider. If you pick
  a cloud one, mull talks to it directly with your own API key, with nothing in between. Ollama
  keeps everything on-device.
- Password fields are skipped automatically (`IsSecureEventInputEnabled`).
- 1Password, Keychain Access and similar are excluded by default. mull never records itself.
- A copy your password manager marked `org.nspasteboard.ConcealedType` is dropped before its
  contents are read. That marker travels with the copy, so it still holds after you ⌘Tab away.
  An excluded-app list cannot do that, because it only knows what is frontmost right now.
- Content that looks sensitive (API keys, card numbers, private keys, credentials) is filtered
  out before it can reach a cloud provider.
- API keys live in the macOS Keychain, never in plaintext.
- The database is at `~/Library/Application Support/mull/mull.sqlite`, mode `0600`, inside a
  `0700` directory. You can delete a time range or everything, including the quarantined copies
  the crash-recovery path leaves behind.

### Why this is open source

Every tool that sits near your keystrokes and earned trust did it by not keeping the content.
TextExpander holds at most 30 keystrokes in volatile memory. Espanso holds 5 characters.
ActivityWatch counts keystrokes and says plainly that it is not a keylogger.

mull keeps the content. The two products that made the same choice and shipped it closed source,
Rewind and Microsoft Recall, were both rejected by their users.

So the source is the argument. You should not trust a closed binary with an Input Monitoring
grant, and that includes this one. Read `Mull/Services/RecordingService.swift` and
`Mull/Core/SensitiveText.swift` and decide for yourself.

---

## Repository layout

```
Mull/
├── App/            MullApp.swift, AppState.swift
├── Core/           the parts an agent touches — no SwiftUI, fully testable
│   ├── MCPServer.swift          13 tools over JSON-RPC / stdio
│   ├── Selection.swift          ranked, now-anchored retrieval
│   ├── CurrentState.swift       the anchor — pure DB, no Accessibility dependency
│   ├── Curator.swift            block-level merge; protects hand-edits, and
│   │                            records what was corrected before the merge hides it
│   ├── CorrectionCard.swift     one correction, 9 sections (1–3 filled, 4–8 not)
│   ├── CorrectionIndex.swift    correction verdicts → ranking weights (the ledger)
│   ├── RuleBook.swift           correction → rule → rules.md; the loop's last link
│   ├── Entity.swift             cross-source entity resolution
│   ├── Signal.swift / Mode.swift  capture-time classification
│   ├── DatabaseService.swift    SQLite (GRDB) + FTS5 + DatabasePool — connection
│   │                            ownership, migrations, recovery. The queries live
│   │                            in DatabaseService+Events / +Derived / +Predictions
│   │                            / +Lifecycle
│   ├── DatabaseAccess.swift     what each consumer may DO to the database:
│   │                            EventReading / EventWriting / DerivedReading.
│   │                            MCPDatabase is reads only — that is the boundary
│   │                            between the app and the MCP binary
│   ├── QuarantineRecovery.swift puts back databases the recovery path moved aside
│   ├── CaptureEnvironment.swift the seam under the recorder, so the privacy gates
│   │                            can be tested without a machine
│   ├── MullDirectory.swift      the ~/mull vault: atomic reads/writes
│   ├── SensitiveText.swift      the privacy gate before anything leaves the device
│   └── …                        AnalyticsEngine, TimeBlockEngine, FactExtractor, EditDistance
├── Services/       RecordingService (CGEvent tap + clipboard + windows + URLs;
│                   @MainActor, with SystemCaptureEnvironment holding every AppKit
│                   and Accessibility call),
│                   LiveContextGenerator (regenerates me/now/full every 60s through the
│                   Curator), MullEngine (nightly consolidation), LLMClient, ReportWriter, …
└── Views/          SwiftUI app — see "The GUI" below

MullMCP/            standalone MCP server binary (also embedded at
                    Mull.app/Contents/Helpers/MullMCP, so a shipped build wires
                    itself up with no path to paste)
Tests/              XCTest suite — run it, do not trust a count written in a document
eval/               selection_eval.swift + run.sh — the synthetic retrieval harness
eval/real/          harvest.sh + run.sh — the same ranker, scored on your own log
scripts/            release.sh — build, sign, notarize, staple, verify
```

Design docs: [CLAUDE.md](CLAUDE.md) (spec) · [DIRECTION.md](DIRECTION.md) (how it is built and
why) · [SELECTION-LAYER.md](SELECTION-LAYER.md) (the core IP) ·
[MAP-ARCHITECTURE.md](MAP-ARCHITECTURE.md) (data model). Those are written in Japanese, and they
hold the reasoning rather than the rules.

**The rules are in English, in [ARCHITECTURE.md](ARCHITECTURE.md):** the invariants a change must
not break, each with the test that enforces it, the layer boundaries, and which document decides
what. Read that before proposing a design change. You do not need Japanese to write the issue.

### The GUI

There is a SwiftUI app: menu bar, a Home view, a calendar, a live event stream, and a markdown
editor over the vault. It works, and it is how you inspect and correct what mull believes.

It is not where the work is going. New UI investment is frozen. The product is the MCP surface
and the app is the inspector. The visual design documents are kept out of this repository for
the same reason: there is nothing here for them to govern until that changes.

---

## Running without an LLM

mull's default configuration sends nothing anywhere. Selection, indexing, entity resolution,
time blocks and the three context files are all rule-based and need no model. An LLM only adds
nightly synthesis and a written daily summary. It is never required.

---

## License

[MIT](LICENSE).

mull watches everything you type. You should not have to take that on faith, so
every line of it is here to read, audit, fork, and build yourself, with no
strings attached.

---

*Local-first behavioral memory for agents. Capture everything, forever. Select correctly, right now.*
