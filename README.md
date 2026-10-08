# Mochi

A native macOS conversation app with Mochi. Find the English for a thought, hear it in your own voice, practise locally, and return to the conversation to say it yourself.

## Run

Requires macOS 14 or later and a Swift 5.9+ toolchain (built here with Swift 6.4).

```sh
swift test
./scripts/build-app.sh
open "build/Mochi.app"
```

The local development app is ad-hoc signed; it is not a notarized distribution build. There are no third-party runtime dependencies. The app uses SwiftUI, AppKit, AVFoundation, Security and Foundation.

## Use

1. Open Settings (⌘,) and configure OpenAI API-key access or explicitly select an existing Codex sign-in. Check connection verifies a real text response. No automatic provider fallback occurs.
2. In Settings → Voices, choose Mochi’s conversation voice and a separate practice example voice. New users start with built-in Marin; all ten Realtime voices have a common-sentence preview. For personal examples, connect your ElevenLabs account and choose Set Up My Voice. Record/import 60–180 seconds of your voice or select an existing account clone, choose Jake/Grant pronunciation, consent to upload, compare and accept. No voice ID entry is required. Keys stay in Keychain; voice profiles stay in local preferences.
3. Type a message or click Speak, then Finish to send a voice message. Recording stops at 60 seconds. No microphone opens at launch.
4. Choose Help Me Say This in the window toolbar (⇧⌘H). Type the intended meaning or explicitly record a thought for translation. The English suggestion is text-only and editable. You can also enter an English sentence directly.
5. Create Example uses the selected built-in voice or performer TTS followed by conversion to your own timbre. Built-in examples are accepted only when the returned transcript matches the displayed sentence. Import audio supports an existing reference without an API call. Saved examples retain their voice label; settings changes affect new examples, and Regenerate Example explicitly replaces the current reference. There is no silent provider/voice fallback.
6. Listen, record a local attempt, and compare the pitch contours. Playback can slow to 0.8×. Save the expression or return to the chat with Resume Conversation. Practising does not submit the sentence to the chat.

The interface uses a system sidebar and unified toolbar, a focused practice sheet, and a separate tabbed Settings window.

Closing the main window (red close button or ⌘W) stops active audio and requests, saves your conversation, and keeps Mochi running in the menu bar. Click the halo-free Mochi face → Open Mochi to restore the same window and draft; clicking the Dock icon also restores it. Use Quit Mochi or ⌘Q to exit.

Mochi animates while speaking; her speaking animation is not used during your own-voice reference. My expressions keeps reference audio, attempts and a link to the originating conversation.

## Data and boundaries

- Library and audio: `~/Library/Application Support/Mochi/`. Writes are atomic; corrupt or newer-version libraries are not overwritten.
- Keys: macOS Keychain under `com.xiaolai.mochi-macos`. Launch environment variables `OPENAI_API_KEY` and `ELEVENLABS_API_KEY` are supported when no saved key exists. `MOCHI_CLONE_VOICE_ID` sets a local clone preference. Never put credentials in this repository.
- Text, conversation context and explicitly submitted conversational/translation audio go to OpenAI. Practice attempts and pitch extraction remain local. Personal reference synthesis sends text and performer audio to ElevenLabs; clone setup uploads the selected samples only after explicit consent. Built-in examples send their sentence to OpenAI. Voice setup recordings are kept in a private VoiceProfiles directory and are excluded from library backups. Provider retention follows the account/provider settings.
- Only the most recent 30 completed chat messages are restored as provider context; the complete local transcript remains saved.
- One audio owner at a time. Stop, navigation and close cancel pending work. Late permission results and stale completions cannot restart a previous operation. There is no automatic retry loop.

## First-release limits

Voice turns use tap-to-record / tap-to-finish. Realtime audio is buffered before playback; this is not continuous hands-free conversation. Each request opens a fresh session, which simplifies drill isolation but adds latency. Transcription failure is labeled; retained audio remains replayable.

Pitch uses normalized autocorrelation with voiced gaps and optional median centering. The graph uses elapsed time, not word alignment. It is **unscored**: no overall pronunciation grade, segmental accuracy claim, or validated learning-outcome claim. Existing attempts are retained; the latest attempt is displayed.

Audible quality, actual microphone permission/capture on the user's device, and learning usefulness need hands-on acceptance. Automated verification never records the microphone or plays audio.

