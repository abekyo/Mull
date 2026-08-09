# Pitfalls

Defects this codebase has produced more than once, and the invariant each one left behind.
The second occurrence is always cheaper to prevent than to find, and these have all had a
second occurrence.

**This is not a bug list.** Fixed bugs are in `git log`; open ones are in issues. The record of
why a particular line is the way it is belongs in the comment above that line, and this
codebase has a lot of those on purpose — copying them here would produce two records that
disagree within a month. What is collected here is the smaller thing: the **shapes of mistake**
that have recurred, each with the instances that established them.

Worth reading before you change capture, the vault writers, or anything that wraps AppKit in
SwiftUI. That is where they keep happening.

Every entry ends with **Held by**, which says what is actually preventing a recurrence today.
An invariant enforced by a test is a fact. An invariant enforced by this file is a hope with
good intentions, and the difference is worth stating out loud.

---

## 1. An API does something you did not ask for

The call is correct. It also does a second thing, and the second thing is the defect.

| What was called | What it also did |
|---|---|
| `textView.string = text` | Parked the insertion point at the **end** of the buffer. Giving the view focus a moment later scrolled that caret into view, so every note opened at its last line — [`MarkdownTextEditor.swift:124`](Mull/Views/Components/MarkdownTextEditor.swift#L124) |
| `write(to:atomically:)` | Wrote a temp file and renamed it, which bumps the **parent directory's** mtime. The sidebar's "has the shape changed" signature was built on folder mtimes, so the 0.8s autosave and the 60s context pass both moved it, and the file tree rebuilt and re-sorted under the cursor while you typed — [`FullWindowView.swift:446`](Mull/Views/FullWindowView.swift#L446) |
| `NSWindow.didBecomeKeyNotification` | Fired for **every** window in the app. Opening Settings or the menu-bar panel rebuilt the main window's file tree behind the user's back — [`FullWindowView.swift:231`](Mull/Views/FullWindowView.swift#L231) |
| Unlinking the old database during migration "recovery" | The pool still held it open, so the app went on writing to a deleted inode and the history vanished at the next launch (`3a26448`) |

**Invariant.** The question is never "did this call do what I wanted". It is "what else moved".
Caret position, first responder, scroll offset, directory mtime and file identity all change
without appearing anywhere in the call you wrote.

**Held by:** prose. None of these four have a test.

---

## 2. A proxy signal is wider than the thing it stands for

Something cheap stands in for something real. It is true when the real thing is true — and also
at other times, which is where the defect lives.

- **Folder mtime** stood for *the vault's shape changed*. It is equally true when a file's
  contents are written. Same defect as the second row above, seen from the other side.
- **`isRunning`** stood for *capture is not paused*. The health check saw a stopped recorder,
  judged it a fault, and restarted capture within ten seconds of the user pausing it
  (`3a26448`). Pause survives now because it is stored rather than inferred —
  [`AppState.swift:480`](Mull/App/AppState.swift#L480).
- **A raw window-title string diff** stood for *the user switched projects*. Two separate
  implementations of that inference drifted apart on the same 3-second tick and produced two
  banners for one switch (`c00799c`).

**Invariant.** Write down what the signal is a proxy *for*, then ask what else makes it fire.
If any answer is "an unrelated write", it is the wrong signal — narrow it until the only cause
is the thing you meant.

**Held by:** prose.

---

## 3. Two writers for the same resource, sometimes in two processes

- `now.md` and `full.md` each had two wholesale writers. The nightly LLM output was overwritten
  by the rule-based 60s pass within a minute of being produced. Both go through `Curator` with
  disjoint owned block prefixes now — [`Curator.swift:230`](Mull/Core/Curator.swift#L230).
- The app and the `MullMCP` binary are **separate processes on the same SQLite file**. Both
  could run `ALTER TABLE` at startup; the loser got `SQLITE_BUSY` and fell into the destructive
  recovery path while the winner was still attached. Migration holds an `flock` —
  [`DatabaseService.swift:301`](Mull/Core/DatabaseService.swift#L301).
- `_raw`'s in-process `NSLock` was correct and insufficient, for exactly the same reason
  (`d90c704`).
- Four call sites rebuilt `~/mull` by hand instead of going through `MullDirectory`, bypassing
  its migration and writability gate — so a relocated vault was visible to some readers and
  invisible to others (`d90c704`).

**Invariant.** Before writing to the vault or the database, go find the other writer. There
usually is one, and it is often in another process, where an in-process lock cannot see it.

**Held by:** `flock` for migration and `_raw`; `Curator`'s prefix ownership for the context
files. "Go through `MullDirectory`" is held by review.

---

## 4. The failure produces no signal

The worst class, because nothing is on fire.

- `findRelevantKnowledge` built `"swift* OR chart*"`, which `searchKnowledge` then re-starred
  into `"swift** OR* chart**"` — an FTS5 syntax error, swallowed by a `catch`. The feature had
  never once returned a result (`3a26448`).
- Japanese search returned nothing at all, because `unicode61` tokenizes a CJK run as a single
  token, so a prefix term could never match (`3a26448`).
- `eval/run.sh` compiles a hand-maintained file list **without GRDB**, and rotted silently twice
  when something it depends on started importing GRDB. It now says so at the top of itself —
  [`eval/run.sh:4`](eval/run.sh#L4) — and CI runs it on every push
  ([`.github/workflows/eval.yml`](.github/workflows/eval.yml)).
- `_raw`, documented as the immutable zone future models re-synthesize from, was quietly
  dropping its oldest lines past 2000 per connector (`d90c704`).

**Invariant.** A `catch` that logs nothing, a query that returns empty, and a check that stopped
being run are one defect in three costumes. If a path can fail quietly, make it say so: the eval
harness reports that the correction loop is not connected end to end **out loud**, rather than
passing quietly and being believed (`2d4c93c`).

**Held by:** [`SearchQueryTests.swift`](Tests/SearchQueryTests.swift) for the query paths
(punctuation, bare booleans, prefix terms, CJK detection); CI for `eval/run.sh`.

---

## 5. A rule written only in prose holds wherever someone happened to look

This file is an instance of the class it is describing. That is what the **Held by** line is for.

- Emoji are banned from the interface *and* from generated text. The interface half held.
  The generated half did not: `list_files` shipped a 📁/📄 file tree and `get_projects` shipped
  ⚠️ STALLED, because nothing was reading the strings an agent sees. The rule is a test now, one
  that walks every shipped `.swift` file and reads its string literals —
  [`ShippedVocabularyTests.swift:46`](Tests/ShippedVocabularyTests.swift#L46).
- The comment above `startTreeWatch` described the sidebar signature **wrongly twice inside one
  day**: first claiming that typing did not move it (false — mtimes moved it), then, once that
  was fixed, still claiming the signature was built on mtimes (false — it no longer was). Same
  four lines, two different errors, the second one introduced by the commit that fixed the first.
- `CONTRIBUTING.md` stated a test count that had drifted from the real one as tests were added.
- `project.yml` records that `Mull/Core` being UI-free is kept **by review and not by the
  compiler**, instead of claiming the boundary is enforced (`c00799c`). That is the honest form
  of an unenforced rule, and the form to copy.

**Invariant.** A rule that can be checked by walking the source should be a test rather than a
sentence — `ShippedVocabularyTests` is a lint wearing a test's clothes and it belongs in the
suite. A rule that cannot should name its enforcer, so that nobody mistakes a sentence for a
guarantee. Counts and file lists in prose drift; prefer pointing at the thing over restating it.

**Held by:** itself, which is the point. See the bar below.

---

## 6. SwiftUI calls you back constantly, and after the fact

An AppKit view wrapped in `NSViewRepresentable` is driven by an update path that runs far more
often than the user does anything, in an order you did not choose.

- `updateNSView` runs on every ancestor re-render, and `AppState` refreshes every 3 seconds.
  Comparing `textView.string` against the binding and "fixing" the difference wiped freshly
  typed characters and destroyed in-flight Japanese IME composition — the binding lags the view
  by a runloop turn, and marked text is not in it at all. The buffer is deliberately allowed to
  go stale while the editor holds focus —
  [`MarkdownTextEditor.swift:152`](Mull/Views/Components/MarkdownTextEditor.swift#L152).
- `saveCurrentFile()` re-derived its target from the live `selection`, but `onChange` fires
  **after** selection has already changed — so editing note A and clicking note B wrote A's
  buffer into B. The save target is captured at load time and passed explicitly now
  (`3a26448`, [`FullWindowView.swift:1437`](Mull/Views/FullWindowView.swift#L1437)).
- The 5-second tree poll turned a single mtime mistake into a rebuild every minute, forever.

**Invariant.** Ask two questions of every representable: what happens when this method is called
a hundred times with nothing changed, and what was the value when the callback was *scheduled*
rather than when it ran. A one-shot bug in here is not one-shot.

**Held by:** prose. The save-target capture has no test either.

---

## 7. One fact, enumerated by hand in two places

Not a rule written in prose (that is §5) — two *compiled* lists, both correct-looking, both
covered by tests, describing the same fact. They drift, and the shorter one silently stops
protecting something.

- **Which root files the sidebar pins.** `contextFiles` listed four; `buildTree`'s "already
  drawn above, skip it" set listed three. `me.pinned.md` was therefore drawn twice — once at
  the top, once down among the loose root files — and both rows carried the same `.tag`, so
  selecting the file highlighted two rows and the list scrolled away to the second one. One
  table now, and the skip set is derived from it —
  [`FullWindowView.swift:1783`](Mull/Views/FullWindowView.swift#L1783).
- **Which files mull writes.** `MCPServer` kept the set an agent may not raw-overwrite (six
  files plus `index.md`); the Files tab kept its own set of files the *user* may not type into
  (four). So the editor offered `full.md`, `mull.md`, `proactive.md` and every folder
  `index.md` as ordinary notes, with a Save button — files the same build refused to let an
  agent touch. **`mull.md` lost the writing outright**: it is the one context file written with
  a wholesale `MullDirectory.write` rather than through `Curator`
  ([`LiveContextGenerator.swift:103`](Mull/Services/LiveContextGenerator.swift#L103)), so it
  carries no provenance markers and there is no hand edit to promote to `.human` and protect.
  Whatever was typed there was gone at the next 60-second pass, with nothing said. Both
  surfaces ask [`VaultOwnership`](Mull/Core/VaultOwnership.swift) now —
  [`FullWindowView.swift:344`](Mull/Views/FullWindowView.swift#L344),
  [`MCPServer.swift:581`](Mull/Core/MCPServer.swift#L581).

The second one also shows what the drift costs when it is invisible: the four files it exposed
were displayed **without** `stripMarkers`, so `<!-- mull:block id=… src=agent hash=… -->` had
been sitting in the body of four files in the Files tab — the markers that function exists to
hide — and nobody had read it as a symptom.

**Invariant.** Two enumerations of one fact are a schedule for a defect, not redundancy. Before
adding a name to a list, search the codebase for the other copy of that list; if there is one,
delete it rather than extending it. A predicate both callers can ask beats two sets they both
maintain — and where the two callers need *different* answers, say so in the type rather than in
two sets that look interchangeable. `me.pinned.md` is `.user` even though mull does write to it,
because the distinction that matters is not "does mull touch this file" but "does mull rewrite a
line the user wrote" (CLAUDE.md §7.4).

**Held by:** [`VaultOwnershipTests.swift:27`](Tests/VaultOwnershipTests.swift#L27), which names
the four regressed files individually, so the same list going short again fails the suite. The
sidebar half is held by prose.

---

## The bar for adding an entry

Deliberately high. A file that collects everything gets read once.

An entry belongs here when **the same shape of mistake has happened at least twice**, or when a
single occurrence cost real user data. One occurrence with a good comment above it is already
recorded — leave it there. That comment habit is described in
[CONTRIBUTING.md](CONTRIBUTING.md), and it remains the primary record; this file is the index of
what turned out to be a pattern.

When you add one:

- Name the **mechanism**, not the symptom. "The sidebar jumped" is a bug report; "atomic writes
  bump the parent directory's mtime" is a pitfall.
- Cite something checkable — a file and line, or a commit hash.
- Fill in **Held by** honestly. If the answer is "prose", say "prose".

Most of the **Held by** lines above still say "prose" — read them and see which. (This used to
say "six", written when there were six entries; the count started drifting the moment a seventh
was added, which is §5 happening to this very paragraph.) Each one is an open invitation to
convert an invariant into a test, which is among the more useful contributions available here —
`ShippedVocabularyTests` is the pattern to copy when the rule is about the source itself, and
extracting a pure function out of a view is the pattern when the rule is about behaviour.
