# Architecture

## Product contract

Parrot is a local macOS toggle-to-record dictation service. Press Control + Fn/Globe to start, speak naturally, and press the same chord again to stop. Transcription runs on-device and the result is inserted only if the original editable control still owns focus. Otherwise, Parrot copies the result to the clipboard.

The supported installation is a stable `/Applications/Parrot.app` bundle with identifier `com.digimata.parrot`. Its bundled executable is also exposed as the `parrot` CLI. A LaunchAgent can run that same executable at login. This stable app identity is required for consistent microphone and Accessibility permissions.

## Runtime shape

```text
Control + Fn/Globe toggle
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

`HotkeyMonitor` uses a listen-only session `CGEventTap`. Each rising edge of the Control + Fn/Globe chord emits one toggle request; releasing the keys does not stop recording. It also observes keyboard and mouse interaction while a transcript is pending. A payload-free physical Fn/Globe control press with a live shortcut modifier and the immediate payload-free post-edge duplicate are excluded from focus invalidation; actual typing, navigation, later ordinary key events, or clicking still force clipboard fallback. Focus-invalidating input is recorded directly in the event-tap callback before slower recording and UI work is queued, and delivery yields briefly so an already queued click or keystroke can invalidate the target before text is posted. If the event tap is disabled, Parrot immediately invalidates direct delivery because input was temporarily unobservable, then attempts recovery, checks the real session modifier state, suppresses only a chord that is still physically held, and preserves the current recording state. A failed recovery exits the daemon so launchd can restart it. A ten-minute safety limit prevents an accidental recording from growing without bound, and a two-second rearm window prevents a stop press at the exact limit boundary from reopening the microphone.

At press time, `FocusSnapshot` records only the frontmost process and a specific editable Accessibility element. A secure-text subrole or a true `AXContainsProtectedContent` value aborts before audio capture. An unreadable or malformed Accessibility security state also blocks capture instead of being treated as safe. Parrot checks both signals again at delivery and discards the transcript if focus moved into protected content or its security state became unobservable, so the secret cannot reach the global clipboard. Otherwise, insertion is allowed only when the original element still owns focus and no intervening pointer or real external keyboard interaction was observed. Each recording owns only its current transcript. Parrot never restores a capture-time or prior predicted caret and never retains a prior transcript for continuation. Every inserted transcript supplies its own trailing boundary space, so consecutive captures remain distinct without shared mutable state. Synthetic Unicode events use a private event source, explicitly clear all modifiers, and carry a Parrot marker so the physically held stop chord cannot turn transcript chunks into Control/Fn shortcuts or masquerade as user interaction. Event construction is completed for the whole transcript before any chunk is posted; if construction fails, the raw current transcript falls back to the clipboard. Other ambiguous focus fails closed to clipboard. Clipboard fallback leaves the raw current transcript available for paste after a successful copy. If the transcript cannot be copied, it attempts to restore every representation from the prior clipboard snapshot.

## Audio lifecycle

`AudioCapture` creates a fresh `AVAudioEngine` and `AVAudioConverter` for every recording. This prevents a login daemon from retaining an input node tied to a stale Core Audio route after sleep, docking, or a microphone switch.

The input format must have a nonzero sample rate and channel count. Input frames are converted to mono 16 kHz Float32 samples. Configuration changes and conversion failures are retained in `CaptureResult` and shown as visible menu-bar errors rather than silently producing an empty transcript.

Temporary WAVs are used only for Parakeet inference, model smoke tests, or an explicit `--dump-wav` debug run. WAV creation is exclusive, rejects symlinks, and starts at mode `0600` in the user's private temporary directory. Normal completion removes inference WAVs; a later startup removes crash-orphaned Parrot WAVs whose creator process is no longer alive.

## Transcription and ordering

The built-in model registry is source-backed. Parakeet TDT 0.6B v2 is the recommended English model; WhisperKit models remain selectable. Model preparation checks available disk and uses a bounded timeout.

Transcriptions are serialized in stop order and each live inference is bounded to 180 seconds so one stalled model call cannot block every later result. Each interaction carries a generation number so an older result cannot clear a newer recording, transcribing, or error state. Empty and failed transcriptions surface an error and audible alert; an older failure announces itself without overwriting newer UI state.

The local model selection is stored at `~/Library/Application Support/parrot/settings.json`. Missing settings select the recommended model. Corrupt or unreadable settings fail visibly instead of silently changing models.

## UI

`MenuBarController` is the persistent status surface and offers Quit. `RecordingOverlay` is a borderless, click-through `NSWindow` at the bottom of the active screen. It remains visible for the complete toggled recording, pairs a live waveform with the stop chord, and switches immediately to transcribing. Recording, transcribing, and safety-limit transitions post high-priority accessibility announcements. Only the semantic audio meter uses a short transform-based smoothing transition; Reduce Motion removes the interpolation while retaining live level information.

## Installation and logs

`parrot setup` requests Accessibility and microphone permission, then fully prepares the selected model. It exits nonzero until all required grants are confirmed.

`parrot install --launch-at-login` requires and verifies the stable app bundle, writes the LaunchAgent atomically, bootstraps it, and requires both launchd's running state and a fresh ready log line. Failures attempt to restore the prior plist and registered state. Uninstall treats launchd as authoritative even if the plist is missing.

LaunchAgent output lives in `~/Library/Logs/Parrot`, with a `0700` directory and `0600` regular files. Public installation verifies the published release checksum and bundle identity. Updating a running installation restarts the registered service and requires its fresh-ready verifier before success; a failed update restores the prior app and service.

## Verification

The release path runs the release build and test suite before packaging. Controlled local acceptance requires:

1. `parrot doctor --live-audio --model-ready`
2. `parrot models smoke parakeet-tdt-0.6b-v2`
3. A fresh LaunchAgent ready line and `state = running`
4. A real Control + Fn/Globe start/stop dictation into an editable field
5. Two consecutive captures into the same untouched field that insert two distinct transcripts exactly once
6. A click-away test that copies the raw current transcript to the clipboard instead of injecting into the wrong field

## Deliberate limits

- macOS 14+ on Apple Silicon only
- no cloud transcription
- no transcript history or meeting recorder
- no hands-free VAD mode
- no settings window
- no streaming partial transcript
