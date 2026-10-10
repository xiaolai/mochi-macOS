# Mochi

A native macOS companion for English conversation and speaking practice, powered by Codex Audio. Talk naturally, practise everyday scenarios, and reuse conversation setups with your own character names and instructions.

## Install

Requires **Apple Silicon and macOS 14 or later**.

```sh
brew install --cask xiaolai/tap/mochi
```

Or download the signed and notarized DMG from the [latest release](https://github.com/xiaolai/mochi-macOS/releases/latest) and drag Mochi into Applications.

To upgrade an existing Homebrew installation:

```sh
brew update
brew upgrade --cask xiaolai/tap/mochi
```

## Start practising

1. Sign in through Codex on your Mac, then open Mochi.
2. Start a blank conversation with **New Conversation** (⌘N), or choose **New Conversation from Template…** (⇧⌘N).
3. Type a message, or click the microphone to speak and listen to the response.
4. When you get stuck, use **Help Me Say This** to find the English, listen, and practise saying it.

Choose a conversation voice and speaking speed in **Settings → Voices**. You can also set instructions, coaching style, and speech speed for an individual conversation.

Optionally, connect ElevenLabs in **Settings → Voices** to use your own voice for practice examples. Generating new examples uses ElevenLabs credits; replaying saved audio does not. Conversations and transcription continue to use Codex.

## Conversation templates

Mochi 0.4.0 includes six built-in templates:

| Template | Practice |
| --- | --- |
| Restaurant | Ordering meals and asking follow-up questions |
| Hotel check-in | Reservations, arrivals, and requests |
| Job interview | Explaining experience and answering questions |
| Vocabulary recall | Recalling a word list and using words in sentences |
| Pronunciation and shadowing | Listening, recording, and comparing selected sentences |
| Topic discussion | Exploring a topic at your own pace |

Open **New Conversation from Template…**, select a template, and customize its settings before starting. Supply your word list, target sentence, job, or topic when the companion asks for it. Starting a conversation does not start recording or playback.

Use **Manage Templates…** to create your own templates or duplicate a built-in. Each template can store a title, description, character name, instructions, coaching style, and optional speech speed. Built-ins are read-only.

A conversation’s **Save as Template…** action saves its settings for reuse. From the conversation instructions editor, it captures your current unsaved settings as a template draft.

Each new conversation receives a copy of the template settings. Editing or deleting the source template leaves existing conversations intact. Vocabulary and shadowing templates guide practice; they do not provide spaced-repetition scheduling or validated pronunciation scores.

## Name your companion

Open **Conversation Instructions…** and enable **Use a custom character name**. For example, name your companion Loki and give it instructions for the conversation you want to practise.

An explicit character name takes precedence over names in the instructions. Future replies and introductions use it; saved messages keep their recorded speaker names, and changing the name does not regenerate old audio. Leave the custom name unset to use Mochi’s default identity and preserve instruction-based naming.

A character name belongs to one conversation and can be saved in a template. It is separate from the conversation title and the app’s name.

## Connect an external assistant with MCP

1. Keep Mochi running and open **Settings → Automation**.
2. Enable **Allow external assistants to control Mochi**.
3. Click **Copy MCP Configuration** and add it to your assistant’s MCP settings.

A connected LLM can discover templates, create a setup for your learning goal, refine it, and start a conversation from it. Template tools are available only to external assistants; Mochi’s voice tools do not manage templates.

| Tool | Purpose |
| --- | --- |
| `list_conversation_templates` | Discover built-in and user templates |
| `get_conversation_template` | Read instructions, settings, and the template revision |
| `create_conversation_template` | Create a user template |
| `update_conversation_template` | Patch selected settings using `expected_template_revision` |
| `delete_conversation_template` | Delete a user template using `expected_template_revision` |

For example, an assistant can create a template with these arguments:

```json
{
  "title": "Vocabulary with Loki",
  "character_name": "Loki",
  "instructions": "Ask me for a word list. Give one recall prompt at a time, let me answer before offering a hint, and ask me to use the word in a sentence.",
  "coaching": "gentle"
}
```

Template updates preserve omitted fields. Creation requires a title and at least one effective setting: instructions, a character name, coaching, or speech speed. Built-in templates must be duplicated to customize them.

To instantiate a template, read `get_session` and call `create_conversation` with `template_id` and the session’s `revision` as `expected_revision`. Optionally supply `expected_template_revision` to reject a changed source. Template CRUD uses its own revisions and works independently of the open conversation.

External control is off by default. The local connection is restricted to your macOS user; recording always starts with you. A connected assistant can read active conversations and control supported actions, so enable access for assistants you intend to use.

## Data and backups

Conversations, templates, saved expressions, and practice recordings are stored locally. Conversation and transcription requests are processed by Codex; optional ElevenLabs example generation uses ElevenLabs.

Use **Export Library Backup…** to keep a portable copy of your library, and **Import Library Backup…** to restore or merge one.

Version 0.4.0 upgrades the library format to **version 3**. Before replacing an older library, Mochi preserves its original bytes in a private `library-before-character-templates-v3*.json` backup. Keep a full current library export before downgrading. An older app cannot open a v3 library and requires restoration of a compatible backup.

## Build from source

With Xcode’s command-line tools available:

```sh
swift test
python3 -m unittest discover -s scripts/tests
./scripts/build-app.sh
```

The development app and bundled MCP helper are built into `build/Mochi.app`. Distribution signing and notarization use `scripts/release.sh` with your Developer ID and notarytool Keychain profile.
