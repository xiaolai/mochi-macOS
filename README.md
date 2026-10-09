# Mochi

Version **0.1.2**.

A native macOS conversation app with Mochi. Find the English for a thought, hear it in your own voice, practise locally, and return to the conversation to say it yourself.

## Install with Homebrew

```sh
brew install --cask xiaolai/tap/mochi
```

Requires Apple Silicon and macOS 14 or later. Use the fully qualified cask name: Homebrew’s unrelated `mochi` cask is a flashcard app and installs the same `Mochi.app` filename. They cannot be installed together under that filename; remove the unrelated cask first if it is installed. Update with `brew upgrade --cask xiaolai/tap/mochi`.

## Run

Requires macOS 14 or later and a Swift 5.9+ toolchain (built here with Swift 6.4).

```sh
swift test
./scripts/build-app.sh
open "build/Mochi.app"
```

The local development app is ad-hoc signed; it is not a notarized distribution build. Public release DMGs use Developer ID signing, hardened runtime, and stapled Apple notarization tickets. There are no third-party runtime dependencies. The app uses SwiftUI, AppKit, AVFoundation, Security and Foundation.

## Use

1. Open Settings (⌘,) and configure OpenAI API-key access or explicitly select an existing Codex sign-in. Check connection verifies a real text response. No automatic provider fallback occurs.
2. In Settings → Voices, choose Mochi’s conversation voice and a separate practice example voice. New users start with built-in Marin; all ten Realtime voices have a common-sentence preview. For personal examples, connect your ElevenLabs account and choose Set Up My Voice. Record/import 60–180 seconds of your voice or select an existing account clone, choose Jake/Grant pronunciation, consent to upload, compare and accept. No voice ID entry is required. Keys stay in Keychain; voice profiles stay in local preferences.
3. Type a message or click the microphone to start a voice conversation. Once microphone permission is granted, Mochi opens with one of six brief greetings, avoiding the last three choices, then starts recording. Click the microphone during the greeting to skip it, and Finish Recording to send your voice message. Each conversation remembers its introduction across relaunches; replaying a greeting never starts recording. Recording stops at 60 seconds. No microphone opens at launch. While recording, you can address Mochi by name; idle wake-word listening is not enabled.
4. Choose Help Me Say This beside the microphone in the input area (⇧⌘H). An unfinished composer draft seeds the first thought; unfinished help drafts survive dismissing and relaunching. Type the intended meaning, or Record Thought → Finish & Review. Recording stays local until you choose Transcribe. If typed text already exists, review recognized words and choose Add to thought, Replace thought, or Keep typed thought. Then Find the English. The next screen keeps your original thought visible beside editable English; Try another wording offers an alternative, while unclear meaning returns a clarification question. Return immediately or choose Listen & Practise. Returning with English saves the expression to My Expressions and completes the Help draft, so the next Help session can use a new composer thought. Its thought recording is removed unless another item still references it. Closing the window keeps an unfinished draft, including its recognized-word review. Practising a saved expression preserves any separate unfinished draft. Discarding or replacing a thought recording removes the old file only when nothing else references it. Detailed voice options and the unscored pitch chart are expandable. You can also review an English sentence directly.
5. Create Example uses the selected built-in voice or performer TTS followed by conversion to your own timbre. Built-in examples are accepted only when the returned transcript matches the displayed sentence. Import audio supports an existing reference without an API call. Saved examples retain their voice label; settings changes affect new examples, and Regenerate Example explicitly replaces the current reference. There is no silent provider/voice fallback.
6. Listen, record a local attempt, and compare the pitch contours. Playback can slow to 0.8×. Save the expression or return to the chat with Resume Conversation. Practising does not submit the sentence to the chat.

The interface uses a system sidebar and unified toolbar, a focused practice sheet, and a separate tabbed Settings window.

Voice messages have playback inside the speech bubble: play/pause, elapsed and total time, and a slider you can click or drag to jump. Pausing preserves your position; playing another recording switches playback. Transcript editing, recovery and revealing the recording are in the message menu.

Voice recordings show elapsed time and an input-level meter. Very quiet input produces a warning, not a claim that speech is absent. If a transcript fails or times out, the original recording remains playable. Each voice message offers Retry transcription and Add text/Edit transcript; recovery updates that message without generating another reply. Saved-recording transcription uses Realtime with the selected connection and model, including Codex sign-in, without requesting an assistant reply or switching credentials. A retry is a new OpenAI transcription request and can incur usage. Retry reply uses an available transcript, including manual corrections, without re-transcribing the recording.

Mochi's reply can arrive before its input transcript. The app delivers the reply immediately, then gives transcription a bounded 30-second grace period. Opening Help or My Expressions keeps background transcription running. Stop/conversation navigation/close cancel remaining work; interrupted recordings remain recoverable after relaunch. UI status labels are stored separately and never sent as the user's words in future conversation context.

Closing the main window (red close button or ⌘W) stops conversation audio and requests, saves your conversation, and keeps Mochi running in the menu bar. ⌘Q also cancels voice setup, hides settings windows, and removes the Dock icon. Left-click the outline-only Mochi tray icon to restore the workspace and Dock icon; right-click or Control-click opens the menu. Use Quit Mochi Completely in the app or tray menu to exit. Settings shows the app version and build on every tab. Other open windows and non-voice-setup sheets are retained when hiding and restored when reopening.

