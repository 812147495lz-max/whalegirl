# DSH agent observer

Run `python3 Integrations/WhaleGirlDSH/install.py` to install into an existing desktop profile. The installer copies the observer to the user's Application Support folder and adds a unique `insert` entry to the existing profile patch, with a timestamped backup. It does not restart DSH or run any model.

Only child identity, owner, activity state, optional public task label and timestamps are sent to WhaleGirl's per-user Unix socket. Working root sessions also create a separate main-agent pet; merely opening an idle session does not. Idle means activity ended, not verified success. A resumed child cancels its random 10–20-second retirement. Running children and working roots send a 2-second reconciliation heartbeat so WhaleGirl can reconnect after starting later.

Validated against installed DSH 0.2.0-rc.2 static source and upstream `deepseek-ai/deepseek-harness@687f282e8625c6b8d11ff58211a90524be2e4317`; lifecycle socket fixture passes. Observer v5 uses the optional sessionProjections snapshot and verifies the child owns that sequence before reading its public task label. It never reads prompts, assistant replies or tool payloads. Missing labels fall back to the real child ID. Real model tasks remain a separate unperformed end-to-end check.

Rollback: restore the timestamped `cordis.patch.whalegirl-backup-*.yml` to `cordis.patch.yml`, then restart DSH. This removes only the observer registration.

Version 5 tracks root working/step-start and successful/interrupted turn-end events. Running reconciliation sends heartbeats without reviving a completed turn. Main pets occasionally show generic thinking phrases; these are UI lines, not model reasoning. Routine root/child completion never sends a system notification. Root reply completion keeps the existing ten-second hanging peek. Child farewell stays on its own pet, followed by a 3.6-second halo/rise/curved feathered wipe. No dedicated entrance clip was identified in the existing catalog; entry is a short opacity transition.
