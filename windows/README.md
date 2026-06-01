# i don't type for Windows

This folder contains the Windows client. It is intentionally separate from the native macOS Swift app because the Mac build depends on AppKit, Apple Speech, Carbon hotkeys, and Accessibility APIs.

The Windows client uses Electron for the tray, floating bubble, global shortcut, clipboard, and installer packaging. Speech recognition stays local through bundled `whisper.cpp`, `ffmpeg.exe`, and a Whisper model by default. Users can opt into OpenAI cloud transcription from Home when accent handling is better there. Cloud transcription can use the licensed i don't type service or the user's own OpenAI API key encrypted with Windows secure storage.

## Local Windows Build

Run these commands from this folder on Windows:

```powershell
npm ci
npm run prepare-runtime
npm test
npm run dist
```

Artifacts are written to:

```text
windows/dist/
```

The release build creates an NSIS installer, portable executable, and zip package.

## Runtime

`npm run prepare-runtime` downloads:

- `whisper.cpp` Windows x64 binaries.
- `ffmpeg.exe` from `ffmpeg-static`.
- `ggml-base.en.bin` for local English transcription.

The downloaded files live in `windows/runtime/` and are bundled into the installer. They are intentionally ignored by git because they are large generated release assets.

## Release Workflow

The GitHub Actions workflow at `.github/workflows/windows-release.yml` builds the Windows package on `windows-latest` and uploads the contents of `windows/dist/`.

For code signing, add these repository secrets:

```text
WIN_CSC_LINK
WIN_CSC_KEY_PASSWORD
```

`WIN_CSC_LINK` can be a base64-encoded `.pfx` certificate or a secure URL supported by `electron-builder`.

## Current Scope

Included:

- Tray app and non-focusable floating bubble.
- Global `Ctrl+Alt+Space` toggle.
- Local microphone capture.
- Local Whisper transcription and optional OpenAI cloud transcription through the i don't type service or a user-supplied OpenAI API key.
- Clipboard write and Windows paste attempt.
- Offline license key verification.
- Local settings, dictionary hints, snippets, file transcription, and recent history.

Not included yet:

- Fn-key hold-to-talk parity with macOS.
- Windows accessibility insertion fallback.
- In-app auto-updater.
