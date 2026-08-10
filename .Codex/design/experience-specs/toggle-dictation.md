# Experience Specification: Toggle Dictation

**Status:** approved
**Owner:** Parrot
**Surface:** Global hotkey, recording overlay, and menu-bar status
**Updated:** 2026-08-09
**Source context:** Existing AppKit and SwiftUI runtime, Parrot architecture, and user request

## 1. Product Moment

- **User:** A Mac user capturing a thought without holding keys while speaking.
- **Immediate job:** Start recording globally, speak for as long as needed, then stop and recover the transcript safely.
- **Product outcome:** Dictation feels dependable enough to become an ambient daily tool.
- **Primary action:** Press Control + Fn/Globe to start; press the same chord again to stop.
- **Costliest likely mistake:** Recording without realizing it, or injecting the transcript into the wrong control.
- **One-second comprehension:** The persistent moving waveform means the microphone is live; the adjacent hint explains how to stop.
- **Emotional target:** Calm certainty.

## 2. Experience Thesis

Recording state is unmistakable, and stopping is effortless.

- **Signature moment:** The waveform responds directly to the speaker's voice while the overlay remains present across applications.
- **Stable task moments:** Hotkey feedback, recording visibility, stop instruction, focus-safe delivery, and errors are immediate and predictable.
- **Peak moment:** The transcript appears at the original cursor or is preserved on the clipboard.
- **End state and next action:** The overlay disappears after delivery; clipboard fallback is paired with an audible alert and is ready for Command-V.
- **Effects that may be removed without harming the experience:** All entry, exit, icon-swap, and text-swap animation. Only audio-reactive waveform motion is essential.

## 3. Information Hierarchy

| Priority | Element or message | User question answered | Required prominence |
| --- | --- | --- | --- |
| 1 | Live waveform | Is Parrot recording me? | Dominant visual signal |
| 2 | Control + Fn/Globe to stop | How do I finish? | Compact, always visible during recording |
| 3 | Transcribing or error status | What is Parrot doing now? | Clear temporary replacement state |

The model name remains ambient in the menu. No secondary control competes with the hotkey.

## 4. Composition and Regions

The click-through overlay remains bottom-center on the display under the pointer at recording start and joins all Spaces. A waveform occupies the leading region; a short stop hint occupies the trailing region. The menu-bar icon remains the persistent secondary status surface. There is no scroll, modal layer, or focus-taking control.

## 5. State and Transition Model

| State | Entry trigger | Visible hierarchy | Available action | System feedback | Exit or recovery |
| --- | --- | --- | --- | --- | --- |
| Idle | Daemon ready or delivery complete | Menu-bar bird and idle instruction | Press toggle chord | None beyond immediate state change | Start recording |
| Recording | First toggle press and successful audio start | Live waveform and stop hint | Press toggle chord again | Waveform follows microphone level; menu icon shows microphone | Stop, ten-minute safety limit, capture error, or daemon exit |
| Transcribing | Second toggle press or safety limit | Spinner and Transcribing label | Wait; a new toggle may begin a later capture | Menu state reads transcribing | Cursor injection, clipboard fallback, or visible error |
| Success | Nonempty transcription delivered | Overlay hides; menu returns idle | Start another capture | Clipboard fallback beeps | N/A - next capture is independent |
| Error | Audio, route, model, clipboard, or hotkey failure | Visible menu error; overlay hides | Retry toggle or follow remediation | Beep for actionable failure | Successful retry or daemon restart |

## 6. Interaction Contract

| Interaction | Input methods | User purpose | Immediate feedback | Persistent result | Escape or undo |
| --- | --- | --- | --- | --- | --- |
| Toggle recording | Global Control + Fn/Globe chord | Start or stop capture without holding keys | Overlay and menu state change immediately | Audio is captured until stopped | Press chord again; ten-minute safety stop |
| Speak | Microphone | Create transcript | Waveform reacts to level | Samples remain local until transcription | Stop recording |
| Change focus or type elsewhere | Pointer or keyboard | Continue working while speaking | Recording continues | Delivery becomes clipboard-only | Paste with Command-V |
| Quit | Menu or SIGINT | Stop Parrot | Daemon exits | Active capture is discarded | Relaunch Parrot |

## 7. Motion Choreography

| Moment | Trigger | Property | Timing and easing | Purpose | Reduced-motion result |
| --- | --- | --- | --- | --- | --- |
| Live level response | Microphone buffer | Per-bar vertical transform | 90ms ease-out smoothing | Prove the microphone is hearing the speaker | Values update without interpolation; semantic meter remains |
| Recording or transcribing state | Toggle chord or capture completion | N/A - immediate swap | 0ms | High-frequency keyboard actions must feel instant | Identical |
| Overlay visibility | Start, delivery, or failure | N/A - immediate show/hide | 0ms | Avoid stale or delayed recording truth | Identical |

## 8. Responsive Transformations

| Concern | Mobile | Tablet | Desktop | Why it changes |
| --- | --- | --- | --- | --- |
| Hierarchy | N/A - macOS-only | N/A - macOS-only | Waveform before stop hint | Platform scope |
| Navigation | N/A - macOS-only | N/A - macOS-only | Menu-bar status | Platform scope |
| Primary action | N/A - macOS-only | N/A - macOS-only | Global physical-key chord | Platform scope |
| Supporting content | N/A - macOS-only | N/A - macOS-only | Compact bottom-center overlay | Platform scope |
| Media and motion | N/A - macOS-only | N/A - macOS-only | Small transform-only waveform | Platform scope |

