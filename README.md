# i don't type

i don't type is a small native macOS speech-to-text utility for private dictation in any app. It runs as a menu bar app with a movable floating bubble, local history, Local Whisper, and Apple Speech fallback, then pastes text back where your cursor started.

## Build

```bash
./build.sh
```

The app bundle is written to:

```text
.build/i don't type.app
```

The same build also writes a local download package for the static landing page:

```text
site/downloads/IDontType-0.1.0.zip
site/downloads/IDontType-0.1.0.dmg
```

By default, `./build.sh` uses the best available signing identity:

- `Developer ID Application` when installed.
- `Apple Development` when installed.
- Ad-hoc signing only as a local fallback.

For a real distributable build, install a Developer ID Application certificate, then run:

```bash
SIGN_MODE=developer-id ./build.sh
```

To notarize after signing, first store Apple notary credentials:

```bash
xcrun notarytool store-credentials idonttype-notary
```

Then build and notarize:

```bash
SIGN_MODE=developer-id NOTARY_PROFILE=idonttype-notary ./build.sh
```

If the Developer ID certificate is missing, `SIGN_MODE=developer-id` fails instead of silently producing an ad-hoc build.

## Run

```bash
open .build/i don't type.app
```

macOS will ask for microphone and Speech Recognition access the first time you dictate. For reliable automatic paste and selected-text rewrite, grant Accessibility access in System Settings when prompted. i don't type can use Local Whisper for private local transcription and Apple Speech as a fallback when available.

## Controls

- Click the floating bubble to start dictation.
- Click it again, or use the menu bar item, to stop and paste.
- Drag the bubble to move it anywhere on screen. Its position is saved.
- Hold `Fn` for push-to-talk, then release to stop and paste.
- Double-tap `Fn` to latch dictation on, then click the bubble or press `Fn` again to stop and paste.
- Press `Escape` during dictation to cancel.
- Configure hold-to-record and press-to-toggle triggers from Home.
- Select text and press `Opt+2/3/4/5` to repolish it as professional, casual, list, or clean text.
- Say `press enter` at the end of a dictation to paste and send.
- Say `cancel that` to discard the current dictation.
- Open Home to choose model, language, microphone, cleanup, storage, and triggers.

## Features

- Native always-on-top draggable bubble.
- Menu bar controls: Home, show/hide bubble, recent dictations, help, feedback, and quit.
- Home hub with sidebar navigation, searchable history, dictionary hints, model/language/microphone settings, and editable triggers.
- Minimal recording state on the bubble, without showing transcript text on screen.
- Local Whisper transcription with Apple Speech fallback.
- No i don't type account, sync service, hosted transcript history, or stored audio.
- Local cleanup styles: clean, professional, casual, and list.
- App-aware style defaults for Mail, Messages, Slack, and Discord.
- Clipboard fallback when Accessibility access is not available.
- Selected-text repolish shortcuts for quick rewrites without opening the Hub.
- Conservative local cleanup for fillers, adjacent repetition, spoken punctuation, and explicit correction phrases like "take that back" or "I didn't mean".
