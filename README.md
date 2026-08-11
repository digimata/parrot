# Parrot

Fast, private voice-to-text for Apple Silicon Macs. Press one shortcut, speak naturally, and Parrot inserts the transcript where you started.

Audio and transcription stay on your Mac. There is no account, subscription, or cloud API.

## Install

Open Terminal, paste this entire line, and press Return:

```sh
curl -fsSL https://github.com/willmather95/parrot/releases/latest/download/install.sh | bash
```

The installer walks you through the two macOS permission prompts, downloads the local speech model, verifies your microphone, and starts Parrot automatically whenever you log in.

It also sets the Globe key to "Do Nothing" so macOS does not intercept Parrot's shortcut. You can change that later in System Settings > Keyboard.

**Requires:** macOS 14 or newer on an Apple Silicon Mac (M1 or newer). The first install downloads the on-device speech model and can take a few minutes.

## Use it

1. Click the text field where you want your words to appear.
2. Press `Control + Fn/Globe` once.
3. Speak. The pill at the bottom of the screen confirms that Parrot is listening.
4. Press `Control + Fn/Globe` again.

Parrot inserts the transcript into the original field. If you switch apps, move focus, or type while it is listening, Parrot copies the transcript to your clipboard instead of risking the wrong destination. Press `Command-V` to paste it.

Parrot will not start in a password or other secure field. If focus moves into one while Parrot is working, it discards that transcript instead of putting it on the clipboard.

## Troubleshooting

Run one check that verifies permissions, the real microphone path, and the selected local model:

```sh
parrot doctor --live-audio --model-ready
```

If macOS permissions were changed after installation, run:

```sh
parrot setup
parrot install --launch-at-login
```

## Useful commands

```sh
parrot doctor                          # check permissions and shortcut settings
parrot models list                     # list available speech models
parrot models download <id>            # download a model before selecting it
parrot --model whisper-large-v3-turbo  # use the larger multilingual model
parrot install --uninstall             # stop launching Parrot at login
```

## What this fork adds

This is a customized fork of [Digimata's original Parrot project](https://github.com/digimata/parrot). Full credit to Digimata for the foundation.

The fork adds:

- A Parakeet model tuned for fast English dictation
- Safer cursor insertion that verifies the original field before typing
- Clipboard fallback when focus changes
- Protection for secure and unobservable fields
- Runtime recovery for microphone route changes and repeated dictation
- A checksum-verified app installer with launch-at-login setup and rollback

The stable `com.digimata.parrot` app identity is intentionally preserved so macOS can retain existing Accessibility and microphone permissions across updates.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```

See [docs/architecture.md](docs/architecture.md) for the design and safety model.

## How the release is verified

The installer downloads the latest GitHub release, verifies its published SHA-256 checksum, checks the app signature and stable identity, and installs `/Applications/Parrot.app`. Updates are staged transactionally. If a running replacement cannot become ready, the installer restores the prior app and service.

## License

Parrot remains available under the original project's [MIT License](LICENSE).
