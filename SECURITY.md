# Security

mull holds an Input Monitoring grant and records what you type. That is a larger amount of
trust than most software asks for, so this document states plainly what it does with it, what
it deliberately does not do, and how to report it when the code does not match this page.

## Reporting a vulnerability

Open a [private security advisory](https://github.com/abekyo/Mull/security/advisories/new) on
this repository. Please do not open a public issue for anything that could expose a user's
recorded data before there is a fix.

Include what you did, what happened, and which version or commit you were on. A proof of
concept is welcome but not required — a clear description of the path is enough to start.

This is a solo project, so there is no paid bounty and no guaranteed response time. What there
is: an acknowledgement when the report is read, and a note in the advisory when it is fixed or
when it is judged not to be a vulnerability, with the reasoning.

## What the threat model actually is

**The attacker mull defends against is any process or party other than you.** mull's design
assumption is that your Mac is yours and the software on it is not automatically trusted.

| Boundary | The guarantee |
|---|---|
| Network | No mull server exists. With the default configuration nothing leaves the machine — there is no telemetry, no analytics, no crash reporting, and no toggle for them because there is nothing to toggle. |
| Cloud LLMs | Off by default. Turning one on sends data directly from your machine to the provider you chose, with your own API key. There is no intermediary. |
| Secrets | Content classified as sensitive — API keys, card numbers, private keys, credentials — is filtered before it can reach a provider. See `Mull/Core/SensitiveText.swift` and `Mull/Core/Redactor.swift`. |
| Password fields | Skipped at capture via `IsSecureEventInputEnabled`, so they are never written in the first place. |
| Excluded apps | Password managers and keychain apps are excluded by default. mull never records itself. |
| Storage | SQLite at `~/Library/Application Support/mull/mull.sqlite`, plus plain markdown in `~/mull/`. Both are ordinary files under your user account. |
| API keys | macOS Keychain. Never written in plaintext. |

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
- **Anything you send to a cloud LLM has left your machine.** After that, the provider's
  retention policy governs, not this one.

## Reading it yourself

The claims above are checkable, and checking them is the intended use of this repository:

| Question | Where to look |
|---|---|
| What is captured, and when is capture skipped? | `Mull/Services/RecordingService.swift` |
| What counts as sensitive, and what is filtered? | `Mull/Core/SensitiveText.swift`, `Mull/Core/Redactor.swift` |
| Does anything make a network call? | `Mull/Services/LLMClient.swift` — the only outbound path |
| What does the MCP server expose to an agent? | `Mull/Core/MCPServer.swift` |
| What is written to disk, and where? | `Mull/Core/DatabaseService.swift`, `Mull/Core/MullDirectory.swift` |

If any of these disagree with this document, the code is correct and this document is a bug.
Report it the same way.
