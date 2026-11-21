# Import record

DLSS5-Bot's initial commits import the DLSS mission of DLSS5-ADDER at legacy v67, the last release published from its gist, with its release suite, as the repository-home design (held in Pluri-Bot, `docs/repository-home/2026-11-20-repository-home-design.md`) sets out. The history of the legacy line (v1 to v67) is not reconstructed as commits; its development folders stay in the author's LocalAppData as a frozen archive. Pluri-Bot's import record covers the engine's half.

## Sources and hashes

- `mission-dlss5/` is the legacy v67 release folder's `mission-dlss5\`, unchanged.
- `engine/engine.cmd` is the engine file Pluri-Bot joins from its import, SHA-256 `2701fafcded1e2ed1a206c7eaf4b925186922a12675be3eee2f0492d2e747ef4`, the engine hash of the published legacy v67 package. `engine/pin.json` pins it as Pluri-Bot's `legacy-v67` release.
- `tools/Build-Package.ps1` assembles, from the pinned engine and `mission-dlss5/`, a package byte-identical to the published legacy v67 package, `DLSS5-ADDER.cmd`, SHA-256 `35414382fc84514ea47197d5bdb2d01f158b33ecf6d6b8c854cfd3ee99a92140`, published at revision `858ae4c6efe62fc2180eb5f040f8e7e2697668ec` of gist `b05c26b341d569124bcdd0edf29c34cf`. The import lost nothing.

## Historical packages

The suite reads two historical packages, and the legacy v67 package is the new line's first baseline. They are committed under `tests/fixtures/`, each with the gist revision that published those exact bytes, which is what makes them already public:

| File | SHA-256 | Gist revision |
|---|---|---|
| `DLSS5-ADDER.v22.cmd` | `caaa556470bc78f7440d040ca642c2304930472e64e09de87ac616acadbd3831` | `bb5dfa3925946a2f0934d13b0768927f93e3eaf7` |
| `DLSS5-ADDER.v49.cmd` | `d442d3a73f4b92572fbe81cc0274982254e4778685e8238e0bfd4c584b524a0a` | `c5fb4ad60c6bed27d18e44b5ebab42fc5d148387` |
| `DLSS5-ADDER.v67.cmd` | `35414382fc84514ea47197d5bdb2d01f158b33ecf6d6b8c854cfd3ee99a92140` | `858ae4c6efe62fc2180eb5f040f8e7e2697668ec` |

## The release suite