Workspace title-bar controls are fixed to icons with hover tooltips; toolbar display-mode choices, the Mochi name/artwork, and the horizontal title-bar separator are omitted. Conversation actions are on sidebar rows; Help Me Say This is beside the microphone. Search is at the far right of the title bar.

Routine conversation confirmations appear in a small floating notice at the upper right and dismiss automatically after four seconds, with an explicit dismiss button. They do not move the composer. Help-step guidance and errors remain until the relevant action or dismissal.

The title-bar Stop button appears only during generation. Recording uses the microphone control, and voice-message playback uses the bubble's play/pause control. Escape remains available to stop work when conversation search is closed.

Practice pitch charts default to light display smoothing with shape-preserving cubic curves. Voiceless gaps remain empty. Turn off Smooth curves to inspect the original pitch samples; this changes only the chart, not the analysis or audio.

Mochi's artwork remains on the welcome screen. My expressions keeps reference audio, attempts and a link to the originating conversation.

## Data and boundaries

- Library and audio: `~/Library/Application Support/Mochi/`. Writes are atomic; corrupt or newer-version libraries are not overwritten.
- Keys: macOS Keychain under `com.lixiaolai.mochi-macos`. Launch environment variables `OPENAI_API_KEY` and `ELEVENLABS_API_KEY` are supported when no saved key exists. `MOCHI_CLONE_VOICE_ID` sets a local clone preference. Never put credentials in this repository.
- Help drafts, English suggestions, thought recordings, and transcript states are additive fields in library v2. Before the first save using these fields, an existing library is preserved byte-for-byte as `library-before-help-transcription.json`. Older builds can read v2 but may discard these new fields when rewriting; quit Mochi and restore the preserved JSON for a rollback. Library backups include recorded thoughts and remap their filenames on import.
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

Use the sidebar to browse Conversations, Archived, and Recently Deleted. Each conversation has an actions dropdown to rename, pin, archive, move to Recently Deleted, recover, or export it; right-click is also supported. Sidebar search (⇧⌘F) matches titles and message text and includes archived conversations. The collapsible title-bar search (⌘F) searches only the current conversation; use Enter/⌘G for the next match and Shift-Enter/⇧⌘G for the previous match. Escape or Close Search collapses it. While a conversation search is active, new messages do not scroll away from the selected result; close search to return to the latest messages. Drafts and selected conversation are saved locally.

Conversation → Manage Conversations (⇧⌘M) supports selecting several chats with ⌘-click/⇧-click. Deleted chats stay recoverable indefinitely until an explicitly confirmed permanent deletion. Saved expressions and their recordings survive deletion of their source chat. Existing backups and provider-side data are not affected by local deletion.

Conversation → Export Library Backup creates an `.mochilibrary` package with history, drafts, expressions and referenced audio, excluding credentials. Import Library Backup adds missing IDs while keeping local versions of existing IDs. Markdown/JSON transcript exports do not embed audio; JSON includes drafts and metadata. The first v2 save preserves the original v1 JSON as `library-v1-backup.json`.

See [the feature ledger](dev-docs/chat-history-feature-ledger.md) for scope, research, deferred features, and verification boundaries.

### Rebrand compatibility

The project lives at `~/github/xiaolai/myprojects/mochi-macOS`; the native bundle is `build/Mochi.app` (`com.lixiaolai.mochi-macos`). On the first normal launch, Mochi copies the former `Application Support/Enjoy Myself` folder to `Application Support/Mochi`, preserving conversations, drafts, recordings and migration backups. The original is retained; an existing Mochi library is never overwritten; an empty destination folder can be reused, and unrelated files are protected. Invalid or future-version source libraries fail closed.

Connection/model/voice preferences and greeting history are copied from the previous Mochi preferences, then the former Enjoy Myself preferences, only when the new setting is absent. Keychain lookup prefers the new service, then reads `com.xiaolai.mochi-macos`, followed by the older `com.xiaolai.enjoy-myself` entry and attempts to copy it to the new service when a credential is needed. Original keys remain available for rollback. No credential migration or network request occurs just from opening the app.

New backups use `.mochilibrary`; older `.enjoylibrary` packages remain importable. `MOCHI_CLONE_VOICE_ID` and `MOCHI_EVIDENCE_DIR` are the preferred environment variables; their former `ENJOY_` aliases remain accepted. The former app bundle is retained under `build/legacy/` for rollback. Quit Mochi before using the old app; changes in the new data folder are not synced back to the original.

Voice options are in **Settings → Voices**, and the slider button beside the practice voice picker. OpenAI has independent conversation/example speech speeds. ElevenLabs has separate pronunciation and conversion controls (stability, similarity, style and speaker boost), with speed applied to the pronunciation recording. Voice setup previews use the selected options, which are saved when the comparison is accepted. Existing saved examples retain their audio; use Regenerate Example to apply new settings.

## Distribution builds

Use a Developer ID Application identity and a notarization Keychain profile:

```sh
MOCHI_SIGN_ID="Developer ID Application: …" MOCHI_NOTARY_PROFILE="chase-notary" ./scripts/release.sh
```

This runs Swift and release-helper tests, stages `build/release/Mochi.app`, signs with the audio-input entitlement, notarizes and staples the app, then builds, signs, notarizes and staples `Mochi-<version>.dmg`. It verifies Gatekeeper and the app inside the mounted DMG. A saved submission ID allows polling to resume without re-uploading an unchanged archive. Publication is separate: push the reviewed source, upload the verified DMG to a versioned GitHub release, hash the public download, and render `dev-docs/distribution/mochi.rb.in` with that hash into the tap.
