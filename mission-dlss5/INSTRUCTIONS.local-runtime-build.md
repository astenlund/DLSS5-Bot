## Local runtime build

This file extends operating rule 3 (binary acquisition and trust) of the DLSS 5 ADDER operating prompt, and every rule of that prompt still applies. The store is the folder named by dlssnr_patcher_store in the prompt's state block.

- Local runtime build for RTX 20, 30, and 40 GPUs. When the selected route needs
  a patched nvngx_dlssnr.dll and the user does not already have one on this
  machine that suits the selected route, runtime version, and GPU, offer to build
  one locally from the user's own stock NVIDIA runtime before downloading,
  recommending, or asking for any patched binary. Never use it for
  anti-cheat-protected games. The bootstrap ships no trusted patcher version:
  trust is the user's decision, recorded per machine. Whenever this path cannot
  produce a verified runtime (a decline, a failed build, a declined overlay, an
  unavailable toolchain, no usable stock input, no usable Python, or an
  invalid pin while upstream is unreachable), say so and continue under the
  ordinary binary rules of operating rule 3. Never install Python or any other software for
  this path without the user's explicit approval.
    * Input: a stock nvngx_dlssnr.dll whose Authenticode status is Valid with signer
      NVIDIA Corporation. Look first in inputs\<file version>\ in the store, then
      ask the user; never download a stock runtime yourself. A copy in inputs\ is
      not trusted by location: check its signature and version before every use.
      With the user's consent, keep a verified stock copy the user supplied in
      inputs\<file version>\nvngx_dlssnr.dll for later builds. Record the input's
      file version and SHA-256. Refuse unsigned, invalidly signed, or
      already-patched input.
    * Patcher: dev-camo/dlssnr-patcher (GPL-2.0, one standard-library Python
      script, dlssnr_patcher.py). At commit 98dac112 it removes the NVIDIA
      signature, lowers the DLL's GPU architecture gates, rewrites PTX
      instructions the selected GPUs lack (sm_90-class bulk copy, barrier,
      release-fence, vector-reduction, and fused min/ReLU forms; FP8 math for RTX 20 and 30;
      matrix, half-precision min/max, asynchronous-copy, and barrier lowerings
      for RTX 20), and recompiles the CUDA kernels for the selected generations.
      Run it with the selected Python (see Python below) using -I and -B, only the needed generation flags
      (--turing, --ampere, --ada), --cuda-bin, --work-dir set to a new empty
      folder inside the build folder, and --output to a new file in that build
      folder. Never let it replace a file in place.
    * Toolchain: upstream expects a CUDA Toolkit install for ptxas, fatbinary, and
      cuobjdump; instead take them from the PyPI wheels nvidia-cuda-nvcc and
      nvidia-cuda-cuobjdump at exact versions of the CUDA release the pinned
      patcher requires (13.3 at commit 98dac112). Fetch them by running the
      selected Python with -I -B -m pip download
      --no-deps --only-binary=:all: into a toolchain\<nvcc version>-<cuobjdump
      version>\ folder in the store, extract both there so the three tools share
      one bin folder, pass that bin folder as --cuda-bin, and require a Valid
      NVIDIA Corporation signature on each executable. Do not install the CUDA
      Toolkit. The toolchain is part of the pin: if the pinned wheels can no
      longer be fetched or verified, the local build is unavailable until the
      user accepts a commit offer that brings a different toolchain.
    * Python: the patcher and pip run under one selected Python, invoked by its
      absolute path with -I and -B, never activated and never through a PATH
      change. Select it before staging anything that needs pip. Use an existing
      interpreter on this machine whose --version reports 3.10 or newer, that
      is 64-bit, and whose -I -m pip --version succeeds; an interpreter inside
      the store never counts as existing and runs only as the
      managed runtime under the managed runtime rules below, against the
      expected package they define. Only when none
      qualifies, use the managed runtime recorded in dlssnr_patcher.python if
      it passes its checks below, and otherwise offer to acquire one. The
      managed runtime is the official python.org NuGet package (package ID
      python on nuget.org, by Python Software Foundation), which includes venv
      and pip and needs no installer, registry, or PATH change. Never use an
      embeddable zip, an installer, or another distribution for it.
    * Managed Python offer: offer the latest stable (non-prerelease) version
      listed on nuget.org, showing its version, package URL, and the reason no
      existing interpreter qualified. If the recorded runtime has become
      unavailable, say so first and name the check that failed.
      Acquiring it needs the user's explicit
      yes; a decline records nothing and leaves the local build unavailable.
      After a yes, download the .nupkg into a new staging folder (see Store),
      require its SHA-512 to equal the packageHash in that version's
      nuget.org catalog entry, extract it there, and require a Valid
      Authenticode signature with signer Python Software Foundation on
      tools\python.exe, tools\pythonw.exe, and every tools\python*.dll, and
      that tools\python.exe -I -B --version reports the offered version. If
      any check fails, say so and record nothing. If the staged version
      equals the recorded version but the staged .nupkg SHA-256 differs from the
      recorded package SHA-256, state that mismatch and ask again before
      placing anything; a decline records nothing. On success, the expected
      package is the staged one (its version and the SHA-256 of its .nupkg
      bytes) until the pin is recorded. Place the runtime: if
      python\<version>\ is absent, move the contents of the extracted tools
      folder into it, so that python\<version>\python.exe exists, and put
      the .nupkg in it; if it exists, keep it when it passes the runtime
      checks below against the expected package, and otherwise replace it
      with the staged runtime and .nupkg as repair, subject to the unknown
      file rule below; this replacement takes precedence over the general
      cleanup confirmation for that folder only. Then prepare the venv as below, and record
      dlssnr_patcher.python only after the runtime and the venv pass their
      checks. If acquisition fails after placement, say so and name the
      runtime and venv folders this acquisition created or replaced,
      offering their removal under the store's confirmation rule; never
      offer to remove the recorded runtime or its venv this way. Afterwards, and after a failed check,
      remove that staging folder without confirmation, since this session
      created it; this takes precedence over the general cleanup
      confirmation for that folder only.
    * Bytecode caches: a __pycache__ folder under python\<version>\ or
      venv\<version>\ may hold only .pyc files, which Python regenerates and
      venv creation writes even with -B. Delete those .pyc files without
      confirmation each time before the runtime or venv checks run,
      including a repeat after a repair; this takes precedence over the
      general cleanup confirmation for those .pyc files only. Any other file
      in a __pycache__ folder is an unknown file (below).
    * Unknown files: an unknown file is a file in python\<version>\, in
      venv\<version>\Lib\site-packages\, or in a __pycache__ folder under
      python\<version>\ or venv\<version>\ that the checks neither expect
      nor allow (a .pyc file in a __pycache__ folder is allowed), or any
      other file in venv\<version>\ outside Lib\ except pyvenv.cfg and
      .gitignore at its top and, in its Scripts\ folder, python.exe,
      pythonw.exe, the pip*.exe launchers, and the activate and deactivate
      scripts. It has no recorded source to repair it from. It fails the
      check of its folder, and neither the
      refetch, nor venv --clear, nor any other repair runs on that folder
      while it is there: report it, offer its removal under the store's
      confirmation rule, and treat the managed runtime as unavailable until
      it is removed and the checks pass.
    * Managed runtime checks, before every use: the expected package is the
      recorded pin, except during acquisition (above). Require the .nupkg in
      python\<version>\ to have the expected package SHA-256, every file
      under that package's tools\ folder to be present in python\<version>\
      with identical bytes and no other file there besides the .nupkg and
      empty __pycache__ folders, the signatures above, and
      python\<version>\python.exe -I -B --version to report the expected
      version. If a check of the recorded runtime fails, refetch the recorded
      version into a new staging folder, require the recorded package
      SHA-256 and the checks of the offer, replace python\<version>\ with
      it as repair, and run the bytecode step and these checks again. If
      the refetch or the repeated checks fail, the managed runtime is
      unavailable: say so and name the check that failed. Either way,
      remove that staging folder without confirmation, since
      this session created it; this takes precedence over the general
      cleanup confirmation for that folder only.
    * Venv checks, before every use and after the runtime checks: require
      venv\<version>\Scripts\python.exe and Scripts\pythonw.exe to have a
      Valid Python Software Foundation signature, Scripts\python.exe -I -B
      --version to report the expected version, pyvenv.cfg to name
      python\<version>\ as its home and the expected version, and
      Lib\site-packages to hold only pip\, one pip-<pip version>.dist-info\,
      and empty __pycache__ folders, with every file in pip\ identical to
      the same file in python\<version>\Lib\site-packages\pip\ and no other
      file in either (empty __pycache__ folders are ignored on both sides).
      If venv\<version>\ is absent or fails, create it again with
      python\<version>\python.exe -I -B -m venv --clear venv\<version>\,
      which is repair, subject to the unknown file rule, and takes
      precedence over the general cleanup confirmation for that venv
      folder only; then repeat the bytecode step and the checks; if they
      still fail, the managed runtime is unavailable: say so and name the
      check that failed. The selected Python is
      then venv\<version>\Scripts\python.exe.
    * Managed runtime updates and removal: once per session that uses it,
      after its checks pass, check nuget.org for a newer stable version and
      offer it with its version and package URL, acquiring it as above;
      accepting re-pins to it in new python\<version>\ and venv\<version>\
      folders. Declining or postponing records nothing and keeps the
      recorded runtime in use. If nuget.org is unreachable, or acquiring the
      newer version fails, say so and keep using the recorded runtime; the
      update check never makes the local build unavailable. After any
      acceptance that records a different version than before, offer to
      remove the earlier version's runtime and venv folders.
      Removing a runtime or venv folder needs the user's exact-target
      confirmation; removing the recorded runtime also empties
      dlssnr_patcher.python.
    * Store: the store holds staging\ (each new staging folder is
      staging\<UTC timestamp as yyyyMMddTHHmmssZ>-<8 random hex digits>\,
      created by this session only if that path is absent; only a folder this
      session created that way counts as created by it), inputs\<file version>\,
      <commit>\dlssnr_patcher.py, overlays\,
      toolchain\<nvcc version>-<cuobjdump version>\, python\<version>\,
      venv\<version>\, and builds\<UTC timestamp
      as yyyyMMddTHHmmssZ>\ folders, each build with a build.txt recording its
      input, flags, commit, overlay, patched-script hash, toolchain, the
      selected Python's path and version, and output
      hashes, plus status: verified, written only after build verification
      passes. An earlier output counts as a patched runtime the user already has
      only if its build.txt says status: verified, its output hash still
      matches, and its commit, overlay, and toolchain equal the current pin;
      otherwise build again. It is persistent machine state, not session
      scratch. Replacing a store file that
      failed its own recorded hash, signature, or version check (including the
      wheels and extracted files of a toolchain folder that failed) with a
      verified refetch is repair and needs no confirmation, which takes precedence
      over the general cleanup confirmation for those store files only; any other
      removal or replacement needs the user's exact-target confirmation. A
      v39-style toolchain\<version>\ folder is not used; offer to remove it under
      that confirmation rule.
    * Pin record, in machine notes: dlssnr_patcher.commit (full commit hash),
      dlssnr_patcher.script_sha256 (SHA-256 of the exact bytes fetched for that
      commit from the GitHub contents API in raw form; never hash a Git checkout,
      whose line endings may differ), dlssnr_patcher.toolchain (the exact wheel
      pins separated by commas, for example
      nvidia-cuda-nvcc==13.3.73,nvidia-cuda-cuobjdump==13.3.73),
      dlssnr_patcher.overlays (the accepted overlay as one
      overlay-SHA-256@base-script-SHA-256@patched-script-SHA-256 triple, or
      empty), dlssnr_patcher.rejected_commits (full commit hashes separated by
      commas, or empty), dlssnr_patcher.accepted (ISO 8601 date of the latest
      acceptance; informational only), and dlssnr_patcher.python (the accepted
      managed runtime as one version@package-SHA-256 pair, the SHA-256 of the
      exact .nupkg bytes, or empty). Change these keys only to record an
      explicit user decision (an acceptance, a rejection, or a confirmed
      removal of the recorded managed runtime), under the
      machine-notes write rules. A missing python key reads as empty, and a
      malformed one is reported and read as empty; neither invalidates the
      patcher pin. A missing or malformed commit, script_sha256, or
      toolchain value, or a malformed overlays value, invalidates the pin; a
      missing overlays or rejected_commits key reads as empty, and a malformed
      rejected_commits value is reported and read as empty. Accepting a pin after
      an invalid pin starts a fresh record with an empty overlay and keeps a
      well-formed rejected_commits and dlssnr_patcher.python. A v39 record is valid: its overlay pairs
      (overlay@base with no patched hash, possibly several separated by commas)
      stay recorded but none is applied until the user accepts one again as the
      single triple, which replaces them.
    * Before any offer to pin a commit (first use, an invalid pin, a newer
      commit, or the current head when upstream no longer has the pinned
      commit), fetch its script and the toolchain it needs into a new
      staging folder in the store (see Store) and verify
      them as described above; the user's yes to the local-build offer covers
      this download. If that fails, say so, offer nothing, and record nothing.
      On acceptance, move each staged file whose pinned location is absent, keep
      any matching verified file already there, and replace any other file there
      with the verified staged copy as repair. Afterwards, and after a
      decline, rejection, postponement, or failed check, remove that staging folder without
      confirmation, since this session created it; this takes precedence over
      the general cleanup confirmation for that folder only. Offer to remove a
      staging folder left by an earlier session under the store's confirmation
      rule.
    * First use, or an invalid pin: fetch the default-branch head and read the
      script. If that commit is in dlssnr_patcher.rejected_commits, say so and do
      not offer it. Otherwise show the user the repository, commit, date, script
      SHA-256, license, and your own summary of what that exact script does,
      written from reading it rather than copied from the description above and
      naming every PTX rewrite it performs for the selected generations. Report
      any network access, any subprocess other than the three CUDA tools, and any
      file write outside its output and work directories. Ask the user to accept
      the risk and that exact commit and toolchain. A decline here records
      nothing.
    * Each later use: verify the stored script against dlssnr_patcher.script_sha256.
      If it is missing or differs, refetch the pinned commit and require the same
      hash; otherwise the pin is invalid, so report it and continue as on first
      use. Verify that each of the three tools still has a Valid NVIDIA
      Corporation signature and that its --version output names the exact pinned
      wheel version (for example V13.3.73 for 13.3.73); otherwise refetch the
      pinned wheels and repeat the check, and never build with an unaccepted
      toolchain. Repeat these script and tool checks immediately before every
      build. Once per session, and even when the toolchain is unavailable, check
      upstream for commits newer than the pin before falling back. If the newest
      one is not in dlssnr_patcher.rejected_commits, read it and give the same
      disclosure as on first use for it (commit, date, script SHA-256, license,
      and your own summary naming every PTX rewrite), plus every commit since the
      pin, the changed files, any new network, subprocess, or file-write
      behavior, and any different toolchain it needs. Ask the user to accept,
      reject, or postpone that newest commit together with its toolchain;
      postponing records nothing and keeps the pin. Accepting re-pins it
      with its toolchain. Rejecting adds it and every commit between the pin and
      it to dlssnr_patcher.rejected_commits and keeps the pin. If upstream is
      unreachable, keep using the verified stored copy and say so. If upstream no
      longer has the pinned commit, keep using the verified stored copy, say so,
      and offer the current head, unless it is already rejected, through the same
      full disclosure; accepting it is a re-pin, rejecting it adds it to
      dlssnr_patcher.rejected_commits, and postponing records nothing.
    * Overlays: when the pinned script fails on a specific input because of a
      narrow, demonstrable gap, such as an unsupported PTX form with a strictly
      stronger supported equivalent, you may propose a minimal unified diff
      against the pinned script. Name it overlays\<first 8 hex digits of the base
      script SHA-256>-<slug>.diff. Prepare the patched copy in a new build folder
      to compute its hash, show the diff, and record the triple only after
      explicit acceptance. Never run the patched copy before the user accepts
      the overlay; after acceptance, build from a new build folder. At most one overlay applies to a pinned script; to add
      another fix, regenerate one combined diff and have the user accept it in
      place of the old one. Apply the accepted overlay without Git, to a copy of
      the script in the build folder, never to the stored script and never inside
      the game directory. Before applying, require the overlay file's SHA-256 to
      equal its recorded overlay hash and its recorded base hash to equal
      dlssnr_patcher.script_sha256; after applying, require the patched copy's
      SHA-256 to equal the recorded patched-script hash. If any check fails,
      report it, leave the copy unused in its build folder, and run no build from
      that folder; build with the unpatched pinned script only if the user asks
      for that. A re-pin clears the overlay; to keep a fix on the new pin,
      regenerate the diff against the new script, show it, and have the user
      accept it as a new overlay. Offer to report the gap upstream, but never post
      anything on the user's behalf without explicit approval.
    * Build verification: require exit 0, the output file, and a log line for every
      rebuilt fatbin. Record input SHA-256, selected generation flags, output
      SHA-256, patcher commit, overlay, patched-script SHA-256 (the pinned
      script's own hash when no overlay applies), and toolchain with the
      installed component in the game notes; where no game notes file exists in
      a session that must not create one, follow the absent-notes rule of
      operating rule 7 (persistent game notes). The output is unsigned by design;
      never describe it as NVIDIA-signed. The same input, generation flags,
      patched script, and toolchain should reproduce the same output SHA-256, so
      treat a mismatch as a failure to investigate.
    * Install the built runtime under the ordinary transaction, verification, and
      visual-validation rules. A build is validated only for the generations it
      targets and the GPU it was tested on.
