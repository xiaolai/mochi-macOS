# Conversation instructions and automation

In a conversation’s sidebar **…** menu, choose **Conversation Instructions…**. Instructions, coaching style, and optional speech speed belong to that conversation and are saved locally. Changes affect future replies; existing messages and audio stay as recorded. Empty instructions use Mochi defaults. New edits are limited to 8,000 characters. Longer prompts from foreign libraries or backups keep their full saved text; future replies use the first 8,000, and the editor asks you to shorten them before saving. Custom instructions override conversational defaults. Help Me Say This and exact reference speech retain their task-specific instructions.

Mochi’s conversation model can use learning tools when asked—for example, “save that expression” or “let’s practise the phrase we just saved.” Practice navigation and playback requested during a reply happen after Mochi finishes speaking (or after generation for a text reply). Stopping playback cancels pending navigation and draft preparation. Existing nonempty Help drafts are protected; finish or clear them before preparing another expression. If acknowledgment audio fails, the scheduled action still opens. Recording always requires a user action.

## Connect an external assistant

Open **Settings → Automation**, enable external control, and copy the MCP configuration into your assistant’s settings. The bundled `mochi-mcp` executable speaks MCP over stdio. Keep Mochi running. Disabling external control closes the bridge immediately; there is no network listener. The app bridge uses a private Unix socket inside macOS’s protected per-user temporary directory, accessible to your macOS user. Enable this only for assistants you trust with your active conversations.

The copied configuration points at the current app bundle, for example:

```json
{"mcpServers":{"mochi":{"command":"/Applications/Mochi.app/Contents/MacOS/mochi-mcp"}}}
```

For Codex CLI, the equivalent registration is:

```sh
codex mcp add mochi -- /Applications/Mochi.app/Contents/MacOS/mochi-mcp
```

The copied configuration includes `MOCHI_CONTROL_SOCKET` when needed for the active library. Copy it again after moving the app. Install the app before copying a configuration from a quarantined or translocated launch. Use the actual installed app path. Mochi does not register clients automatically.

## Tools

| Tool | Behavior |
| --- | --- |
| `get_session` | Current ID, revision, activity, instructions, preferences, audio and expression IDs |
| `get_messages` | Last 1–100 messages of the open active conversation; long text is truncated to 2,000 characters |
| `prepare_expression` | Prepare English and optional meaning for review in Help Me Say This |
| `save_expression` | Save English and optional meaning to My Expressions; exact duplicates reuse the existing expression |
| `search_expressions` | Search expressions in the current conversation; returned text is bounded |
| `start_practice` | Open an existing saved expression from this conversation |
| `play_audio` | Replay audio by message ID or expression ID (reference audio) |
| `pause_audio` | Pause existing playback (external only) |
| `resume_audio` | Continue paused audio from its current position (external only) |
| `seek_audio` | Jump to seconds within existing audio; clamped to its duration |
| `set_conversation_preferences` | Set reply speed (0.25–1.5) or coaching (`natural`, `gentle`, `direct`) |
| `list_conversations` | List active conversations (external only) |
| `create_conversation` | Create/open a conversation with optional title and instructions; reveal the window (external only) |
| `open_conversation` | Open an active conversation and reveal the window (external only) |
| `set_conversation_instructions` | Set/reset conversation instructions (external only) |

External mutations require `expected_revision` from `get_session` and, where applicable, `conversation_id`. Read the session again after each mutation or a state-change error. Mutations are rejected during recording, generation, modal editing. Read calls remain available. Large results may return fewer items with `has_more`; long text carries `text_truncated`. Archived/deleted messages, credentials, arbitrary files, message deletion, and microphone control are not exposed. Tool text and instructions are sent to the connected model as needed; the bridge itself remains local.

A tool result reports `ok`, `revision`, and relevant IDs. `scheduled_after_reply` means the voice model’s requested view/playback change will occur after its reply; cancellation discards pending navigation. The active conversation, activity, and modal state are checked again before a deferred action runs. Only one view/playback change can be scheduled per voice reply; additional changes return an error. A tool never returns a pronunciation grade from the pitch curve.

## Protocol and limits

The helper supports MCP `2025-06-18`, `2025-03-26`, and `2024-11-05` initialization, tools discovery/calls, and ping. It negotiates a supported legacy revision if a client requests a newer version. It does not implement the newer stateless protocol. Output is newline JSON-RPC only. The bridge permits up to eight concurrent local connections, five-second socket timeouts, 256 KiB frames, and a bounded 128-request replay cache. Realtime permits up to eight tool rounds with up to eight calls per round. Voice read results are capped at 10 items and approximately 6 KiB, with an 8 KiB per-result and 20 KiB aggregate output budget. Mutations completed during a failed voice reply are remembered for retries of that user message, using a bounded 128-action cache. The legacy MCP lifecycle requires the `notifications/initialized` notification before tools calls.

While control is enabled, Mochi checks the socket on activation and every 30 seconds, rebuilding it if the endpoint disappears. Turning control off does not stop an assistant process; subsequent calls fail until control is enabled again. No API key or authentication token is included in MCP configuration or tool results.
