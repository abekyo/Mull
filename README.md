# mull

**Your agent knows what you told it. mull knows what you did.**

mull is a local-first MCP server that gives coding agents **behavioral memory** — sourced
from your machine instead of your chat log. It records what you type, copy, and work on,
indexes it for retrieval, and exposes a small set of sharp, now-anchored search tools over
MCP. Everything stays on your Mac. No server, no account, no telemetry.

```bash
claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
```

---

## Why

Every AI memory system in 2026 remembers **what you said to it**:

| | Remembers | Never sees |
|---|---|---|
| ChatGPT memory | your ChatGPT messages | your machine |
| Claude memory | your Claude messages | your machine |
| Copilot Memory | your commits and PRs | the attempts before the commit |
| Gemini Personal Intelligence | Gmail, Photos — Google's surfaces | your editor |
| Mem0 / Zep / Letta | whatever the app hands the API | OS-level behavior |

None of them know that you spent the afternoon in `ViewController.swift`, that the error you
copied at 15:04 is still unresolved, or what you were looking at when you made a decision
last Tuesday. **That is the only thing mull knows, and it is the whole point.**

### Access is not the same as selection

Claude Code can already read your whole disk. But it explores from scratch every time —
slow, expensive, noisy. The useful thing is not access, it is **returning the smallest correct
slice for the question being asked right now**.

That selection layer is the product. Everything else is scaffolding.

---

## Does context actually help?

