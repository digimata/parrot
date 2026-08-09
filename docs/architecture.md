# Architecture

## Product contract

Parrot is a local macOS push-to-talk dictation service. Hold Control + Fn/Globe, speak, and release. Transcription runs on-device and the result is inserted only if the original editable control still owns focus. Otherwise, Parrot copies the result to the clipboard.

The supported installation is a stable `/Applications/Parrot.app` bundle with identifier `com.digimata.parrot`. Its bundled executable is also exposed as the `parrot` CLI. A LaunchAgent can run that same executable at login. This stable app identity is required for consistent microphone and Accessibility permissions.

## Runtime shape

```text
Control + Fn/Globe
        |
        v
 HotkeyMonitor ---> AudioCapture ---> Transcriber ---> TextInjector
        |                 |                |                |
        |                 |                |                +--> original field or clipboard
        |                 |                +--> Parakeet or WhisperKit
        |                 +--> fresh AVAudioEngine for each recording
        +--> pointer/keyboard focus-safety signals

 MenuBarController <--- runtime state ---> RecordingOverlay
```

`Run` warms the selected model before starting `NSApplication`. The process uses `.accessory` activation policy, so it has no Dock icon or main window. It does have a menu-bar status item and a click-through recording/transcribing overlay.

## Input and delivery safety

`HotkeyMonitor` uses a listen-only session `CGEventTap`. Dictation begins only when Control and Fn/Globe are both held. It also observes keyboard and mouse interaction while a transcript is pending. If the event tap is disabled, Parrot attempts recovery; a failed recovery exits the daemon so launchd can restart it. A hold watchdog ends any capture that reaches 120 seconds.

At press time, `FocusSnapshot` records the frontmost process and a specific editable Accessibility element. At delivery time, insertion is allowed only when that exact element still owns focus and no intervening pointer or external keyboard interaction was observed. Ambiguous focus fails closed to clipboard. Clipboard fallback leaves the transcript available for paste after a successful copy. If the transcript cannot be copied, it restores every representation from the prior clipboard snapshot.

## Audio lifecycle

`AudioCapture` creates a fresh `AVAudioEngine` and `AVAudioConverter` for every recording. This prevents a login daemon from retaining an input node tied to a stale Core Audio route after sleep, docking, or a microphone switch.

The input format must have a nonzero sample rate and channel count. Input frames are converted to mono 16 kHz Float32 samples. Configuration changes and conversion failures are retained in `CaptureResult` and shown as visible menu-bar errors rather than silently producing an empty transcript.

Temporary WAVs are used only for Parakeet inference, model smoke tests, or an explicit `--dump-wav` debug run. WAV creation is exclusive, rejects symlinks, and starts at mode `0600` in the user's private temporary directory. Normal completion removes inference WAVs; a later startup removes crash-orphaned Parrot WAVs whose creator process is no longer alive.

## Transcription and ordering

The built-in model registry is source-backed. Parakeet TDT 0.6B v2 is the recommended English model; WhisperKit models remain selectable. Model preparation checks available disk and uses a bounded timeout.

Transcriptions are serialized in release order. Each interaction carries a generation number so an older result cannot clear a newer recording, transcribing, or error state. Empty and failed transcriptions surface an error and audible alert.

The local model selection is stored at `~/Library/Application Support/parrot/settings.json`. Missing settings select the recommended model. Corrupt or unreadable settings fail visibly instead of silently changing models.

## UI

`MenuBarController` is the persistent status surface and offers Quit. `RecordingOverlay` is a borderless, click-through `NSWindow` at the bottom of the active screen. Recording and transcribing visibility changes are immediate so fast press/release sequences cannot leave stale UI. Only the waveform uses a short transform-based smoothing transition, and Reduce Motion disables that transition.

## Installation and logs

`parrot setup` requests Accessibility and microphone permission, then fully prepares the selected model. It exits nonzero until all required grants are confirmed.

`parrot install --launch-at-login` requires and verifies the stable app bundle, writes the LaunchAgent atomically, bootstraps it, and requires both launchd's running state and a fresh ready log line. Failures attempt to restore the prior plist and registered state. Uninstall treats launchd as authoritative even if the plist is missing.

LaunchAgent output lives in `~/Library/Logs/Parrot`, with a `0700` directory and `0600` regular files. Public installation verifies the published release checksum and bundle identity. Updating a running installation restarts the registered service and requires its fresh-ready verifier before success; a failed update restores the prior app and service.

## Verification

The release path runs the release build and test suite before packaging. Controlled local acceptance requires:

1. `parrot doctor --live-audio --model-ready`
2. `parrot models smoke parakeet-tdt-0.6b-v2`
3. A fresh LaunchAgent ready line and `state = running`
4. A real Control + Fn/Globe dictation into an editable field
5. A click-away test that copies to the clipboard instead of injecting into the wrong field

## Deliberate limits

- macOS 14+ on Apple Silicon only
- no cloud transcription
- no transcript history or meeting recorder
- no hands-free VAD mode
- no settings window
- no streaming partial transcript
