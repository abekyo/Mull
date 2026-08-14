# mull

mull records what you actually do on your Mac: the files and pages you have open, the text on
screen in them, and what you copy. Your coding agent can then look it up. It can read your
keyboard too, but only if you switch that on.

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
| Synthetic, 32 cases | **F1 0.964** | 0.624 | 0.648 | 0.659 |
| Real log, 4 windows / 1,493 events | **F1 0.220** | 0.020 | 0.045 | 0.045 |

You can reproduce the first row: `./eval/run.sh`, same cases, same numbers. **You cannot
reproduce the second.** That corpus is raw keystrokes and clipboard from one machine, it is
gitignored, and it will never ship. Treat 0.220 as a report, not as evidence, and produce your
own with `eval/real/`.

The drop from the synthetic score to 0.220 is the interesting part. The real-log number
predates the deduplication added on 2026-08-09 and has not been measured since. It is what a real 25-minute window does to
a ranker tuned on invented ones. Four failures account for most of it, and they are now cases
29 to 32 in the synthetic set so CI can see them:

| failure | what happens |
|---|---|
| `duplicate-flood` | Window titles are polled every 5 seconds. Six of eight slots went to six identical copies of one title. Repeats now collapse before the cut, so the flood is gone; the case still fails because the other two answers do not contain the query's words and the lexical gate drops them. |
| `query-echo` | The clipboard holds the question the user just pasted into an agent. It matches its own query perfectly and ranks first, so the agent gets its own question back as context. |
| `subsumption` | The same note drafted three times, each longer than the last. All three ranked, and the complete one came third. Fixed on 2026-08-09: a draft contained whole inside a later one is the same draft. |
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
| Keystrokes | CGEvent tap | **Off by default.** On, everything typed, IME romaji included, 3s flush |
| Clipboard | NSPasteboard polling (0.5s) | Post-IME, high signal, up to 40,000 chars |
| Window titles | Accessibility API (5s) | Which file / page / tab |
| Window body | Accessibility API (30s, 5min while untouched) | The work itself, not just its title |
| Browser URLs | AppleScript (30s, 5min while untouched) | Safari, Chrome, Arc, Brave, Edge |
| App switches | NSWorkspace | Time allocation |
| Calendar | EventKit | Today's schedule |
| Email | AppleScript, Mail.app (opt-in) | Headers only on this channel: subject, sender, date |

"While untouched" means two minutes with no key, click or scroll anywhere on the machine.
Those two rows then sample every five minutes instead of every thirty seconds; they do not
stop, and no other row changes. Both are cheap for mull and expensive for whoever is in
front — one walks up to 1,500 Accessibility nodes in that app, the other wakes the browser's
main thread with an Apple Event — and against a screen nobody is touching, both re-read what
they have already recorded. Window titles keep their 5s: someone's agent working while they
are away from the keyboard is a normal afternoon here, and the record should be able to say
what it did.

The rows are not independent of each other. "Headers only" is true of the Mail channel and
false of the product: Mail.app is not on the excluded-apps list, so while you are reading a
message the "Window body" row picks up the text on screen. [SECURITY.md](SECURITY.md) has the
exact promise and how to turn that off; it is the source of truth for this one.

Not captured, on purpose: screen OCR and screenshots (Screenpipe does that; it is heavy and
noisy), and audio (Granola and Omi do that, and recording other people raises a consent problem
mull does not want).

### Light indexing, not summarization

Each event gets a few retrieval handles when it is captured. The content itself is never
replaced by them.

| Field | Derived from | Used for |
|---|---|---|
| `entity` | a window title segment. Editors put the project last, so `candidates.last ?? candidates.first` | the strongest axis |
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

`daily/` does not yet hold what that line promises. `MullEngine.writeDailyFile` is a no-op, and
what is actually written there is a copy of `full.md`, refreshed every 60 seconds. The day's
written record exists — it is generated, it is accurate, and it is in the database — but it has
no file. See [DIRECTION.md](DIRECTION.md) §6.2.

| File | Who reads it | What changes because of it |
|------|---|---|
| `rules.md` | your agent, every session | **it works the way you corrected it to** |
| `me.md` | your agent | you stop re-explaining your setup |
| `now.md` | your agent | it can pick up where you left off |
| `full.md` | your agent, on request | — *(see [CLAUDE.md](CLAUDE.md) §7: this one cannot answer the question, and is under review)* |

`me.md` is held to a strict rule: **it may only contain lines you can trace back to a specific
record.** Guessing someone's job from their app list is a claim, not an observation. The code
that inferred role, tech stack and domain was removed in 2026-07 for exactly this reason.