Not by default. [arXiv 2602.11988](https://arxiv.org/abs/2602.11988) (ETH Zurich, 2026) found
that *"providing context files does not generally improve task success rates, while increasing
inference cost by over 20% on average."*

**That result is about dumping context.** mull's claim is narrower and testable: *anchor to
current state, select a small ranked slice, and it does help.*

There is an evaluation harness for exactly this — [`eval/selection_eval.swift`](eval/selection_eval.swift),
20 labeled `(need → ideal slice)` cases measuring **precision / recall / MRR** over
`Selection.rank`. It is designed to compile without GRDB and run in seconds:

```bash
./eval/run.sh
```

If mull's ranking cannot beat naive full-context injection on this harness, the premise is
wrong and should be discarded. That is the intended use of the harness.

> **Status (2026-08-09):** the harness builds and runs again (it had rotted — see
> [ROADMAP.md](ROADMAP.md) §1-A — and CI now runs it on every push). **But it does not yet
> support the claim above.** All 20 cases score `precision = recall = MRR = 1.000`, and there
> is no baseline to compare against. A benchmark its own author passes perfectly, with nothing
> to lose to, measures nothing. Harder cases and the baselines (full-context, recency-only,
> entity-only) are the open release gate, §1-B.

---

## MCP tools

The server exposes **12 tools — read and write**. Start with `whats_active_now`, then condition
everything else on it.

| Tool | What it does |
|------|-------------|
| `whats_active_now` | **The anchor.** Active app / entity / session, plus recent high-salience actions |
| `search` | Ranked, now-anchored retrieval: `recency + entity match + BM25 + salience` |
| `get_user_context` | Three-layer context (`profile` / `standard` / `full`) |
| `get_relevant` | Facet-scoped selection for a topic |
| `get_projects` | Current entities and their state |
| `get_knowledge` | Extracted decisions and their reasoning |
| `search_history` | Raw event search |
| `calendar` | Planned (EventKit) beside actual (observed activity) |
| `list_files` / `read_file` | Browse and read the vault |
| `write_note` | Write a note into the vault |
| `curate` | Merge a block into an existing file — **your hand-edits are preserved** |

Writes go through the **Curator**, which merges at block level, so an agent can only touch its
own block. `me.pinned.md` is yours and is never overwritten.

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

Capture is deliberately wide. Fidelity is the one asset that cannot be recovered later —
you can always rebuild an index, you can never re-record yesterday.

| Signal | Method | Notes |
|--------|--------|-------|
| Keystrokes | CGEvent tap | Everything typed, IME romaji included, 3s flush |
| Clipboard | NSPasteboard polling (0.5s) | Post-IME, high signal, up to 40,000 chars |
| Window titles | Accessibility API (5s) | Which file / page / tab |
| Window body | Accessibility API (30s) | The work itself, not just its title |
| Browser URLs | AppleScript | Safari, Chrome, Arc, Brave, Edge |
| App switches | NSWorkspace | Time allocation |
| Calendar | EventKit | Today's schedule |
| Email | AppleScript, Mail.app (opt-in) | **Subject and sender only** — never the body |

**Deliberately not captured:** screen OCR / screenshots (Screenpipe's territory — heavy and
noisy), audio (Granola/Omi's territory, and it drags in third-party consent).

### Light indexing, not summarization

Each event gets retrieval handles at capture time. **Content is never replaced.**

| Field | Derived from | Used for |
|---|---|---|
| `entity` | window title head segment, git repo, clipboard paths | the strongest axis |
| `contentType` | note / error / decision / code / web / file | faceting |
| `salience` | 0–1 — a copied error scores high, a random keystroke fragment low | ranking, budget |
| `session` | gap < N minutes | "this chunk of work" |
| `mode` | produce / consume / decide / think / research / communicate | meaning |

> Summaries are lossy and get thrown away. Structure is a handle and gets kept.

---

## Corrections are the moat

```
mull selects and serves  →  you fix or delete it in the markdown
                                      ↓
                        "this was irrelevant" / "this is right"
                                      ↓
                          fed back into salience and weights
```

An agent using a slice is a weak positive label. **A human deleting a slice is the highest
quality relevance label there is, and it is free.**

Screenpipe, ManicTime and Timing all capture activity. None of them have this signal, because
none of them put the output in a file you can edit. mull's output is plain markdown with
provenance (`agent` / `human` / `pinned`), and the automatic layer is structurally forbidden
from overwriting your edits.

---

## The vault

Everything mull knows lives in `~/mull/` as plain markdown — readable by you, by mull, and by
any tool (git, Obsidian, iCloud, another AI):

```
~/mull/
├── me.md / now.md / full.md    — three-layer context (auto-generated)
├── me.pinned.md                — yours. mull never writes here
├── MEMORY.md                   — index of what mull has learned
├── 00_identity/  01_now/  02_work/  03_projects/
├── 04_career/    05_people/    06_knowledge/    09_inbox/
└── daily/                      — one file per day
```

| File | Size | Contains |
|------|------|---------|
| `me.md` | ~200 tokens | Identity — **observations only**, never inferences about you |
| `now.md` | ~500 tokens | Current entities, today's activity, schedule |
| `full.md` | ~1,500+ tokens | Everything, including raw input |

`me.md` is held to a strict rule: **it may only contain lines you can trace back to a specific
record.** Guessing someone's job from their app list is a claim, not an observation. Inferences
about role, tech stack, and domain were removed in 2026-07 for exactly this reason.

---

## Install

### Requirements

- macOS 14.0+ (Sonoma), Apple Silicon
- [Ollama](https://ollama.com/) — optional, only for local LLM summaries

### Download

**There is no published release yet — build from source below.** The release pipeline exists
and is scripted ([Cutting a release](#cutting-a-release)); nothing has been cut from it. When a
build does ship it will be a signed, notarized `Mull.dmg`, so it opens on a double-click with
no right-click dance and no `xattr -d` incantation.

On first launch mull walks you through the permissions it needs, shows you what it can already
see, and offers to connect itself to whichever of Claude Code, Claude Desktop and Cursor it
finds on the machine. `MullMCP` ships inside the app bundle, so there is no second thing to
install and no path to paste.

### Build from source

You do not need to build it to read it — but reading it and then running your own build is the
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

Requires Xcode 16+. `Local.xcconfig` is gitignored and genuinely optional — without it the
build signs ad-hoc, which works but makes macOS re-prompt for permissions after every rebuild.

There is deliberately no `swift build`: the app needs a resource bundle, an entitlements file
and an Info.plist, none of which SwiftPM handles for a macOS app — and a SwiftPM build of
`MullMCP` *alone* would be a trap, because capture lives in the app. The server would start,
answer every tool call, and have an empty database to answer them from.

### Cutting a release

```bash
./scripts/release.sh
```

Builds Release, signs with a Developer ID certificate, notarizes, staples, and runs the same
Gatekeeper assessment users' machines will run. It checks its prerequisites first and refuses
early rather than failing twenty minutes into a submission — notarization needs a **Developer
ID Application** certificate specifically, and an Apple Development certificate is rejected no
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

> **Running from Xcode:** add **Xcode** to Input Monitoring, not mull — mull runs as Xcode's
> child process.

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

There is no mull server. No account, no sync, no usage statistics — there isn't even a toggle
for telemetry, because there is nothing to toggle.

- **LLM is off by default.** Nothing leaves the machine until you pick a provider. Pick a cloud
  provider and mull talks to it directly with *your* API key — no intermediary. Ollama keeps
  everything on-device.
- Password fields are skipped automatically (`IsSecureEventInputEnabled`).
- 1Password, Keychain Access and similar are excluded by default. mull never records itself.
- Content classified as sensitive — API keys, card numbers, private keys, credentials — is
  filtered before it can reach a cloud provider.
- API keys live in the macOS Keychain, never in plaintext.
- Database at `~/Library/Application Support/mull/mull.sqlite`. You can delete a time range or
  everything.

### Why this is open source

Every keystroke-adjacent tool that earned trust did it by **not retaining content** —
TextExpander keeps at most 30 keystrokes in volatile memory, Espanso keeps 5 characters,
ActivityWatch counts keystrokes and states plainly that it is not a keylogger.

mull *does* retain content. The two products that made that same choice and shipped it closed —
Rewind and Microsoft Recall — were both rejected by their users.

So the source is the argument. **You should not trust a closed binary with an Input Monitoring
grant, including this one.** Read `Mull/Services/RecordingService.swift` and
`Mull/Core/SensitiveText.swift` and decide for yourself.

---

## Repository layout

```
Mull/
├── App/            MullApp.swift, AppState.swift
├── Core/           the parts an agent touches — no SwiftUI, fully testable
│   ├── MCPServer.swift          12 tools over JSON-RPC / stdio
│   ├── Selection.swift          ranked, now-anchored retrieval
│   ├── CurrentState.swift       the anchor — pure DB, no Accessibility dependency
│   ├── Curator.swift            block-level merge; protects hand-edits
│   ├── Entity.swift             cross-source entity resolution
│   ├── Signal.swift / Mode.swift  capture-time classification
│   ├── DatabaseService.swift    SQLite (GRDB) + FTS5 + DatabasePool
│   ├── MullDirectory.swift      the ~/mull vault: atomic reads/writes
│   ├── SensitiveText.swift      the privacy gate before anything leaves the device
│   └── …                        AnalyticsEngine, TimeBlockEngine, FactExtractor, EditDistance
├── Services/       RecordingService (CGEvent tap + clipboard + windows + URLs),
│                   LiveContextGenerator (regenerates me/now/full every 60s through the
│                   Curator), MullEngine (nightly consolidation), LLMClient, ReportWriter, …
└── Views/          SwiftUI app — see "The GUI" below

MullMCP/            standalone MCP server binary (also embedded at
                    Mull.app/Contents/Helpers/MullMCP, so a shipped build wires
                    itself up with no path to paste)
Tests/              36 XCTest files
eval/               selection_eval.swift + run.sh — the retrieval harness
scripts/            release.sh — build, sign, notarize, staple, verify
```

Design docs: [CLAUDE.md](CLAUDE.md) (spec) · [DIRECTION.md](DIRECTION.md) (how it is built and
why) · [SELECTION-LAYER.md](SELECTION-LAYER.md) (the core IP) ·
[MAP-ARCHITECTURE.md](MAP-ARCHITECTURE.md) (data model) · [ROADMAP.md](ROADMAP.md) (what is
gating the next release). They are written in Japanese — the code and this README are the
English surface.

### The GUI

There is a SwiftUI app — menu bar, a Home view, a calendar, a live event stream, a markdown
editor over the vault. It works, and it is how you inspect and correct what mull believes.

**It is not where the work is going.** New UI investment is frozen (CLAUDE.md §9). The product
is the MCP surface; the app is the inspector.

---

## Running without an LLM

mull's default configuration sends nothing anywhere. Selection, indexing, entity resolution,
time blocks and the three context files are all rule-based and need no model. An LLM only adds
nightly synthesis and a written daily summary — it is never required.

---

## License

[MIT](LICENSE).

mull watches everything you type. You should not have to take that on faith, so
every line of it is here to read, audit, fork, and build yourself — with no
strings attached.

---

*Local-first behavioral memory for agents. Capture everything, forever. Select correctly, right now.*
