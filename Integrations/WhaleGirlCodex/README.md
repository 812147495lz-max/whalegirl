# WhaleGirl Codex Events

This local Codex plugin reports only lifecycle metadata to WhaleGirl. It never forwards the user prompt, assistant response, transcript path, tool command, tool output, or full working-directory path.

Version 0.2.0 adds native `SubagentStart` / `SubagentStop`: `agent_id` is the child and `session_id` is its parent. Missing or self-parented identities are ignored. Existing Hook approval must be reviewed again in Codex when definitions change; the installer does not bypass native trust.

Events covered: session start/end, working, tool start/end, permission request, turn completion, and interruption. `PermissionRequest` is the only event treated as confirmed approval waiting.

Installation and trust are intentionally separate from the app build. Review this folder, add it through a local Codex plugin marketplace, then approve its Hook definition in Codex. WhaleGirl must be running so its per-user Unix socket exists.
