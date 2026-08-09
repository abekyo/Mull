# Contributing

## Before anything else

mull is a solo project with a strong opinion about what it is. [CLAUDE.md](CLAUDE.md) §0 lists
the four situations it exists for, and a change that serves none of them is out of scope by
construction. Small fixes are welcome without discussion. For anything that adds a feature,
changes the capture surface, or touches the selection layer, **open an issue first.** It is
cheaper than finding out at review that the change is out of scope.

## Language

The documents that record *why* the code is shaped this way are written in Japanese. That would
otherwise mean you cannot argue with a design decision without reading Japanese, which is not an
acceptable position for a repository that asks for contributions.

So the contract those documents produced is written in English, in
[ARCHITECTURE.md](ARCHITECTURE.md): the invariants a change must not break, each with the test
that enforces it, the layer boundaries, and a table saying which document decides what. **Read
that before proposing a design change.** It is enough to write the issue.

The Japanese documents are not translated, on purpose. A paragraph maintained in two languages
drifts, and nobody diffs prose across languages; [PITFALLS.md](PITFALLS.md) §7 is about what that
costs here. If a decision you want to argue with is only readable in Japanese, ask in the issue
and it gets translated there, next to the argument rather than into a second copy of the document.

Issues, pull requests and reviews are in English.

## Setting up

```bash
git clone https://github.com/abekyo/Mull.git
cd Mull

# Optional: keeps macOS permission grants stable across rebuilds
cp Local.xcconfig.example Local.xcconfig
security find-identity -v -p codesigning   # paste a hash into Local.xcconfig

brew install xcodegen
xcodegen generate
open Mull.xcodeproj
```

Requires macOS 14+, Apple Silicon and Xcode 16+. `Mull.xcodeproj` is generated and gitignored, so
edit [`project.yml`](project.yml) instead, never the project file. Sources are globbed by
directory, so a new file in `Mull/Core/` needs no project edit, just a regenerate.

## What has to pass

Two things, both of which run locally in under a minute:

```bash
xcodebuild -project Mull.xcodeproj -scheme Mull -destination 'platform=macOS' test
./eval/run.sh
```

The test suite is expected to be fully green. A count is deliberately not written down
here. It was wrong in two files at once the last time it was, and no document is the right
place to hold a number the test runner already prints.

Both commands also run on every push and pull request, so the two above are what CI enforces
rather than a convention you are trusted to follow. That was not true until 2026-08-09: only
the eval ran, and a change that broke the app build, or every test in it, still collected a
green check from a guide that said otherwise.

`eval/run.sh` is the selection-layer harness. It scores `Selection.rank` against labeled
`(need → ideal slice)` cases. It runs in its own workflow
([`.github/workflows/eval.yml`](.github/workflows/eval.yml)), separate from the build
([`.github/workflows/build.yml`](.github/workflows/build.yml)), for a specific reason: it compiles
a hand-maintained file list **without GRDB**, and it has silently broken twice when something
it depends on started importing GRDB. If you make `Mull/Core/` code reach for a new symbol,
check that `./eval/run.sh` still builds before you push.

> Current scores and the four known-failing gaps are in the README's status block, and
> [SELECTION-LAYER.md](SELECTION-LAYER.md) §6 is the specification behind them. The harness
> beats its three baselines on the synthetic set and scores far lower on real harvested logs;
> that gap is the interesting part. **New cases that the current ranker fails, especially
> ones harvested from a real log, are one of the most useful contributions available.**

## Changing the capture surface

Anything that changes what gets recorded, or what leaves the machine, is held to a higher bar
than the rest of the codebase:

- New capture sources need a line in the README's capture table and a reason in the issue.
- Nothing may be added to the outbound path (`Mull/Services/LLMClient.swift`) without going
  through the sensitive-content filter first.
- The default configuration must stay "nothing leaves this machine". A feature that requires
  the network has to be opt-in, and has to say so where the user turns it on.

[SECURITY.md](SECURITY.md) states the guarantees users are given. If a change would make any
line there untrue, that line has to change in the same pull request.

## Style

Match the file you are editing. The codebase has a specific comment habit worth keeping:
comments explain why a thing is the way it is (usually a constraint, a platform quirk, or an
incident that produced the code) and do not restate what the next line does. Several of the
most useful comments in this repository are records of something that went wrong. Keep writing
those.

Those comments are the record. [PITFALLS.md](PITFALLS.md) is the index of the ones that turned
out to be a pattern: the shapes of mistake this codebase has made more than once, and what is
holding each invariant today. It is short, and it is worth reading before you touch capture, the
vault writers, or anything wrapping AppKit in SwiftUI.
