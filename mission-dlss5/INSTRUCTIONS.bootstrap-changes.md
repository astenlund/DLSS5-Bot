## Bootstrap changes

This file extends operating rule 9 (bootstrap self-improvement) of the DLSS 5 ADDER operating prompt, and every rule of that prompt still applies. Rule 9's explanation, exact diff, risk statement and explicit approval come first; this file says what a proposal must name and how an approved change is built and adopted.

- When intentionally changing bootstrap code, increment:
    rem DLSS5_BOOTSTRAP_VERSION=<integer>
- Preserve the files named by game_notes_path, machine_notes_path, and project_knowledge_path in the state block, and the engine store (the
  engine file named by engine_file_path and the location records beside it, such as the one named by location_record_path), according to their strict
  ownership and grammar unless the approved change explicitly migrates them.
- An approved bootstrap change must name both the shared AppData canonical and game-local destinations in its exact diff, behavior, and risk explanation.
- Increment both the batch version declaration and the embedded payload version literal. Preserve immutable historical whole-file and engine checksums.
- The package is an engine plus embedded sections: the MISSION section holds this prompt and its instruction files, and the STATE section holds the copy's arm state and any update record. Trust follows the engine hash, which excludes every section body. Build a candidate in published form, with an empty STATE section body; the adoption mode refuses anything else. A change to the mission alone is made by exploding the mission, editing its files and dropping them onto the package, not by a bootstrap change.
- Build and validate the complete candidate in the guarded AppData development directory. After explicit approval, invoke that candidate with --internal-adopt-bootstrap, the exact absolute game-local DLSS5-ADDER.cmd path, and the approved lowercase SHA-256. Invoke it from the game directory.
- Only adoption exit 0 proves success. Exit 1 is a wrapper precheck failure, 2 invalid arguments, 4 I/O failure, and 6 trust, Git, version, or target rejection. Unknown nonzero results are invocation failure. Preserve candidate and diagnostics after failure.
- Never replace bootstrap or checksum files directly using general agent tools. The adoption mode validates and records immutable trust, both the whole-file entry and the candidate's engine entry, in the engine file and then in its machine-notes copy, writes canonical before game-local, and verifies both destinations while serialized.
- Before invoking adoption, release any held machine-notes mutex. Bootstrap file lock always precedes the machine-notes mutex and every location record mutex (Local\DLSS5-ADDER-LOCATION-<hash>), and every engine file write holds the bootstrap lock. Never prompt while either lock is held.
- A v22 or older game copy does not converge on its own. Bring it forward once by adoption as above, which accepts such a target and compares it by its whole-file hash. Never confirm a v22 integrity overwrite for a file claiming v23 or newer.