The rule binds what mull writes. It did not reach back for what was already written: on
2026-08-14 the author's own `me.md` still carried `- Software developer` under the block id
`mem:user-role`, and had been handing it to every agent since. It came from a `memory_entries`
row stamped 2026-06-02 05:15:42, 73 seconds before five daily summaries with 5-byte bodies and
event counts of 10, 20, 30, 40 — seeded demo data, not an inference about anybody. The row was
deleted on 2026-08-15 and the block went with it on the next pass (`mem:` is a Curator-managed
prefix). It is recorded here rather than fixed quietly because a promise a reader can falsify by
opening one file costs more than the line it was protecting (§7.4).

What remains open is narrower and worth stating: this rule is enforced in the rule-based
extractor, and nothing enforces it on the path the nightly model writes. A model that decides to
record what you *are* rather than what you did would land in the same place, and mull would serve
it.

---

## Install

### Requirements

- macOS 14.0+ (Sonoma), Apple Silicon
- [Ollama](https://ollama.com/), or any OpenAI-compatible local server (LM Studio, Jan, llama.cpp,
  vLLM) — optional. Needed only to run the LLM features on-device: nightly summaries, Chat, and
  per-project deliberation. The MCP tools never call an LLM, so they work without either.

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
| **Accessibility** | Window titles and focused-window text | Yes |
| **Input Monitoring** | Keystroke capture | No — off by default |
| **Calendar** | Today's schedule | Optional |
| **Automation** | Browser URLs, Mail subjects | Optional, prompted on first use |

Installed from the .dmg, mull asks for Accessibility during onboarding and links straight to
the right System Settings pane. Clipboard monitoring needs no permission at all.

Input Monitoring is not part of setting mull up. Keystroke capture is off until you turn it on
under Settings → Data → Optional sources, and macOS asks you at that point rather than during
onboarding. Measured over 75 days it was 3.0% of the text mull captured against 80.6% for the
Accessibility-driven window reader, and four fifths of it was editor text already visible
through that reader — so it is not the permission the product stands on, and it no longer
behaves like one.

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

- LLM use is off by default. Nothing leaves the machine until you choose a provider. Point it at
  Ollama or an OpenAI-compatible local server and nothing leaves it even then: mull runs with the
  network off, summaries and Chat included. If you pick a cloud provider instead, mull talks to it
  directly with your own API key, with nothing in between. The full list of boundaries, and where
  in the source to check each one, is in [SECURITY.md](SECURITY.md).
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

Tools that sit near your keystrokes have earned trust two different ways, and only one of them is
"keep nothing". TextExpander holds 30 keystrokes in volatile memory, 300 with Snippet Suggestions
turned on, and what it holds is a hash rather than the characters you typed. Espanso holds the
last 3 characters by default. ActivityWatch does not record which keys you pressed, and says so
plainly — though it does keep window titles and browser URLs, which is content by the definition
this project uses for itself.

The other way is Maccy. It keeps every string you copy, on your machine, forever, and it is the
43rd most-installed cask on Homebrew out of 22,030 over the last year. It is MIT-licensed, so you
can read what it does with your clipboard. Keeping the content did not cost it anything; being
unreadable would have.

mull keeps the content. Of the two products that kept it and shipped closed, Microsoft Recall was
walked back to explicit opt-in after security researchers took it apart, and Rewind was folded
into Meta and had screen capture switched off for good in December 2025. Neither of them ever let
you check a claim it made about itself.

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
eval/calendar/      harvest.sh + run.sh — the titles the calendar mirror would write,
                    scored on your own log
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
editor over the vault.

On 2026-08-14 that last one was ruled out. The GUI keeps the two things a person opens every
day — the calendar that puts your schedule beside what you actually did, and the markdown file
holding that day's record — and gives up being a place to edit the vault. Your vault is plain
markdown in a folder; Finder, Obsidian and VS Code are already better at editing it than mull
will ever be. The files do not change, only the editor over them goes.

The tab went on 2026-08-15, behind the two repairs it was sequenced after, so the deletion was
not made while the thing it replaces was broken. `FullWindowView` is 979 lines rather than 2,823;
`MarkdownTextEditor`, the 1,408-line editor built for it, had no call sites left and went too.
An **About you** page survived the first cut — `me.md` with `me.pinned.md` editable at its foot —
on the reasoning that correcting mull's reading of you only makes sense beside the reading. It
lasted a few hours. Settings › General › "Your answers" already owned that file, so the page's
one irreplaceable job had a home, and what was left was a file written for an agent, shown to the
person it is about, on a screen in an app about your day.

The sidebar is Home, Calendar, Live, Chat. [DIRECTION.md](DIRECTION.md) §6.2 has the reasoning
and what would reverse it.

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
