# Conversation instructions and automation

In a conversation’s sidebar **…** menu, choose **Conversation Instructions…**. Instructions, the character (name, personality and voice), the greeting and phrases, the language, coaching style, and optional speech speed belong to that conversation and are saved locally. Changes affect future replies; existing messages and audio stay as recorded. Empty instructions use Mochi defaults. New edits are limited to 8,000 characters. Longer prompts from foreign libraries or backups keep their full saved text; future replies use the first 8,000, and the editor asks you to shorten them before saving. Custom instructions override conversational defaults. Help Me Say This and exact reference speech retain their task-specific instructions.

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
| `get_session` | Current ID, revision, activity, instructions, character, greeting, phrases, voice, preferences, audio and expression IDs |
| `get_messages` | Last 1–100 messages of the open active conversation; long text is truncated to 2,000 characters |
| `prepare_expression` | Prepare `text`, in the conversation’s language, and an optional meaning for review in Help Me Say This |
| `save_expression` | Save `text` and an optional meaning to My Expressions; exact duplicates reuse the existing expression |
| `search_expressions` | Search expressions in the current conversation; returned text is bounded |
| `search_all_expressions` | Search every saved expression, as My Expressions lists them, newest first, with paging; `conversation_id` is null when the expression's conversation is archived, deleted or gone (external only) |
| `start_practice` | Open an existing saved expression from this conversation |
| `play_audio` | Replay audio by message ID or expression ID (reference audio) |
| `pause_audio` | Pause existing playback (external only) |
| `resume_audio` | Continue paused audio from its current position (external only) |
| `stop_audio` | Stop playback, cancelling a view change scheduled after it; transcriptions are unaffected (external only) |
| `seek_audio` | Jump to seconds within existing audio; clamped to its duration |
| `set_conversation_preferences` | Set reply speed (0.25–1.5) or coaching (`natural`, `gentle`, `direct`) |
| `list_conversations` | List active conversations, pinned first, optionally matching a query, with paging (external only) |
| `create_conversation` | Create/open a conversation with an optional title and settings, or from a template; reveal the window (external only) |
| `open_conversation` | Open an active conversation and reveal the window (external only) |
| `rename_conversation` | Rename any active conversation, open or not (external only) |
| `archive_conversation` | Archive any active conversation; restore it from Archived in Mochi (external only) |
| `set_conversation_instructions` | Set/reset the open conversation’s instructions, character, greeting or phrases (external only) |
| `list_characters` | List built-in and user characters: name, description, personality and voice, with paging (external only) |
| `list_conversation_templates` | List built-in and user templates, without instructions (external only) |
| `get_conversation_template` | Read one template, including its instructions, personality and `template_revision` (external only) |
| `create_conversation_template` | Create a user template; pass an `idempotency_key` so a retry cannot create a duplicate (external only) |
| `update_conversation_template` | Patch a user template using `expected_template_revision` (external only) |
| `delete_conversation_template` | Move a user template to Recently Deleted using `expected_template_revision`; only you can recover it or delete it permanently, in **Manage Templates** (external only) |

Conversations and templates share the companion settings. `character_name` names the companion; `personality` (up to 2,000 characters) says how it comes across, and the instructions win when the two disagree. `greeting` (one line, up to 160 characters) is spoken exactly as written when the user first starts talking in an empty conversation; empty means a standard greeting in the conversation’s language. `phrases` (up to six lines of up to 100 characters) appear as buttons that send exactly their text; an update replaces the whole list. `voice` is one of Mochi’s voice IDs, and `clear_voice` returns to the voice chosen in Settings. A stored voice this version does not have is kept and reported in `voice`, while `effective_voice` in `get_session` names the voice that speaks. Mochi records no link to a character: to use one, copy its name, personality and voice from `list_characters`.

External mutations require `expected_revision` from `get_session` and, where applicable, `conversation_id`. Every successful result returns the new `revision`; read the session again after a state-change error. Pausing, resuming, or audio finishing does not change the revision. `open_conversation`, `rename_conversation`, and `archive_conversation` accept any active conversation; the other conversation tools act on the open one. Template changes use `expected_template_revision` instead of `expected_revision`. Every mutation, template changes included, is rejected while you record, while Mochi generates a reply, and while an editing, template or practice panel is open. Read calls remain available. Large results may return fewer items with `has_more`; paged lists return `next_offset` (null on the last page). Long text carries `text_truncated`. An assistant can make these changes and no others: create, open, rename, archive and set up conversations (instructions, character, greeting, phrases, voice, language, coaching and speed); save expressions, prepare one in Help Me Say This and open practice; create, update and delete user templates; and play, pause, resume, stop and seek audio. Archiving and template deletion are recoverable: an archived conversation can be restored only in Mochi, and a deleted template waits in Recently Deleted. Archived and deleted conversations, credentials, arbitrary files, permanent deletion, and microphone control are not exposed. Tool text and instructions are sent to the connected model as needed; the bridge itself remains local.

