# Dream

**Your life, AI-ready.**

Dream silently records your computer activity and makes it available as structured context for AI assistants. You never explain yourself again — AI already knows who you are, what you're working on, and what you did today.

## The Problem

Every time you ask AI for help, you start from zero:

> "I'm a Swift developer working on a health app called PantryApp. I'm doing a Storyboard refactor, currently on Phase 5. I also have a web project for a real estate company in Yokohama, and I have a meeting in 17 minutes..."

**Dream eliminates this entirely.** AI just knows.

## How It Works

```
You work normally
    ↓
Dream silently records (keystrokes, clipboard, window titles, browser URLs, calendar)
    ↓
Every 60 seconds: me.md / now.md / full.md auto-generated (no LLM needed)
    ↓
Every night: Dream Engine summarizes your day (LLM or rule-based fallback)
    ↓
AI reads your context via MCP Server, file reference, or copy/paste
    ↓
AI knows you. You explain nothing.
```

## What AI Sees

From a single day of recording, Dream generates this:

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
git clone https://github.com/yourname/dream.git
cd dream

# Generate Xcode project
brew install xcodegen   # if not installed
xcodegen generate

# Open and build
open Dream.xcodeproj
# Select "Dream" scheme → ⌘R
```

### Permissions

Dream needs two macOS permissions:

| Permission | What it does | How to grant |
|-----------|-------------|-------------|
| **Accessibility** | Read window titles | System Settings → Privacy & Security → Accessibility → Add Dream |
| **Input Monitoring** | Record keystrokes | System Settings → Privacy & Security → Input Monitoring → Add Dream |

> **Xcode development note:** When running from Xcode, add **Xcode** to Input Monitoring instead of Dream (Dream runs as Xcode's child process).

Clipboard monitoring requires no permission.

## Architecture

```
Dream/
├── App/
│   ├── DreamApp.swift              — Menu bar + Dock + Onboarding
│   └── AppState.swift              — Central state, timers, notifications
├── Services/
│   ├── RecordingService.swift      — CGEvent tap + clipboard + window titles + browser URLs
│   ├── DatabaseService.swift       — SQLite (GRDB) + FTS5 + DatabasePool
│   ├── DreamEngine.swift           — 3-gate trigger + 4-phase LLM consolidation
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
└── DreamMCP/
    └── main.swift                  — Standalone MCP server binary
```

## 3-Layer Context System

Dream generates three files with different token budgets:

| File | Size | Contains | Use when |
|------|------|---------|----------|
| `~/Dream/me.md` | ~200 tokens | Identity, skills, preferences | Always safe to include |
| `~/Dream/now.md` | ~500 tokens | Current projects, today's activity, calendar, patterns | Task is related to current work |
| `~/Dream/full.md` | ~1,500+ tokens | Everything + raw keystrokes + clipboard | Onboarding AI to a new task |

## AI Integration

### Option 1: MCP Server (recommended)

```bash
# Build the DreamMCP target in Xcode first, then:
claude mcp add --transport stdio --scope user dream -- /path/to/DreamMCP
```

AI can then call `get_user_context`, `search_history`, and `get_patterns` tools automatically.

### Option 2: CLAUDE.md reference

Add to any project's `CLAUDE.md`:

```markdown
Read ~/Dream/me.md and ~/Dream/now.md for context about who I am.
```

### Option 3: Copy & Paste

Click the moon icon (☽) in the menu bar → "Copy to AI" → paste into any AI chat.

## Dream Engine

Nightly (default 23:00), Dream consolidates the day's data:

### 3-Gate Trigger

1. **Time Gate** — 24 hours since last Dream
2. **Data Gate** — Enough new events recorded
3. **Lock Gate** — No other Dream process running

### 4-Phase Processing

1. **Orient** — Read existing memories
2. **Gather** — Collect today's events by time period
3. **Consolidate** — LLM generates summary + memory updates
4. **Prune** — Keep MEMORY.md under 200 lines / 25KB

If no LLM is configured (no Ollama, no API key), Dream falls back to **rule-based summaries** — window titles + clipboard + app usage, formatted as markdown. No configuration needed.

## Recording

Dream captures:

| Signal | Method | Why |
|--------|--------|-----|
| Keystrokes | CGEvent tap (every key, 1s buffer) | What you typed — IME romaji included, AI judges |
| Clipboard | NSPasteboard polling (0.5s) | What you copied — always post-IME, high signal |
| Window titles | Accessibility API (3s polling) | What files/pages are open |
| Browser URLs | AppleScript (Safari, Chrome, Arc, Brave, Edge) | Full URL context |
| App switches | NSWorkspace notification | Time allocation per app |
| Calendar | EventKit | Today's schedule + upcoming meetings |

**Privacy:** All data stays on your Mac. No cloud. No telemetry by default. Database at `~/Library/Application Support/Dream/dream.sqlite`.

## Analytics (Rule-Based, No LLM)

Dream detects behavioral patterns without any LLM:

- **Top keywords** — what words appear most in your typing/clipboard
- **App usage** — time allocation across tools
- **Work rhythm** — peak hours, busiest day of week
- **Language mix** — Japanese / English / Code ratio
- **Fact extraction** — infers role, tech stack, projects from patterns

## Settings

Three tabs:

- **General** — Dream schedule, output size limit, export destinations
- **AI** — LLM provider (Ollama / Claude API / OpenAI API) + connection test
- **Data** — Permission status, storage stats, retention policy, cleanup

## Origin

Dream's architecture is inspired by Claude Code's `autoDream` system (the memory consolidation engine leaked via npm sourcemap on March 31, 2026). The 3-gate trigger, 4-phase consolidation, and memory file format are adapted from that design.

Key differences:
- Dream captures **computer activity** (not conversation transcripts)
- Dream generates **portable markdown files** (not internal database entries)
- Dream works **without any LLM** via rule-based analytics and fact extraction
- Dream exposes data via **MCP Server** for any AI assistant to query

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

*Remember everything. Explain nothing.*
