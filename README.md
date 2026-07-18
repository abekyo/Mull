# mull

**It thinks about you, so you don't have to.**

mull is an always-on engine that quietly mulls over your computer activity — what you read, write, copy, and work on — and keeps a living understanding of who you are and what you're doing. You never mull over your own life to explain it to an AI again; mull already did the thinking, and hands the result to any AI assistant as structured context.

## Two things mull does

**1. It zeroes out the 2-minute self-explanation.**

Every time you ask AI for help, you start from zero:

> "I'm a Swift developer working on a health app called PantryApp. I'm doing a Storyboard refactor, currently on Phase 5. I also have a web project for a real estate company in Yokohama, and I have a meeting in 17 minutes..."

Two minutes, ten times a day, is ~10 hours a month spent explaining yourself to a machine. **mull eliminates it entirely.** AI just knows — instantly.

**2. It mulls over your life 24/7, so you don't have to.**

The deeper job isn't logging — it's *deliberation*. mull continuously reflects on your activity in the background: what you keep returning to, what you're stuck on, how your attention actually moves. You experience the result as instant ("AI just knows"), but the work behind it is slow, ongoing thinking that you've offloaded. Because mull understands you, it — and the AI reading it — can see what you'll likely need next.

> You stop mulling over your own life. mull does it for you, continuously.

## How It Works

```
You work normally
    ↓
mull silently records (keystrokes, clipboard, window titles + body, browser URLs, calendar)
    ↓
At capture: each event is classified (kind, salience, mode) and stored enriched
    ↓
Every 60 seconds: me.md / now.md / full.md regenerated (no LLM needed)
    ↓            └─ through the Curator, so your hand-edits survive
Every night: mull Engine mulls over your day (LLM, or rule-based fallback)
    ↓
AI reads your context via MCP Server, file reference, or copy/paste
    ↓
AI knows you. You explain nothing.
```

## The app

Four pinned views, plus your vault as an editable file tree:

- **Home** — your portrait: who mull thinks you are, what you're working on,
  today's activity, and unified search over everything
- **Calendar** — week / month / year. Planned (calendar events) beside actual
  (observed activity), auto-filled — you never type into it
- **Live** — the raw event stream as it happens, so you can see exactly what is
  being recorded
- **Chat** — ask about *your own records*. Grounded in me/now/projects; it will
  send you to Claude or ChatGPT for general questions

### Today, in your words

In the evening mull drafts your day as a report **in your writing voice**,
learned from what you've actually written. Edit it, and your edits become
tomorrow's voice sample. The draft is always yours to approve — mull writes,
you decide.

## What AI Sees

From a single day of recording, mull generates this:

```
About the user:
- Bilingual: Japanese (38%) and English (53%)
- Software developer (primary tools: Code, Xcode)
- Tech stack: UIKit/Storyboard, Vercel
- Most productive hours: 11:00, 12:00, 14:00

What the user is currently working on:

Today's schedule:
- 8:15 AM-1:15 PM アプリ事業：開発
- 3:00 PM-3:30 PM FX事業：CS ← in 17min

Today's files/pages:
- PantryApp — ViewController.swift (Xcode)
- lifedesign-silk.vercel.app/rental-management (Firefox)

App usage today:
- Code: 807 events
- Xcode: 284 events
- Firefox: 173 events

Clipboard today (68 unique entries):
- Storyboard全面改修に進んでください
- RegisterAccountTutorialVC（4 IBOutlet）
- Phase 5完了
- 栄養スコアバーの背景色が不一致
- 角丸が12〜20でバラバラ
...
```

With this data, AI can say:

> "Phase 5まで完了していますね。RegisterAccountTutorialVCが次の対象です。ただし15:00からFX事業のCSミーティングがあるので、残り17分で完了できるタスクから始めましょう。角丸の不統一はDesignTokensで解決するのはどうですか？"

**You said nothing. AI knew everything.**

