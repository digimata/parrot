# parrot

A minimal macOS dictation daemon. Toggle recording, speak naturally, and receive on-device transcription at the cursor or on the clipboard.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer verifies the release SHA-256, installs an ad-hoc-signed `/Applications/Parrot.app` with the stable `com.digimata.parrot` identity, and links its executable at `/usr/local/bin/parrot`. The stable app identity is what lets macOS retain Accessibility and microphone approval across login launches.

If an existing Parrot login service is running, an update restarts it and waits for a fresh ready signal before reporting success. If the replacement cannot become ready, the installer restores the prior app and service.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Press `Control + Fn/Globe` once, then speak.** A persistent pill shows a live waveform while the microphone is hot.
4. **Press the same chord again to stop.** The transcript types itself into the original field. If you started outside a text field, click elsewhere, switch apps, or type while recording, Parrot copies the transcript to the clipboard instead of typing it in the wrong place. Paste it with **Command-V**.

Parrot refuses to start while a password or other secure text field is focused. If focus moves into one during recording or transcription, it discards that transcript instead of writing it to the system clipboard.

That's it. There is no record button, no stop button, no "send". `Control + Fn/Globe` toggles the microphone.

> **Note:** on most modern Macs the `Fn/Globe` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to set it to "Do Nothing."

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + Fn/Globe key setting
parrot doctor --live-audio             # also verify real microphone frames
parrot doctor --model-ready            # also load and verify the selected model
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --no-overlay                    # disable the bottom-of-screen pill
```

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
