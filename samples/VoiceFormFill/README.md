# Voice Form Fill (UIKit POC)

Proof-of-concept sample that reads form field prompts aloud, listens for answers through DAT **Speech** (`MWDATSpeech`), mirrors the active question on **Display** (`MWDATDisplay`), and fills `UITextField`s on the phone.

**Technical documentation:** [TECHNICAL.md](./TECHNICAL.md) — architecture, Fill by voice sequence, DAT publisher APIs, Apple speech/TTS delegates, and mock vs live ASR paths.

## Run (simulator)

1. Open `VoiceFormFill.xcodeproj` (regenerate with `xcodegen generate` if you change `project.yml`).
2. Build and run on an iOS Simulator (MockDeviceKit pairs a **Meta Ray-Ban Display** automatically).

## Try voice fill

1. **Form** tab → **Fill by voice** (starts a device session with speech + display).
2. **Mock** tab → type an answer → **Send final** (injected speech), or switch to **Live ASR** and speak into the Mac mic (phone mic → `SFSpeechRecognizer`, forwarded as mock speech — not `MockSpeechSource.liveDeviceAsr`, which can crash on some hosts).

Voice commands: `skip` / `next`, `back`, `repeat`, `clear`, `stop`, and `done` (commit the answer you just spoke).

The form advances when a **final** transcript arrives, after **~1.5s of silence** following a partial (Live ASR), or when you say **done**. Mock tab: use **Send final**, not **Send partial**, unless you are testing the preview line only.

## Notes

- Speech is experimental (dev/beta release channels only).
- Talkback uses `AVSpeechSynthesizer` on the phone (speaker allowed in simulator mock mode).
- DAT does not provide glasses TTS; audio routes to Bluetooth when real glasses are connected.