## Installation

### Requirements

- macOS 14.0+ (Sonoma)
- Xcode 16+ (for building)
- [Ollama](https://ollama.com/) (optional, for local LLM summaries)

### Build

```bash
# Clone
git clone https://github.com/yourname/mull.git
cd mull

# Optional: keep macOS permission grants stable across rebuilds
cp Local.xcconfig.example Local.xcconfig
security find-identity -v -p codesigning   # paste a hash into Local.xcconfig

# Generate Xcode project
brew install xcodegen   # if not installed
xcodegen generate

# Open and build
open Mull.xcodeproj
# Select the "Mull" scheme → ⌘R
```

`Local.xcconfig` is gitignored and optional. Without it the build signs ad-hoc,
which works but makes macOS re-prompt for permissions after every rebuild.

### Permissions

| Permission | What it does | Required? |
|-----------|-------------|-----------|
| **Input Monitoring** | Record keystrokes | Yes, for typing capture |
| **Accessibility** | Read window titles and focused-window text | Yes, for window capture |
| **Calendar** | Read today's schedule (EventKit) | Optional |
| **Automation** | Read browser URLs, and Mail subjects if enabled | Optional, prompted on first use |

Grant these in System Settings → Privacy & Security. Clipboard monitoring
requires no permission.

> **Xcode development note:** When running from Xcode, add **Xcode** to Input
> Monitoring instead of mull (mull runs as Xcode's child process).

## Architecture

```
Mull/                               — the app target
├── App/
│   ├── MullApp.swift               — Menu bar + Dock + Onboarding
│   └── AppState.swift              — Central state, timers, notifications
├── Services/
│   ├── RecordingService.swift      — CGEvent tap + clipboard + window titles/body + browser URLs
│   ├── DatabaseService.swift       — SQLite (GRDB) + FTS5 + DatabasePool
│   ├── MullEngine.swift            — 3-gate trigger + 4-phase LLM consolidation
│   ├── LiveContextGenerator.swift  — Generates me.md / now.md / full.md every 60s
│   ├── Curator.swift               — Block-level merge; protects hand-edits from regeneration
│   ├── MullDirectory.swift         — The ~/mull vault: setup, atomic reads/writes
│   ├── FolderOntology.swift        — The 00_identity … 09_inbox folder scheme
│   ├── Selection.swift             — Ranked, facet-scoped retrieval (now-anchored)
│   ├── Signal.swift / Mode.swift   — Capture-time classification stored on each row
│   ├── TimeBlockEngine.swift       — Events → time blocks, "what you mainly did"
│   ├── AnalyticsEngine.swift       — Keyword frequency, app usage, work rhythm
│   ├── FactExtractor.swift         — Rule-based identity/role/project inference
│   ├── ReportWriter.swift          — "Today, in your words" — a draft in your voice
│   ├── CalendarService.swift       — EventKit calendar integration
│   ├── EmailService.swift          — Mail.app subjects + senders (opt-in)
│   ├── SensitiveText.swift         — The privacy gate before anything leaves the device
│   ├── PermissionService.swift     — Accessibility + Input Monitoring status
│   ├── KeychainService.swift       — Secure API key storage
│   ├── LLMClient.swift             — Gemini / Ollama / Claude / OpenAI
│   └── MCPServer.swift             — MCP server for Claude Code / Claude Desktop / Cursor
├── Views/
│   ├── FullWindowView.swift        — Sidebar shell: Home / Calendar / Live / Chat + file tree
│   ├── HomeTab.swift               — Portrait, projects, today's report, search
│   ├── CalendarView.swift          — Week / month / year, plan vs. actual
│   ├── ChatPanelView.swift         — Scoped chat grounded in your own records
│   ├── InsightsTab.swift           — "What mull knows" (lives in Settings → Profile)
│   ├── MenuBarPanel.swift          — Menu bar dropdown (search, today, actions)
│   ├── OnboardingView.swift        — Permission setup + cold read
│   ├── Settings/                   — General / AI / Data / Profile
│   └── Components/                 — DesignTokens, MarkdownTextEditor, MarkdownView
│
MullMCP/                            — standalone MCP server binary target
└── main.swift
Tests/                              — XCTest suite
project.yml                         — XcodeGen project definition
```

### The vault

Everything mull knows lives in `~/mull/` as plain markdown — readable by you, by
mull, and by any AI or tool (git, Obsidian, iCloud):

```
~/mull/
├── me.md / now.md / full.md    — the 3-layer context system (auto-generated)
├── me.pinned.md                — yours. mull never overwrites this file
├── MEMORY.md                   — index of what mull has learned
├── 00_identity/  01_now/  02_work/  03_projects/
├── 04_career/    05_people/    06_knowledge/    09_inbox/
└── daily/                      — one file per day
```

## 3-Layer Context System

mull generates three files with different token budgets:

| File | Size | Contains | Use when |
|------|------|---------|----------|
| `~/mull/me.md` | ~200 tokens | Identity, skills, preferences | Always safe to include |
| `~/mull/now.md` | ~500 tokens | Current projects, today's activity, calendar, patterns | Task is related to current work |
| `~/mull/full.md` | ~1,500+ tokens | Everything + raw keystrokes + clipboard | Onboarding AI to a new task |

## AI Integration

### Option 1: MCP Server (recommended)

Settings → AI can configure Claude Code, Claude Desktop, and Cursor for you. To
wire it up by hand, build the MullMCP target in Xcode first, then:

```bash
claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
```

The server exposes 12 tools — read *and* write:

| Tool | What it does |
|------|-------------|
| `get_user_context` | The 3-layer context (profile / standard / full) |
| `whats_active_now` | What you are doing right now |
| `search` | Ranked, now-anchored retrieval across your records |
| `search_history` | Raw event search |
| `get_relevant` | Facet-scoped selection for a given topic |
| `get_projects` | Current projects and their state |
| `get_knowledge` | Extracted decisions and their reasoning |
| `calendar` | Planned (events) vs. actual (observed activity) |
| `list_files` / `read_file` | Browse and read the vault |
| `write_note` | Write a new note into the vault |
| `curate` | Merge a block into an existing file — your edits are preserved |

Writes go through the Curator, which merges at block level so an agent can only
touch its own block. `me.pinned.md` is yours and is never overwritten.

### Option 2: CLAUDE.md reference

Add to any project's `CLAUDE.md`:

```markdown
Read ~/mull/me.md and ~/mull/now.md for context about who I am.
```

### Option 3: Copy & Paste

Click the moon icon (☽) in the menu bar → "Copy to AI" → paste into any AI chat.

## mull Engine

Nightly (default 23:00), mull consolidates the day's data:

### 3-Gate Trigger

1. **Time Gate** — 24 hours since last run
2. **Data Gate** — Enough new events recorded
3. **Lock Gate** — No other mull process running

### 4-Phase Processing

1. **Orient** — Read existing memories
2. **Gather** — Collect today's events by time period
3. **Consolidate** — LLM generates summary + memory updates
4. **Prune** — Keep MEMORY.md under 200 lines / 25KB

If no LLM is configured (no Ollama, no API key), mull falls back to **rule-based summaries** — window titles + clipboard + app usage, formatted as markdown. No configuration needed.

## Recording

mull captures:

| Signal | Method | Why |
|--------|--------|-----|
| Keystrokes | CGEvent tap (every key, 3s flush) | What you typed — IME romaji included, AI judges |
| Clipboard | NSPasteboard polling (0.5s) | What you copied — always post-IME, high signal |
| Window titles | Accessibility API (5s polling) | What files/pages are open |
| Window body | Accessibility API (30s polling) | The work itself, not just its title |
| Browser URLs | AppleScript (Safari, Chrome, Arc, Brave, Edge) | Full URL context |
| App switches | NSWorkspace notification | Time allocation per app |
| Calendar | EventKit | Today's schedule + upcoming meetings |
| Email | AppleScript, Mail.app (opt-in) | Subject + sender only — never the body |

### Privacy

All data stays on your Mac. There is no mull server, and no usage statistics are
collected or transmitted — there isn't even a toggle for it.

- **LLM is off by default.** Nothing is sent anywhere until you pick a provider.
  Choose a cloud provider and mull talks directly to it with *your* API key —
  no intermediary. Ollama keeps everything on-device.
- Password fields are skipped automatically (`IsSecureEventInputEnabled`).
- 1Password, Keychain Access, and similar apps are excluded by default, and mull
  never records its own events.
- Content classified as sensitive — API keys, card numbers, private keys,
  credentials — is filtered before it can reach a cloud provider.
- API keys are stored in the macOS Keychain, never in plaintext.
- Database at `~/Library/Application Support/mull/mull.sqlite`. Settings → Data
  can delete a time range or everything.

## Analytics (Rule-Based, No LLM)

mull detects behavioral patterns without any LLM:

- **Top keywords** — what words appear most in your typing/clipboard
- **App usage** — time allocation across tools
- **Work rhythm** — peak hours, busiest day of week
- **Language mix** — Japanese / English / Code ratio
- **Fact extraction** — infers role, tech stack, projects from patterns
- **Time blocks** — groups events into blocks and infers what you mainly did
- **Signal & mode** — classifies each moment by content kind, salience, and how
  it was engaged with (produce / consume / decide / think / research / communicate)

Everything above runs with no LLM configured. An LLM adds nightly synthesis and
the report in your voice — it is never required for mull to work.

## Settings

Four tabs:

- **General** — mull schedule, launch at login, output size limit, export destinations
- **AI** — LLM provider + connection test, and one-click MCP setup for Claude
  Code / Claude Desktop / Cursor
- **Data** — Permission status, data sources (email), storage stats, retention,
  cleanup, privacy statement
- **Profile** — What mull knows about you: portrait, fact tags, keywords,
  analysis grid. Correct anything that's wrong; corrections are authoritative

### LLM providers

| Provider | On-device? | Notes |
|----------|-----------|-------|
| **Off** | — | The default. Rule-based only, nothing leaves your Mac |
| Ollama | Yes | Local models |
| OpenAI-compatible (local) | Yes | Any local server speaking the OpenAI API |
| Gemini | No | Your API key, direct to Google |
| Claude | No | Your API key, direct to Anthropic |
| OpenAI | No | Your API key, direct to OpenAI |

## Origin

mull's memory pipeline — a 3-gate trigger, 4-phase consolidation, and plain-markdown memory files — follows the well-established pattern for how AI agents consolidate long-term memory: capture continuously, consolidate on a gated schedule, summarize, then prune. mull applies that pattern to **computer activity** instead of chat history.

How it differs from conversation-based AI memory (ChatGPT Memory, Mem0):
- mull captures **computer activity** (not conversation transcripts)
- mull generates **portable markdown files** (not internal database entries or an API)
- mull works **without any LLM** via rule-based analytics and fact extraction
- mull exposes data via **MCP Server** for any AI assistant to query

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Swift |
| UI | SwiftUI |
| Database | SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift) (WAL + FTS5 + DatabasePool) |
| Keystrokes | CGEvent tap (Quartz Event Services) |
| Calendar | EventKit |
| Browser | AppleScript |
| Email | AppleScript (Mail.app) |
| API Keys | macOS Keychain Services |
| LLM | Ollama (local) / Gemini / Anthropic API / OpenAI API |
| AI Protocol | MCP (Model Context Protocol) via stdio |
| Project generation | XcodeGen (`project.yml`) |

## License

MIT

---

*Know what you did. Stop explaining yourself to AI.*
