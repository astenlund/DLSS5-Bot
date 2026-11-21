# Quick wins

Refactors ready to land when time allows. A quick win is always ready for its own pickup, but features and bugs may still list it as a prerequisite.

This file is **one of four repo-local indexes** agents consult on demand when relevant (alongside `FEATURES.md`, `BUGS.md`, `PATTERNS.md`). Active entries are kept inline, organized under thematic `##` sections you invent as work emerges. When a quick win lands, append a shipped-note entry to [`QUICK_WINS_HISTORY.md`](QUICK_WINS_HISTORY.md); do not move it within this file. Negative-knowledge findings (approaches attempted and reverted) are first-class promotion candidates from the history to the relevant `.nightshift/patterns/<slug>.md` Cautionary tales sections.

Readiness and graduation are not approval. Agree meaningful commitments through an investigated understanding readback or concise spec; preserve valid agreement through compatible corrections and compaction.

Backlog prose is one paragraph or one bullet per physical line, never hard-wrapped at a column: a search hit then shows the whole entry, the parsers anchor on whole lines, and an edit shows as one changed line instead of a reflowed block. `/nightshift:ready` reports a hard-wrapped file as a notice so it can receive a scoped repair before handover.

**Before adding an entry, look for a feature to fold it into.** If an active feature in `FEATURES.md` would remove or rewrite the lines the fix touches, so that the fix would not survive the feature in its current form, add the fix as one line under that feature record's `## Carried fixes` heading, beginning with the name of the slice whose work removes those lines when the feature is sliced, giving the observed failure, its location, what the replacement must do and a link to the evidence, and create no entry here. When the feature would remove only part of what the fix changes, and that part fails and can be verified on its own, carry that part the same way and add an entry here for the rest that names the part carried and links the feature's `## Carried fixes` heading, while the carried line links its evidence rather than that entry, so either can ship first; a fix whose parts cannot be separated stays whole. A feature that merely touches the same module does not qualify, and neither does an Exploring draft, which has not settled what it replaces. A repeat adds a date to that line, never a paragraph. A tenuous match, or a feature invented so there is somewhere to fold into, means an entry here as before. A defect that blocks runs now gets the smallest stopgap, noted on its carried line, without an entry of its own. `FEATURES.md` describes how carried fixes ship and what happens to them when a feature is retired.

Capture shorthand: name the refactor, describe the current smell in a sentence or two, sketch the preferred shape. A reader should be able to start work from the entry alone. Anchor entries on identifiers that survive refactors -- symbol names, entry titles, commit hashes, config keys -- never on line numbers, plan-phase ordinals, bullet positions, or temporal qualifiers ("new", "recent"): a precise locator that rots misleads harder than a coarse one that holds.

**After adding a new entry, run `/nightshift:ready`** from the repo root to confirm it parses as a quick-wins work item against the real grammar in `skills/ready/ready.js`. Quick wins carry neither a `**Requires:**` nor an `**External:**` line, and ready reports one written on a quick win as a notice; the other failure mode to catch is an entry that doesn't parse as a `- ` bullet or `###` heading (ready reports it as a prose-only-section notice) while you can still fix it in the same session.

## Release tooling

### Build record names its commit and covers the pin and tools

`tools/Build-Package.ps1` writes `build/build-record.json` with `mission_clean` over `mission-dlss5/` only and no DLSS5-Bot commit, so a build from an uncommitted pin and engine pair, or with an edited `tools/Assemble-Package.ps1`, still records `kind: pin` and `mission_clean: true`. Record the HEAD commit and extend the clean check to `engine/` and the assembly scripts, as Pluri-Bot's `tools/Build-Release.ps1` does with `commit` and `source_clean`, before the v1-1 publication gate ties a package to a reviewed commit.

### Pin update checks the engine version against the tag

`tools/Update-EnginePin.ps1` reads the engine version from the downloaded engine file and never compares it with the tag, so a release tagged `v3` carrying an engine that reports version 2 would be pinned, and `tools/Build-Package.ps1` cannot catch it, since both values then come from the same file. Require a `v<n>` tag's number to equal the engine version, and `legacy-v67` to carry version 67.

### Array parameters and shared scratch in the imported tools

`tools/Normalize-Endings.ps1` (`[string[]]$Paths`) and `tools/Probe-MissionMerge.ps1` (`[string[]]$Hosts`) take array parameters, which `pwsh -File` binds as one string or spills into other parameters; take one delimited string and split it inside. `tools/Compare-PromptParity.ps1` and the probes use fixed scratch folders under `.tmp/`, which two concurrent runs would share; give each run a folder of its own.

## History

Implemented quick wins are archived in [`QUICK_WINS_HISTORY.md`](QUICK_WINS_HISTORY.md), consulted only on demand so the active backlog above stays scannable. When a quick win lands, append its entry there rather than to this file.