## 9. Accessibility and User Control

- **Keyboard order and focus behavior:** The global shortcut never takes focus. The overlay is nonactivating and click-through.
- **Screen-reader names and announcements:** Recording, transcribing, and safety-limit transitions post high-priority announcements; the recording announcement identifies the exact stop chord.
- **Contrast and non-color cues:** Waveform movement, text, menu copy, and icon shape supplement color.
- **Touch targets:** N/A - no pointer target is introduced.
- **Reduced-motion behavior:** Remove waveform interpolation while retaining instantaneous level information.
- **Sound controls and captions:** No spoken content is played; a standard system beep signals clipboard fallback or error.
- **Pause, skip, escape, undo, or recovery controls:** The same chord stops capture. A ten-minute limit prevents indefinite accidental recording. A two-second rearm window prevents an already-arriving stop press from reopening the microphone at that boundary.
- **Secure input:** If a password or secure text field is focused, Parrot aborts before opening the microphone and announces the reason. If focus moves into a secure field during capture or transcription, Parrot discards the transcript instead of inserting or copying it.

## 10. Performance and Media Contract

- **Critical content available before enhanced media:** Stop instructions and recording state do not depend on waveform animation.
- **Loading strategy:** Model warms before the daemon advertises readiness.
- **Poster, skeleton, or static fallback:** The waveform rests at minimum height when silent.
- **Slow-network and data-saver behavior:** N/A - transcription is on-device after model installation.
- **Failed-media behavior:** Capture and route failures hide the overlay, beep, and remain visible in the menu.
- **Rendering or animation budget:** Six small bars update through vertical transforms only; no layout, blur, or continuous timer animation.
- **Target measurements and how they will be measured:** Existing audio callback cadence drives updates; release tests and rendered observation verify stability.

## 11. Content Truth and Microcopy

- **Final headline and primary CTA:** N/A - system utility, not a page.
- **Terminology that must remain consistent:** Press Control + Fn/Globe to record; press again to stop; transcribing; copied to clipboard.
- **Claims or numbers requiring evidence:** Ten-minute safety limit must match implementation.
- **Placeholders or fabricated data prohibited:** No simulated waveform during silence.
- **Error and recovery voice:** Direct, short, and actionable.

## 12. Implementation Boundaries

- **Existing patterns and dependencies to reuse:** CGEventTap, AVAudioEngine, FocusSnapshot, DeliveryGuard, SwiftUI overlay, NSStatusItem, and system accessibility settings.
- **Allowed files or surfaces:** Hotkey state, run coordination, overlay/menu UI, tests, setup/help copy, README, and architecture documentation.
- **Must remain unchanged:** Stable app identifier, signed bundle path, private logs/audio, local transcription, and fail-closed focus delivery.
- **Explicitly out of scope:** Cloud transcription, history, monetization, account systems, a settings window, or publishing a release.
- **Known technical constraints:** Fn/Globe must remain mapped to Do Nothing; system permission identity is app-bundle-specific.

## 13. Assumptions and Open Decisions

| Item | Known, assumed, or unknown | Evidence | What would invalidate it |
| --- | --- | --- | --- |
| Toggle is the only default interaction | Known | User explicitly requested same-chord start and stop | User later requests selectable hold mode |
| Clipboard means recoverable for manual paste | Known | Existing fail-closed delivery and user wording | User requests automatic paste into a later field |
| Ten minutes covers normal dictation | Assumed | Dictation use case, not meeting recording | Observed legitimate captures regularly exceed it |
| Overlay can remain bottom-center | Assumed | Existing accepted surface | Rendered use shows it obscures critical controls |

## 14. Acceptance Criteria

1. PASS if one chord press starts recording and releasing the keys does not stop it.
2. PASS if a second press stops recording exactly once and begins transcription.
3. PASS if repeated flagsChanged events while the chord remains down cannot double-toggle.
4. PASS if the overlay remains visible for the complete recording and reacts to real audio levels.
5. PASS if recording and transcribing state changes are immediate and rapid reuse cannot leave stale UI.
6. PASS if Reduce Motion removes waveform interpolation without removing the live microphone signal.
7. PASS if starting outside a specific editable field or interacting elsewhere copies the transcript instead of injecting it.
8. PASS if a successful clipboard fallback leaves the transcript available for Command-V and a failed copy restores the prior clipboard.
9. PASS if capture is bounded by a visible ten-minute safety stop.
10. PASS if app identity, live audio, model readiness, private logs, and LaunchAgent readiness remain verified.

## 15. Verification Plan

- **Routes or stories:** Idle to recording to transcribing to cursor delivery; clipboard fallback; capture error; rapid toggle; safety limit.
- **Viewports:** Active macOS display and a secondary display when available.
- **Input modes:** Physical Control + Fn/Globe, pointer focus change, keyboard interaction, and menu Quit.
- **Network and failure scenarios:** Offline cached model; input-route change; zero-frame capture; event-tap recovery.
- **Automated checks:** Release build, Swift tests for chord/toggle state, parse, plist, workflow YAML, and staged diff checks.
- **Rendered QA evidence:** Persistent overlay, voice-reactive waveform, instant state swap, and reduced-motion behavior observed in the running signed app.
- **Responsive QA loop:** N/A - macOS utility has no web viewport or mobile surface; multi-display positioning is the applicable adaptation.
- **Final verifier:** Signed app doctor with live audio and model readiness, Parakeet smoke test, running LaunchAgent ready log, Boris, Fresh Eyes, and motion approval.