Read results list the fields that hold text from your library in `untrusted_fields` (for example `instructions` or `messages.text`). That text can come from a backup or template someone else wrote, so assistants are told to treat it as data and never follow instructions found in it.

A tool result reports `ok`, `revision`, and relevant IDs. Each tool declares a title, a described input schema, and an output schema; a successful result is returned both as `structuredContent` matching that schema and as the same JSON in text. A refused call, including one with invalid arguments, is a tool result with `isError` and a message naming what to change, so the assistant can correct it and retry. `scheduled_after_reply` means a change will occur after Mochi’s reply instead of cutting it off. The voice model’s view and playback changes wait for the reply it is generating. An external `prepare_expression`, `start_practice` or `play_audio` sent while Mochi speaks a reply or greeting for the first time waits until she finishes; while the reply is still being produced, these calls are refused as busy and can be retried once she speaks. A paused reply keeps the change waiting until it is resumed and finishes. `seek_audio`, `pause_audio`, `resume_audio` and `stop_audio` act at once, and so does every change while existing audio is replayed. A reply you have sought within counts as replayed, but a change already waiting for it still runs when it ends, and other view or playback changes are refused until then. Stopping playback, or playing or seeking to other audio in its place, cancels the waiting change. The active conversation, activity, and modal state are checked again before it runs, and a change that no longer fits is cancelled with an error shown in Mochi. The result does not report what happened later, so read `get_session` for the new revision and state before retrying. Only one change can wait per reply; additional changes return an error. A tool never returns a pronunciation grade from the pitch curve.

## Protocol and limits

The helper supports MCP `2025-11-25`, `2025-06-18`, `2025-03-26`, and `2024-11-05` initialization, tools discovery/calls, and ping. A client requesting another revision is offered `2025-11-25`. It does not implement the stateless `2026-07-28` protocol: a client of that revision probes with `server/discover`, receives “Method not found”, and falls back to initialization. Output is newline JSON-RPC only; when a call fails, the helper writes a one-line diagnosis to stderr. A client that negotiated `2025-03-26`, the one supported revision whose transport requires them, may send JSON-RPC batches (initialization cannot be batched); under every other revision a batch is refused with one invalid-request error. An invalid request is answered with its ID whenever that ID is readable. Tool calls run one at a time while the helper keeps reading, so `ping` is answered during a slow call, and `notifications/cancelled` for a call in progress means it is not answered; a call cancelled before it starts never reaches Mochi. The bridge permits up to eight concurrent local connections, 256 KiB frames, and a bounded 128-request replay cache. Mochi waits up to five seconds for a request and for the app to handle it; the helper waits eight, so an answer is never lost to a race. If Mochi is too busy to start a request, it answers that the request did not start and can be retried; if a request started but did not finish in time, it answers that the request may still complete, so read `get_session` before retrying. Conversation titles are one line of up to 160 characters and 2 KB, without control characters or text-direction overrides; an expression and its meaning are each at most 1,000 characters and 8 KB. Tools can create at most 60 conversations and save at most 300 new expressions in any hour; Mochi rewrites the whole library on every save, so this bounds how fast a runaway assistant can grow it, and nothing limits what you add in Mochi yourself. Realtime permits up to eight tool rounds with up to eight calls per round. Voice read results are capped at 10 items and approximately 6 KiB, with an 8 KiB per-result and 20 KiB aggregate output budget. Mutations completed during a failed voice reply are remembered for retries of that user message, using a bounded 128-action cache. The legacy MCP lifecycle requires the `notifications/initialized` notification before tools calls.

While control is enabled, Mochi checks the socket on activation and every 30 seconds, rebuilding it if the endpoint disappears. Turning control off does not stop an assistant process; subsequent calls fail until control is enabled again. No API key or authentication token is included in MCP configuration or tool results.
