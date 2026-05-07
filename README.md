# Wispry

Wispry is a small native macOS dictation utility inspired by the workflow of Wispr Flow. It runs as a menu bar app with a movable floating bubble that starts and stops dictation.

## Build

```bash
./build.sh
```

The app bundle is written to:

```text
.build/Wispry.app
```

## Run

```bash
open .build/Wispry.app
```

macOS will ask for microphone and speech recognition access the first time you dictate. For automatic paste into other apps, grant Accessibility access in System Settings when prompted.

## Controls

- Click the floating bubble to start dictation.
- Click it again, or use the menu bar item, to stop and paste.
- Drag the bubble to move it anywhere on screen. Its position is saved.
- Hold `Fn` for push-to-talk, then release to stop and paste.
- Double-tap `Fn` to latch dictation on, then click the bubble or press `Escape`.
- Press `Escape` during dictation to cancel.
- Press `Control+Option+Space` to toggle hands-free dictation.
- Configure a mouse side button to emit `F13` to use it as a mouse trigger.
- Select text and press `Option+2/3/4/5` to repolish it as professional, casual, list, or clean text.
- Open Home > Shortcuts to record different keyboard shortcuts for toggle and rewrite actions.
- Say `press enter` at the end of a dictation to paste and send.
- Say `cancel that` to discard the current dictation.

## Features

- Native always-on-top draggable bubble.
- Menu bar controls: Home, check for updates, paste/copy last transcript, shortcuts, microphone, help, feedback, and quit.
- Home hub with sidebar navigation, searchable history, dictionary hints, snippets, style transform, and editable shortcuts.
- Minimal recording state on the bubble, without showing transcript text on screen.
- Apple Speech transcription with personal dictionary context.
- Snippets for reusable voice shortcuts.
- Local cleanup styles: clean, professional, casual, and list.
- App-aware style defaults for Mail, Messages, Slack, Discord, and code editors.
- Clipboard fallback when Accessibility access is not available.
- Selected-text repolish shortcuts for quick rewrites without opening the Hub.
- Local cleanup for fillers, adjacent repetition, and correction phrases like "take that back" or "I didn't mean".
