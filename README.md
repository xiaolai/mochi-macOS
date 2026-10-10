# Mochi

A macOS app that turns Codex Audio into your personal English speaking practice partner.

## Install

Requires Apple Silicon and macOS 14 or later.

```sh
brew install --cask xiaolai/tap/mochi
```

## Use

1. Sign in through Codex on your Mac, then open Mochi.
2. Click the microphone, speak, and listen to Mochi’s response.
3. When you get stuck, use **Help Me Say This** to find the English, listen, and practise saying it.

Mochi uses Codex for voice responses and transcription. Choose a built-in voice and speaking speed in Settings.

Optionally, use your own ElevenLabs voice for practice examples in Settings → Voices. New examples use ElevenLabs credits; replaying saved audio does not. Conversations and transcription still use Codex.

Your conversations and practice recordings are saved locally.


Use **New Conversation from Template…** (⇧⌘N) to start scenario practice, vocabulary recall, shadowing, or a topic discussion. Preview and edit the settings before starting. **Manage Templates…** lets you create your own or duplicate a built-in; a conversation's **Save as Template…** action reuses its settings.

In **Conversation Instructions…**, enable a custom character name such as Loki. Explicit names take precedence over naming in instructions. Future replies and introductions use the new name; saved messages and recordings retain their original speaker. Leaving the name unset preserves the default Mochi identity and existing instruction overrides.

Templates are copied into each new conversation, so later template edits or deletion do not change existing chats. Vocabulary and shadowing templates guide practice; they do not provide spaced-repetition scheduling or validated pronunciation scores.

External LLMs can manage templates through the opt-in MCP helper in **Settings → Automation**. Discover `list_conversation_templates`, read with `get_conversation_template`, then create, patch, or delete user templates. Update/delete require the template revision; template management works independently of the current conversation. `create_conversation` accepts `template_id` and the current app revision. Built-ins are read-only. Omitted patch fields remain unchanged, including recovered oversized instructions.

The library now uses version 3. Before upgrading an existing library, Mochi preserves its original bytes in a private `library-before-character-templates-v3*.json` backup. Keep a full current library export before downgrading; an older app requires restoration of a compatible backup and cannot open a v3 library.
