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
mull silently records (keystrokes, clipboard, window titles, browser URLs, calendar)
    ↓
Every 60 seconds: me.md / now.md / full.md auto-generated (no LLM needed)
    ↓
Every night: mull Engine mulls over your day (LLM or rule-based fallback)
    ↓
AI reads your context via MCP Server, file reference, or copy/paste
    ↓
AI knows you. You explain nothing.
```

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
- Apple Silicon or Intel Mac
- Xcode 16+ (for building)
- [Ollama](https://ollama.com/) (optional, for local LLM summaries)

### Build

```bash
# Clone
git clone https://github.com/yourname/mull.git
cd mull

# Generate Xcode project
brew install xcodegen   # if not installed
xcodegen generate

# Open and build
open mull.xcodeproj
# Select "mull" scheme → ⌘R
```

### Permissions

mull needs two macOS permissions:

| Permission | What it does | How to grant |
|-----------|-------------|-------------|
| **Accessibility** | Read window titles | System Settings → Privacy & Security → Accessibility → Add mull |
| **Input Monitoring** | Record keystrokes | System Settings → Privacy & Security → Input Monitoring → Add mull |

> **Xcode development note:** When running from Xcode, add **Xcode** to Input Monitoring instead of mull (mull runs as Xcode's child process).

Clipboard monitoring requires no permission.

## Architecture

```
mull/
├── App/
│   ├── MullApp.swift              — Menu bar + Dock + Onboarding
│   └── AppState.swift              — Central state, timers, notifications
├── Services/
│   ├── RecordingService.swift      — CGEvent tap + clipboard + window titles + browser URLs
│   ├── DatabaseService.swift       — SQLite (GRDB) + FTS5 + DatabasePool
│   ├── MullEngine.swift           — 3-gate trigger + 4-phase LLM consolidation
│   ├── AnalyticsEngine.swift       — Keyword frequency, app usage, work rhythm
│   ├── FactExtractor.swift         — Rule-based identity/role/project inference
│   ├── LiveContextGenerator.swift  — Generates me.md/now.md/full.md every 60s
│   ├── CalendarService.swift       — EventKit calendar integration
│   ├── PermissionService.swift     — Accessibility + Input Monitoring monitoring
│   ├── KeychainService.swift       — Secure API key storage
│   └── MCPServer.swift             — MCP server for Claude Code / Cursor
├── Views/
│   ├── MenuBarPanel.swift          — Main panel (search, summary, actions)
│   ├── AIExportSheet.swift         — 3-layer AI context export (Profile/Standard/Full)
│   ├── FullWindowView.swift        — Live / Insights / Timeline dashboard
│   ├── OnboardingView.swift        — Permission setup with step-by-step guide
│   └── Components/                 — DesignTokens, ActionBar, SearchBar, etc.
└── MullMCP/
    └── main.swift                  — Standalone MCP server binary
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

```bash
# Build the MullMCP target in Xcode first, then:
claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
```

AI can then call `get_user_context`, `search_history`, and `get_patterns` tools automatically.

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
| Keystrokes | CGEvent tap (every key, 1s buffer) | What you typed — IME romaji included, AI judges |
| Clipboard | NSPasteboard polling (0.5s) | What you copied — always post-IME, high signal |
| Window titles | Accessibility API (3s polling) | What files/pages are open |
| Browser URLs | AppleScript (Safari, Chrome, Arc, Brave, Edge) | Full URL context |
| App switches | NSWorkspace notification | Time allocation per app |
| Calendar | EventKit | Today's schedule + upcoming meetings |

**Privacy:** All data stays on your Mac. No cloud. No telemetry by default. Database at `~/Library/Application Support/mull/mull.sqlite`.

## Analytics (Rule-Based, No LLM)

mull detects behavioral patterns without any LLM:

- **Top keywords** — what words appear most in your typing/clipboard
- **App usage** — time allocation across tools
- **Work rhythm** — peak hours, busiest day of week
- **Language mix** — Japanese / English / Code ratio
- **Fact extraction** — infers role, tech stack, projects from patterns

## Settings

Three tabs:

- **General** — mull schedule, output size limit, export destinations
- **AI** — LLM provider (Ollama / Claude API / OpenAI API) + connection test
- **Data** — Permission status, storage stats, retention policy, cleanup

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
| API Keys | macOS Keychain Services |
| LLM | Ollama (local) / Anthropic API / OpenAI API |
| AI Protocol | MCP (Model Context Protocol) via stdio |

## License

MIT

---

*Know what you did. Stop explaining yourself to AI.*
