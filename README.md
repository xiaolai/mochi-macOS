# Mochi

A home for voice conversations on your Mac, running on your ChatGPT subscription.

Mochi uses the ChatGPT sign-in you already have in Codex. It gives voice conversations a window and a history of their own, so you can talk while ChatGPT and Codex stay free for your work, and your conversations stay in one place, apart from your work threads.

## Why Mochi

- **Its own window.** Talk to Mochi while your other apps stay as they were. Desktop Mochi sits on your screen, and ⌃⌥⌘M starts a voice message from any app.
- **Its own history.** Every conversation is kept in Mochi, searchable by title, character and message.
- **One setup per conversation.** Each conversation has its own character, voice, instructions, language and speaking speed, so one can be a study partner and another a sounding board.

## What you need

- Apple Silicon and macOS 14 or later
- Codex on your Mac, signed in with ChatGPT. Mochi uses that sign-in; it does not accept an API key.

## Install

```sh
brew install --cask xiaolai/tap/mochi
```

Or download the signed and notarized DMG from the [latest release](https://github.com/xiaolai/mochi-macOS/releases/latest) and drag Mochi into Applications.

To upgrade an existing Homebrew installation:

```sh
brew update
brew upgrade --cask xiaolai/tap/mochi
```

## Get started

1. Sign in to Codex with ChatGPT, then open Mochi.
2. In **Settings → General**, tell Mochi your name if you'd like her to use it, and choose the language new conversations start in: **Match Me** to talk in whatever language you speak, or a language you want to practise.
3. Start a blank conversation with **New Conversation** (⌘N), or choose **New Conversation from Template…** (⇧⌘N).
4. Type a message, or click the microphone to speak and listen to the reply.

## What you can use it for

Anything you would rather say than type. Out of the box, Mochi is a warm conversation companion that keeps replies short and leaves you room to think. Built-in [templates](#templates) set her up for things like these, in whatever language you speak:

- brainstorming, or thinking a messy idea through out loud
- rehearsing a difficult talk, a pitch or a request, with Mochi playing the other person
- making up a story together, or interviewing a character you are writing
- explaining a topic to a curious beginner to find the gaps in your understanding
- revisiting a memory and keeping it as a short vignette

Or give a conversation your own instructions and character, and save the setup as a template to start the next one from it.

**Language practice** is the use Mochi is best equipped for. Choose a language to practise, and Mochi speaks only that language, corrects you in the coaching style you pick, and helps you find words when you get stuck. See [Language practice](#language-practice).

## Conversations and characters

Every conversation keeps its own history, settings and character. Open **Conversation Instructions…** from a conversation's **…** menu to change its settings, which come in three groups:

- **Character**: who the companion is. A name, a personality and a voice.
- **What you do together**: instructions, a greeting and phrases.
- **Language**: the conversation's language, coaching style and speech speed. See [Language practice](#language-practice).

Changes apply to future replies; existing messages and audio stay as recorded.

**Characters.** Mochi comes with three: Mochi, warm and thoughtful; Alex, curious and direct; and Pip, playful and imaginative. **Manage Characters…**, in the File menu and in the arrow menu beside **New Conversation** in the toolbar, lists them, starts a conversation with one, and creates, edits and deletes your own; duplicate a built-in to customize it. In **Conversation Instructions…** or a template, **Choose Character** copies a character's name, personality and voice into the settings, and **Save as Character…** keeps the companion you set up as a new character. Choosing copies, so editing or deleting a character later changes no conversation or template.

**Personality** is how the companion comes across: temperament, manner, what it enjoys. The instructions say what you do together, and win when the two disagree, including any limits on what the companion may make up.

**Voice.** A conversation speaks in its own voice, or else in the conversation voice from **Settings → Voices**. Its greeting and replies use that voice; practice examples keep the example voice from Settings. A voice this version of Mochi doesn't have, from a newer version or someone else's backup, is kept, and the Settings voice speaks instead.

**Greeting.** When you start a voice message in an empty conversation, the companion first says a short greeting: the conversation's own greeting, exactly as written, or otherwise a standard greeting in the conversation's language. Typing first skips it. A greeting is one line of up to 160 characters. Mochi checks that the voice said it word for word; if it didn't, Mochi asks you to try again, and a shorter greeting is easier to say exactly.

**Phrases.** Up to six one-line phrases, of up to 100 characters each, appear as buttons above the message field. Clicking one sends exactly that text as your message and leaves whatever you were typing in place. You can also type or say them.

**Start Again.** In a role-play, such as a job interview or a conversation you are rehearsing, **Start Again** (above the message field, or in the **Conversation** menu for any conversation) asks to redo it from the beginning. Mochi first says in one sentence what she will redo and waits for you to confirm or correct it. In a long conversation the request still includes how it began, so the scenario you set up at the start isn't lost.

**Your name.** Set it in **Settings → General**. Mochi uses it occasionally to address you; leave it empty and she uses no name.

**The character's name.** Without a name of its own, the companion is Mochi, and instructions can still give it another name in conversation. A name set in the Character group takes precedence over names in the instructions. Saved messages keep their original speaker names, and changing the name does not regenerate old audio.

**Finding conversations.** The button above the conversation list sorts it by recent activity, date created, title or character name, and shows only the conversations with one character. Search matches titles, character names and messages.

## Language practice

Every conversation has a language:

- **A language to practise** — English, Chinese, Japanese, Korean, Spanish, French, German and more. Mochi speaks only that language, corrects it if you choose a coaching style, and Help Me Say This finds words in it.
- **Match Me** — Mochi replies in whatever language you speak and switches when you do. There is nothing to practise, so there are no corrections and no Help Me Say This.

**Coaching.** *Natural* discusses what you say without correcting it, *gentle* now and then works the right form into its reply, and *direct* briefly corrects significant errors. Gentle and direct correct at most one thing per reply, leave accent and casual speech alone, ask when they aren't sure what you said, and stop correcting if you or the conversation's instructions ask them to.

**Help Me Say This** (⇧⌘H). When you get stuck, describe your thought in any language, get the words in the conversation's language, listen to them, and practise saying them in your own voice. Save the result to **My Expressions** to practise it again later. Saved expressions remember their language, so practising one continues in it.

**What Mochi caught** (English, macOS 26 or later). After each practice attempt, Apple's speech recognition on your Mac checks which words of the sentence it heard: heard, heard as another word, not caught, or unclear, plus anything extra it heard. It is a hint, not a score: it also misses some words said well. The first check asks before downloading Apple's English speech model, if your Mac doesn't have it yet. Recordings checked this way stay on your Mac.

**Review.** Saved expressions come back for spoken review: the day after you save one, then after 2, 4, 8, 16 and 32 days as you keep getting it right. **My Expressions → Start Review** shows each due expression's meaning with its words hidden. Say it, recording it if you like, then reveal it, listen to the example, and grade yourself: *Again* starts it over and brings it back once more in the same review, *Hard* keeps its gap, *Good* lengthens it. Expressions saved before review existed are due straight away.

New conversations start in the default language from **Settings → General**; changing it leaves existing conversations and templates as they are. Conversations from earlier versions of Mochi are English.

Without a greeting of its own, a conversation opens with a standard greeting in its language. A Match Me conversation hasn't heard you yet, so it greets you in the language of Mochi's interface.

## Templates

A template saves a conversation setup for reuse: a title and description, a character (name, personality and voice), instructions, a greeting and phrases, a language, a coaching style, and an optional speech speed. Use it for whatever you set up more than once.

- **New Conversation from Template…** starts a conversation from a template, after you adjust its settings if you like. Starting a conversation does not start recording or playback; until you say something, the conversation shows what the template is for.
- **Save as Template…** in a conversation's **…** menu saves that conversation's settings.
- **Manage Templates…** creates, edits and deletes your templates, and duplicates a built-in to customize it. Built-ins are read-only.

Each new conversation receives a copy of the template settings, so editing or deleting the source template leaves existing conversations intact.

Mochi includes thirteen built-in templates in two groups.

**Talk about anything.** These follow the language you speak and never correct it:

| Template | What you do together |
| --- | --- |
| Brainstorm with me | Generate lots of ideas, then choose the best |
| Think out loud | Talk through a messy thought until it becomes clear |
| Rehearse a conversation | Practise a difficult talk, pitch or request, with Mochi playing the other person, then get feedback |
| Make a story with me | Build a story together, one turn at a time |
| Interview my character | Answer as a character you are writing while Mochi interviews them |
| Learn by teaching | Explain a topic to a curious beginner to find the gaps |
| Remember a moment | Revisit a memory and keep it as a short vignette |

Ask Mochi to wrap up, sum up or finish whenever you like, and she closes with something short to keep: a recap, feedback, an ending, a character sketch or a vignette.

Each of these opens with its own greeting and offers three phrases, such as *Give me wilder ideas.* or *Add a twist.* They take the language of Mochi's interface when you start the conversation, and from then on they are the conversation's own text. If you change a built-in's language so that the conversation would be greeted in another language, it opens with the standard greeting in that language instead.

**Practise a language.** These are set to English; change the language before starting to practise another:

| Template | Practice |
| --- | --- |
| Restaurant | Ordering meals and asking follow-up questions |
| Hotel check-in | Reservations, arrivals, and requests |
| Job interview | Explaining experience and answering questions |
| Vocabulary recall | Recalling a word list and using words in sentences |
| Pronunciation and shadowing | Listening, recording, and comparing selected sentences |
| Topic discussion | Exploring a topic at your own pace |

In the practice templates, supply your word list, target sentence, job, or topic when the companion asks for it. The vocabulary and shadowing templates guide practice; they do not provide spaced-repetition scheduling or validated pronunciation scores.

## Desktop Mochi and shortcuts

Turn on **Show Mochi on the desktop** in **Settings → Desktop Mochi**, or press ⌃⌥⌘H. She sits in a small transparent window and follows the conversation: she listens while you record, thinks while a reply is prepared, talks while it plays, and breathes quietly while idle. Click her to start or finish a voice message, drag her anywhere, and Control-click her for more. Eyes that follow the pointer are an option, off by default; Reduce Motion keeps her still.

Two shortcuts work in every app, with no Accessibility permission:

| Shortcut | Action |
| --- | --- |
| ⌃⌥⌘M | **Talk to Mochi** — press once to start a voice message and again to send it, or hold it while you speak and let go to send |
| ⌃⌥⌘H | **Show or Hide Desktop Mochi** |

Change them in **Settings → General**. Mochi refuses a shortcut that macOS, its own menus or the other action already uses.

## Settings

| Tab | What it holds |
| --- | --- |
| General | Your name, the language for new conversations, the Codex connection, and keyboard shortcuts |
| Voices | The voice and speed of conversations that don't choose their own, and the voice of practice examples |
| Desktop Mochi | Showing Mochi on the desktop, and whether her eyes follow the pointer |
| Automation | Control by external assistants over MCP |
| Data & Privacy | Backups, the data folder, and what is sent where |

Mochi's menus, buttons and messages are available in English, Simplified Chinese, Traditional Chinese, Japanese and Korean, following your Mac's language. To choose a language for Mochi alone, open **System Settings → General → Language & Region → Applications**. The interface language is separate from the language of your conversations.

## Connect an external assistant with MCP

1. Keep Mochi running and open **Settings → Automation**.
2. Enable **Allow external assistants to control Mochi**.
3. Click **Copy MCP Configuration** and add it to your assistant's MCP settings.

A connected assistant can read the open conversation, list, open, rename and archive conversations, save and search expressions, control playback, list characters, and manage templates. For example, it can discover templates, create a setup for your goal, refine it, and start a conversation from it. Template tools are available only to external assistants; Mochi's voice tools do not manage templates. The full tool list and protocol details are in [docs/automation.md](docs/automation.md).

| Tool | Purpose |
| --- | --- |
| `list_characters` | Discover built-in and user characters to copy into a setup |
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
  "personality": "Dry, patient and quietly funny.",
  "instructions": "Ask me for a word list. Give one recall prompt at a time, let me answer before offering a hint, and ask me to use the word in a sentence.",
  "greeting": "今日はどの単語を練習しましょうか？",
  "phrases": ["ヒントをください。", "次の単語にしましょう。"],
  "voice": "cedar",
  "language": "ja",
  "coaching": "gentle"
}
```

`language` is a language code such as `en`, `zh`, `ja` or `es`, or `match` to reply in the user's language. Conversations, templates and `set_conversation_preferences` accept it, and `get_session` reports it.

`voice` is one of Mochi's voices, such as `marin`, `cedar` or `coral`; `clear_voice` returns a conversation or template to the Settings voice. A greeting is spoken exactly as written, so write it in the language the conversation will be held in. `phrases` replaces the whole list. To use one of your characters, an assistant copies its name, personality and voice from `list_characters`.

Template updates preserve omitted fields. Creation requires a title and at least one effective setting: instructions, a character, a greeting, phrases, a language, coaching, a voice or speech speed. Built-in templates must be duplicated to customize them.

To instantiate a template, read `get_session` and call `create_conversation` with `template_id` and the session's `revision` as `expected_revision`. Optionally supply `expected_template_revision` to reject a changed source. Template CRUD uses its own revisions and works independently of the open conversation.

External control is off by default. The local connection is restricted to your macOS user; recording always starts with you. A connected assistant can read active conversations and control supported actions, so enable access for assistants you intend to use.

## Data and backups

Conversations, characters, templates, saved expressions, and practice recordings are stored locally. Conversation, transcription, and example-voice requests are processed by Codex. Practice attempts are checked on your Mac by Apple's speech recognition and are not sent anywhere for it.

Use **Export Library Backup…** to keep a portable copy of your library, and **Import Library Backup…** to restore or merge one.

Each save keeps the library as it was just before as `library.previous.json` in the data folder. If the library ever cannot be opened, **Settings → Data & Privacy** offers **Restore Earlier Copy**, which reinstates that copy and keeps the unreadable file beside it.

The library format is **version 5**, which adds review state for saved expressions, how each voice message was transcribed, and the transcriber's confidence in each unedited transcript. Before upgrading an older library, Mochi preserves its original bytes in a private backup in the data folder: `library-before-review-v5*.json` for a version 4 library, `library-before-character-library-v4*.json` for a version 3 library, and `library-before-character-templates-v3*.json` for a library from before Mochi 0.4.0. Mochi 0.8.0 and earlier cannot open a version 5 library or import a version 5 backup, and Mochi 0.7.1 and earlier cannot open version 4. To go back to one of them, quit Mochi and put a backup in place of `library.json` in the data folder: `library-before-review-v5.json` if your library was upgraded from version 4, `library-before-character-library-v4.json` if it was upgraded from version 3, or `library-before-character-templates-v3.json` if it was upgraded straight from an older version. Anything changed since the upgrade exists only in the upgraded library. Mochi 0.6.4 and earlier open every conversation as English and drop a conversation's language when they save it.

Practice examples you saved with ElevenLabs before Mochi moved to Codex voices keep playing. A previously saved ElevenLabs key stays in your Keychain until you delete the `ELEVENLABS_API_KEY` item in Keychain Access.

## Build from source

With Xcode's command-line tools available:

```sh
swift test
python3 -m unittest discover -s scripts/tests
./scripts/build-app.sh
```

The development app and bundled MCP helper are built into `build/Mochi.app`. The release number lives only in `VERSION`.

The development app's test modes (`--smoke-test`, `--tray-smoke-test`) and `scripts/tests/single_instance_e2e.py --allow-native` launch Mochi, take focus and register test copies with Launch Services. Run them on a separate test Mac, not on a Mac whose Mochi holds your library, and quit Mochi there first. Distribution signing and notarization use `scripts/release.sh` with your Developer ID and notarytool Keychain profile.