The suite comes from the LocalAppData `tests\` folder. Each retained file is unchanged apart from the changes listed here:

- `Test-DLSS5Adder.ps1` no longer hands a v23 updater to the standalone v23 suite.
- `Test-DLSS5Package.ps1` reads the v22 and v49 packages from `tests/fixtures/` instead of the archive, and no longer holds "package hello-world base shares the engine and runs as a plain mission".
- `Test-DLSS5Guard.ps1` no longer holds "guard holds the hello-world base folder too".
- `Test-DLSS5Stores.ps1` runs "store menu lists the engine store and removes orphaned, unreadable, mismatched and collision records on confirmation" for the shared AppData copy only; its hello-world base variant became a case of its own.

The two removed cases and that variant read the hello-world base, which Pluri-Bot owns, so they moved to Pluri-Bot (user decision, 2026-11-21) and run there against its own base. `records/import-expected-differences.txt` lists the two removed cases for `tools/Compare-SuiteResults.ps1`.

The other nine retained files are byte-identical to the LocalAppData copies: `Hold-DLSS5Guard.ps1` (Pluri-Bot holds an identical copy), `Test-DLSS5Configure.ps1`, `Test-DLSS5Fingerprint.ps1`, `Test-DLSS5HostModel.ps1`, `Test-DLSS5LineEndings.ps1`, `Test-DLSS5Merge.ps1`, `Test-DLSS5MissionStores.ps1`, `Test-DLSS5Remove.ps1` and `Test-DLSS5Tests.ps1`. Once step 1 acceptance passes, the originals of the four changed files and every retired file below move into the archive's `development\retired-tests\` before the LocalAppData `tests\` folder is removed.

Retired, and not imported:

- The standalone v23 suites (`Test-DLSS5V23.ps1` and the eleven `Test-DLSS5V23*.ps1` files it runs), their three `Invoke-DLSS5V23*Fixture.ps1` helpers, the v24 suite `Test-DLSS5V24.ps1`, and the v23 hand-off in `Test-DLSS5Adder.ps1`. They are pinned to the historical v23 and v24 candidates in the archive, and no current release reaches them.
- `Test-DLSS5GithubDiscovery.ps1`, which only the historical v24 release folder's `Verify-Artifacts.ps1` ran; no suite file and no later release script runs it (searched across the LocalAppData folder, archive included).

## Release scripts

The legacy v67 release folder's scripts were per-release copies with version, hash and revision constants. By the user's decision of 2026-11-21, step 1 imports and generalizes only the scripts its own checks use or that no release ties to its numbers, and step 2 converts the rest for the v1-1 procedure or records their retirement:

- Imported unchanged: `Assemble-Package.ps1`, `Get-PayloadDefinitions.ps1`, `Invoke-SuiteOffscreen.ps1`, `Render-MissionPrompts.ps1`, `Normalize-Endings.ps1`.
- Imported with release-folder defaults replaced by this repository's build output, its `.tmp/` scratch and the LocalAppData `release-records\` folder, with mandatory parameters where a script compared against the previous release (in `Compare-PromptParity.ps1` the baseline and the prompt-changes file, whose output also labels the two sides baseline and candidate instead of v66 and v67): `Invoke-SuiteToFile.ps1`, `Parse-Candidate.ps1`, `Validate-Notes.ps1`, `Compare-PromptParity.ps1`, `Compare-LaunchFunctions.ps1`, `Probe-AccountCheck.ps1`, `Probe-ApprovalModes.ps1`, `Probe-MissionMerge.ps1`.
- Replaced: `Build-Candidate.ps1` by `Build-Package.ps1`, which builds from the pinned engine rather than editing a copy of the canonical package; `Invoke-FilteredSuite.ps1` by `Invoke-Suite.ps1`, which runs a filtered or a full suite; `Build-Base.ps1` by Pluri-Bot's `Build-Release.ps1`.
- Moved to Pluri-Bot: `Test-HelloBase.ps1`, the hello-world base's own test.
- New: `Update-EnginePin.ps1`, `Compare-SuiteResults.ps1` and `Invoke-PrivacySweep.ps1`. `Update-EnginePin.ps1 -FromDirectory` was run against Pluri-Bot's built legacy engine and rewrote `engine/pin.json` and `engine/engine.cmd` byte for byte, and it refused a mismatched published hash and a file that is a package rather than an engine form; its download path runs once Pluri-Bot's `legacy-v67` release exists.
- Left in the archive until step 2, which converts or retires each: `Verify-Candidate.ps1`, `Install-Canonical.ps1`, `Test-InstallCanonical.ps1`, `Invoke-PostReviewChecks.ps1`, `Invoke-BaselineSuite.ps1`, `Test-BaselineSuite.ps1`, `Compare-BaselineFailures.ps1`, `Test-V66Interop.ps1`, `Write-PromptChanges.ps1`, `Write-ReviewInputs.ps1`, and the gist publication scripts `Prepare-Publication.ps1`, `Publish-Gist.ps1`, `Publication-Common.ps1`, `Capture-PublicationSnapshot.ps1`, `Verify-Publication.ps1` and `Test-ReadmeProposal.ps1`.
- Retired: `Seed-ReleaseFolder.ps1`, `Shift-ScriptVersions.ps1`, `Fix-ShiftCollisions.ps1` and `Show-ShiftDiff.ps1`, the machinery that copied and renumbered the scripts for each release, which one copy per script replaces. `Invoke-Reviewer.ps1` and `Read-ReviewerReport.ps1` dispatched and read review agents during a release; they are session tooling rather than release checks and stay in the archive.

## Research and backlog

- `research/` is the LocalAppData `research\` folder, with this machine's home folder in the recorded paths generalized to `<user>`; once step 1 acceptance passes, its unaltered originals move to the archive's `development\research-originals\`.
- The backlog's DLSS release procedure entries ("Release suite in CI" and "Lighter post-review gate") live here. The entries that span the engine and this mission, and every history entry recorded before this repository existed, are in Pluri-Bot's backlog, which this backlog points at.

## Privacy sweep

`tools/Invoke-PrivacySweep.ps1` swept every commit of the import, each commit's message and every file it adds or changes, before the first push, and reruns over the outgoing commit range before every push. Its generic patterns are a home folder path other than a fixture name, an email address outside the reserved example domains, and GitHub, Anthropic and AWS token shapes and private key headers. Its literal terms (the author's names, account, computer name and machine id) and the values public by the author's decision (the commit address, which test fixtures also use as a Git identity) are kept outside the repository, in the LocalAppData `release-records\` folder. Apart from the research paths above, the sweep found nothing to change: the published engine and fixtures hold only the public GitHub owner name.

## Suite run

The full suite, run on 2026-11-21 from this repository through the off-screen runner against the package `tools/Build-Package.ps1` assembled, with the LocalAppData `development\` folder renamed away for the run, passed all 366 cases. `tools/Compare-SuiteResults.ps1` found it in agreement with legacy v67's recorded per-case results (368 cases, all passing) apart from the two cases `records/import-expected-differences.txt` lists, which pass in Pluri-Bot; no case differs only by a changed path. Pluri-Bot's three base cases passed the same day through its off-screen runner. The outputs, the comparison's included, stay in the LocalAppData `release-records\import\` folder.
