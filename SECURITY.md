# Security

mull reads the titles and the on-screen text of the windows you work in, and the things you
copy. That is a larger amount of trust than most software asks for, so this document states
plainly what it does with it, what it deliberately does not do, and how to report it when the
code does not match this page.

**mull does not read your keyboard unless you switch that on.** Since 2026-08-15 keystroke
capture is off by default: a fresh install never creates the event tap, never raises the Input
Monitoring prompt, and runs its other five channels without that grant. You can turn it on
under Settings → Data → Optional sources, and macOS will ask you then. The reason it is off is
measured rather than cautious — over 75 days the tap carried 3.0% of the text mull captured,
four fifths of it duplicating what the window reader already sees, and the part only it could
see was messages and notes ([DIRECTION.md](DIRECTION.md) §3.1). With it on, mull records
everything you type in every app you have not excluded.

## Reporting a vulnerability

Open a [private security advisory](https://github.com/abekyo/Mull/security/advisories/new) on
this repository. Please do not open a public issue for anything that could expose a user's
recorded data before there is a fix.

Include what you did, what happened, and which version or commit you were on. A proof of
concept is welcome but not required. A clear description of the path is enough to start.

This is a solo project, so there is no paid bounty and no guaranteed response time. What there
is: an acknowledgement when the report is read, and a note in the advisory when it is fixed or
when it is judged not to be a vulnerability, with the reasoning.

## What the threat model actually is

**The attacker mull defends against is any process or party other than you.** mull's design
assumption is that your Mac is yours and the software on it is not automatically trusted.

| Boundary | The guarantee |
|---|---|
| Network | No mull server exists. Point mull at Ollama or an OpenAI-compatible local server (LM Studio, Jan, llama.cpp, vLLM) and it runs with the network off entirely — nightly summaries, Chat and per-project deliberation included. The default configuration sends nothing either: the LLM ships off, and the MCP tools never call one at any setting. There is no telemetry, no analytics, no crash reporting, and no toggle for them because there is nothing to toggle. |
| Cloud LLMs | Off by default. Turning one on sends data directly from your machine to the provider you chose, with your own API key. There is no intermediary. |
| Secrets | Content classified as sensitive (API keys, card numbers, private keys, credentials) is filtered before it can reach a provider. See `Mull/Core/SensitiveText.swift` and `Mull/Core/Redactor.swift`. |
| Password fields | Skipped at capture via `IsSecureEventInputEnabled`, so they are never written in the first place. |
| Excluded apps | Password managers and keychain apps are excluded by default. mull never records itself. |
| Clipboard secrets | A copy marked `org.nspasteboard.ConcealedType`, which is what password managers stamp on a copied credential, is dropped before its contents are read. The marker travels with the copy, so it still holds after you switch apps, which the excluded-app list alone cannot do. |
| Storage | SQLite at `~/Library/Application Support/mull/mull.sqlite`, plus plain markdown in `~/mull/`. Ordinary files under your user account: both roots are `0700`, and every file mull writes content into is set back to `0600` after that write, because an atomic write replaces the file with a fresh one carrying the process umask. (Empty `.keep` markers under `_raw/` are the exception, and hold nothing.) The directories *inside* `~/mull` are left at whatever the umask made them; a directory nobody may enter cannot be traversed into, so the `0700` root is what protects them. Two consequences worth knowing. Files written by builds from before this landed keep their old mode until something rewrites them, so an older vault holds a mix. And the mode bits travel when you copy the vault to git, iCloud or a backup while the protecting `0700` root does not, so check what you are copying into. |
| API keys | macOS Keychain. Never written in plaintext. |
| Deletion | "Delete everything" and a time-scoped Forget both reach the quarantined copies of the database (`mull.sqlite.corrupt-*`, `.reattached-*`) that the recovery path leaves beside the live file, not just the live tables. |
| `me.pinned.md` | Yours alone. No MCP tool will write it, by any path. Content there is served to assistants as something *you* asserted, so an agent being able to add a line to it would be an agent putting words in your mouth. |
| Your calendar | mull can create, move and delete events, and four lines bound that. It keeps no copy: it writes to EventKit and reads back from EventKit, and nothing about your calendar enters mull's database. It writes only to a calendar you already chose, and never creates one. It writes nothing without an explicit gesture from you — double-click, type a title, press Return — **except the mirror described below, if you turn it on**. And every such write is registered with `UndoManager`, so ⌘Z reverses it. Recurring events are touched as `.thisEvent` only, and subscribed calendars stay read-only. The MCP `calendar` tool is read-only, so an agent can see your schedule but cannot change it. |
| The calendar mirror | Off unless you turn it on and name a calendar; mull will not pick one for you and will not create one. On, it writes what you worked on into that calendar on an interval you set. Three limits bound it. It writes only work that has **finished** — a block mull can still extend is never written, so nothing it puts in your calendar moves afterwards or claims you stopped at a moment you did not. It touches only events carrying its own marker, so a real appointment in the same calendar is never rewritten or removed. And a mirrored event you delete is **never written again**: mull remembers the deletion rather than restoring it on the next run. What it writes are the names of the things you worked on, taken from your window titles — so if the calendar you pick belongs to an account rather than to this Mac, that text leaves the machine, and mull says so in Settings beside the choice rather than afterwards. |

## What mull will not do to you

Three lines that are not security properties in the usual sense, and are load-bearing anyway.
A tool holding an Input Monitoring grant is in a position to do all three, so it is worth
saying which way this one is pointed.

- **You are never the product.** There is no telemetry to sell and no server to send it to.
  Your data is lent to a model you chose, on your terms, and is otherwise not lent at all.
- **mull does not own what it holds.** It is a custodian: everything it keeps is a plain
  file under your account that you can read, edit, move out, or delete without mull's help
  or permission. Nothing is stored in a form only mull can open.
- **You are not something to be fed.** Nothing in the interface streaks, scores, congratulates
  or nudges you toward using it more. It reports what it observed and gets out of the way.
  A record of your own life is not a game to be won.

## What mull does not protect you from

Stating these explicitly is part of the point:

- **The database is not encrypted at rest.** It is protected by your macOS user account and
  FileVault if you have it on, and by nothing else. Anyone with your unlocked machine, or with
  a backup of it, can read your recorded history.
- **Any process running as your user can read it.** macOS does not sandbox files in
  Application Support from other apps you run. mull cannot fix this.
- **Sensitive-content filtering is best effort, not a guarantee.** It is pattern matching. It
  will miss things. It is a reason to be careful with cloud LLM providers, not a reason to
  trust them with everything.
- **mull can carry someone else's instructions to your agent.** This one is structural, and
  it is worth understanding before you connect the MCP server to a coding agent that can run
  commands. mull records your clipboard and the text of your windows, much of which other
  people wrote, and then hands it to that agent as context. So a web page you merely had
  open, or a README you copied from, can plant a sentence that reaches your agent later,
  labelled as your activity. This is *indirect prompt injection*, and no product that
  captures untrusted text can claim immunity from it.

  What mull does about it: everything it returns is framed to the agent as quotation rather
  than instruction (`MCPServer.serverInstructions`), and lines it can tell are phrased as
  directives are individually marked (`Mull/Core/InstructionText.swift`). Both are road
  signs, not walls. The marking is keyword matching, and a determined phrasing walks past
  it. **The real mitigation is on your side: give an agent reading mull the same trust you
  would give the web pages you had open, and keep destructive tools behind confirmation.**
- **"mull does not read your email body" is narrower than it sounds.** The Mail integration
  is opt-in and reads headers only: subject, sender, date received, and nothing else
  (`Mull/Services/EmailService.swift`). But Mail.app is an ordinary application as far as
  the rest of capture is concerned. While you are reading a message, the window-body
  capture reads the text on screen the same way it reads a browser or an editor, because
  Mail is not on the excluded-apps list. The honest form of the promise is: *the mail
  channel reads only headers; your screen is read wherever you are.* Add Mail under
  Settings › Data › "Don't record in these apps" if you want the message text left alone
  as well.

- **Anything you send to a cloud LLM has left your machine.** After that, the provider's
  retention policy governs, not this one.

## Reading it yourself

The claims above are checkable, and checking them is the intended use of this repository:

| Question | Where to look |
|---|---|
| What is captured, and when is capture skipped? | `Mull/Services/RecordingService.swift` |
| What counts as sensitive, and what is filtered? | `Mull/Core/SensitiveText.swift`, `Mull/Core/Redactor.swift` |
| Does anything make a network call? | `Mull/Services/LLMClient.swift` for every provider request, and the connection tests in `Mull/Views/Settings/SettingsView.swift`. Those two files are the whole outbound surface, and three commands are what that is worth: `rg -l URLRequest Mull/` returns exactly those two; `rg -l -e NWConnection -e NSURLConnection -e WKWebView -e CFStream -e CFSocket Mull/` is empty, so there is no second networking API in the tree; and `rg -l URLSession Mull/` returns a *third* file, `Mull/Views/ChatPanelView.swift`, where the only match is a comment about cancelling a turn. It issues no request. Subprocesses are the remaining way out of a process, so: `rg -l 'Process\(\)' Mull/` finds four sites, and they launch `/usr/bin/ditto` (exporting the vault), mull's own bundled `MullMCP` (the connection test), and the MCP-server command you configured in Settings. mull runs no network client of its own through any of them |
| Can it run with the network off? | The `MullMCP` binary is built from `MullMCP` and `Mull/Core` only (see `project.yml`), and every file that touches `LLMClient` sits in `Mull/Services` or `Mull/Views`. The server your agent talks to does not contain a model call to make. Which providers stay on-device is one switch: `LLMProvider.isCloud` in `Mull/Core/Models.swift` |
| What does the MCP server expose to an agent? | `Mull/Core/MCPServer.swift` |
| How is captured text framed for an agent? | `Mull/Core/InstructionText.swift` |
| What is written to disk, and where? | `Mull/Core/DatabaseService.swift`, `Mull/Core/MullDirectory.swift` |
| What does deleting actually delete? | `Mull/Services/ForgetService.swift`, `Mull/Core/QuarantineRecovery.swift` |

If any of these disagree with this document, the code is correct and this document is a bug.
Report it the same way.