## Verification

```sh
# Tests
swift test

# Silent native UI smoke (isolated fixture library; explicit preview labels)
MOCHI_EVIDENCE_DIR="$PWD/build/evidence" \
  "build/Mochi.app/Contents/MacOS/Mochi" --smoke-test

# Explicit live text/audio provider probe; consumes API usage, never plays audio
MOCHI_EVIDENCE_DIR="$PWD/build/evidence" \
  "build/Mochi.app/Contents/MacOS/Mochi" --probe
```

`--preview` opens the illustrative design fixture. `--import-environment` is a one-time local setup option that saves the two provider keys from the process environment into Keychain. Normal launches do not import credentials or contact providers.

Implementation plan: [dev-docs/codex-plans/20261008-1000-native-app.md](dev-docs/codex-plans/20261008-1000-native-app.md). Evidence and remaining acceptance: [dev-docs/verification.md](dev-docs/verification.md).

## Provenance

Mochi sprite atlas and icon come from [xiaolai/mochi](https://github.com/xiaolai/mochi), reused with the owner's authorization. The character license is bundled with the app. The native UI takes its layout direction from the user's COMES project. The voice boundary follows the decisions in Checkmate's voice-coach plan, implemented here in native Swift.

API references consulted and live-tested: [OpenAI Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations), [WebSocket transport](https://developers.openai.com/api/docs/guides/realtime-websocket), [ElevenLabs TTS](https://elevenlabs.io/docs/api-reference/text-to-speech/convert), [ElevenLabs speech-to-speech](https://elevenlabs.io/docs/api-reference/speech-to-speech/convert).

### Managing history

Use the sidebar to browse Conversations, Archived, and Recently Deleted. Right-click a conversation to rename, pin, archive, move to Recently Deleted, recover, or export it. Search (⌘F) matches titles and message text; normal search includes archived conversations. Drafts and selected conversation are saved locally.

Conversation → Manage Conversations (⇧⌘M) supports selecting several chats with ⌘-click/⇧-click. Deleted chats stay recoverable indefinitely until an explicitly confirmed permanent deletion. Saved expressions and their recordings survive deletion of their source chat. Existing backups and provider-side data are not affected by local deletion.

Conversation → Export Library Backup creates an `.mochilibrary` package with history, drafts, expressions and referenced audio, excluding credentials. Import Library Backup adds missing IDs while keeping local versions of existing IDs. Markdown/JSON transcript exports do not embed audio; JSON includes drafts and metadata. The first v2 save preserves the original v1 JSON as `library-v1-backup.json`.

See [the feature ledger](dev-docs/chat-history-feature-ledger.md) for scope, research, deferred features, and verification boundaries.

### Rebrand compatibility

The project lives at `~/github/xiaolai/myprojects/mochi-macOS`; the native bundle is `build/Mochi.app` (`com.xiaolai.mochi-macos`). On the first normal launch, Mochi copies the former `Application Support/Enjoy Myself` folder to `Application Support/Mochi`, preserving conversations, drafts, recordings and migration backups. The original is retained; an existing Mochi library is never overwritten; an empty destination folder can be reused, and unrelated files are protected. Invalid or future-version source libraries fail closed.

Connection/model/voice preferences are copied only when the new setting is absent. Keychain lookup prefers the new service, then reads the old `com.xiaolai.enjoy-myself` entry and attempts to copy it to the new service when a credential is needed. Original keys remain available for rollback. No credential migration or network request occurs just from opening the app.

New backups use `.mochilibrary`; older `.enjoylibrary` packages remain importable. `MOCHI_CLONE_VOICE_ID` and `MOCHI_EVIDENCE_DIR` are the preferred environment variables; their former `ENJOY_` aliases remain accepted. The former app bundle is retained under `build/legacy/` for rollback. Quit Mochi before using the old app; changes in the new data folder are not synced back to the original.

Voice options are in **Settings → Voices**, and the slider button beside the practice voice picker. OpenAI has independent conversation/example speech speeds. ElevenLabs has separate pronunciation and conversion controls (stability, similarity, style and speaker boost), with speed applied to the pronunciation recording. Voice setup previews use the selected options, which are saved when the comparison is accepted. Existing saved examples retain their audio; use Regenerate Example to apply new settings.
