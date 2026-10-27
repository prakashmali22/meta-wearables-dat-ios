# Voice Form Fill — Technical Documentation

UIKit proof-of-concept that walks a form field-by-field: prompts are spoken on the phone and mirrored on glasses **Display**, answers arrive through DAT **Speech**, and committed values land in `UITextField`s.

**SPM products:** `MWDATCore`, `MWDATSpeech`, `MWDATDisplay`, `MWDATMockDevice` (see `project.yml`).

---

## High-level architecture

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ FormViewController                                                       │
│   Fill by voice → WearablesService.startVoiceSession()                  │
│                 → VoiceFormCoordinator.start(fields:binding:)            │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
  SpokenOutput            GlassesDisplayMirror    GlassesSpeechInput
  (AVSpeechSynthesizer)   → WearablesService      → transcriptionStream()
        │                   → Display.send()              │
        │                       (MWDATDisplay)            │
        │                                                 ▼
        │                                         WearablesService
        │                                         (Speech publishers)
        │                                                 ▲
        │                                                 │
  PhoneLiveSpeechBridge (optional) ──simulateTranscription──┘
  SFSpeechRecognizer + AVAudioEngine          MockSpeechKit (.injected)
```

**Important:** DAT Speech does **not** use UIKit-style delegates. It exposes **`Announcer` publishers**; the sample subscribes with `.listen { }` and stores tokens in `ListenerTokenBag`.

---

## “Fill by voice” — end-to-end sequence

### 1. User taps **Fill by voice** (`FormViewController.fillTapped`)

1. Dismiss keyboard (`view.endEditing`).
2. `try await wearablesService.startVoiceSession()` — opens DAT session and capabilities.
3. `coordinator.start(fields: fieldDescriptors, binding: self)` — starts the per-field loop (does not block the main thread; runs in a `Task`).

### 2. Session startup (`WearablesService.startVoiceSession`)

| Step | API / action |
|------|----------------|
| Mock pairing (simulator default) | `MockDeviceKit.shared.enable()`, `pairGlasses(model: .metaRayBanDisplay)`, lifecycle `powerOn()` / `unfold()` / `don()`, `services.speech.setTranscriptionSource(.injected)` |
| Device selection | `SpecificDeviceSelector(device:)` (mock) or `AutoDeviceSelector(wearables:filter: { $0.supportsDisplay() })` (hardware) |
| Session | `Wearables.shared.createSession(deviceSelector:)`, `session.start()`, wait until `session.stateStream()` yields `.started` |
| Microphone permission | `checkPermissionStatus(.microphone)`, `requestPermission(.microphone)` |
| Speech capability | `session.addSpeech()`, register publishers, `speech.start()` |
| Display capability | `session.addDisplay()`, register `statePublisher`, `display.start()` |
| Live ASR (Mock tab) | If **Live ASR** is on: `PhoneLiveSpeechBridge.start()` → forwards text via `MockSpeechKit.simulateTranscription` |

Session errors are observed on `session.errorStream()` in a background `Task`.

### 3. Per-field loop (`VoiceFormCoordinator.runLoop`)

For each `FormFieldDescriptor` (Name, Email, Phone, Notes):

1. **UI:** `binding.focusField(id:)` → `UITextField.becomeFirstResponder()`.
2. **Glasses:** `displayMirror.showQuestion(field.prompt)` → `Display.send(FlexBox { Text(prompt, style: .heading) … })`.
3. **Phone TTS:** `spokenOutput.speak(field.prompt)` — default prompt is `"<Label>?"` from `FormFieldDescriptor.init`.
4. **Listen:** `waitForAnswer` consumes `speechInput.transcriptionStream()` until an answer or voice command.
5. **Commit:** `AnswerNormalizer.normalize`, `binding.setCommittedText`, optional `spokenOutput.speak("Got …")`, advance index.

After all fields: `spokenOutput.speak("All fields complete.")`.

### 4. How answers are accepted (`AnswerWaitSession`)

Transcripts are ignored while `spokenOutput.isSpeaking` is true (prompt / confirmation TTS).

| Source | Advance when |
|--------|----------------|
| Final transcript (`isFinal: true`) | Non-empty text, or voice command |
| Partial transcript | Voice command (`skip`, `done`, …), or **~1.5 s silence** after last partial (Live ASR) |
| Mock tab **Send final** | Injected final transcript |
| Mock tab **Send partial** | Preview only (gray text); does not commit unless silence/command rules fire |

Voice commands (case-insensitive): `skip` / `next`, `back` / `previous`, `repeat` / `again`, `clear` / `erase`, `stop` / `cancel` / `quit`, `done` / `finish` / `ok` / `okay` (commits current partial).

---

## Speech input paths

### A. DAT Speech (always active during session)

```text
Speech.transcriptionPublisher  →  handleTranscription(TranscriptionResult)
                               →  AsyncStream<Transcription>  →  VoiceFormCoordinator
```

Hardware path: glasses microphone + DAT speech stack (when not using mock injection).

### B. Mock — typed injection (Mock tab, default)

```text
MockPanelViewController.sendFinal / sendPartial
  → WearablesService.simulateTranscription(text:isFinal:)
  → mockGlasses.services.speech.simulateTranscription(...)
  → same Speech.transcriptionPublisher path as real speech
```

Requires `MockSpeechSource.injected` (set at bootstrap and when toggling Live ASR).

### C. Mock — Live ASR (Mock tab)

The sample **does not** call `MockSpeechSource.liveDeviceAsr` (known AVAudioEngine tap issues on some hosts).

```text
PhoneLiveSpeechBridge (SFSpeechRecognizer + AVAudioEngine)
  → simulateTranscription(text:isFinal:)
  → DAT Speech path (B)
```

**Echo avoidance:** Before TTS, `SpokenOutput.prepareForSpeech` → `WearablesService.suspendLiveCapture()` (stops feeding buffers, ends current recognition request). After TTS + 400 ms tail, `finishSpeech` → `resumeLiveCapture()` (new `SFSpeechAudioBufferRecognitionRequest`).

---

## Delegates, protocols, and callbacks

### Meta DAT SDK — listeners (not delegates)

Registered in `WearablesService.attachSpeech` / `attachDisplay`. Tokens kept in `ListenerTokenBag` until session teardown.

| Publisher | Type (module) | Handler | Purpose |
|-----------|---------------|---------|---------|
| `speech.transcriptionPublisher` | `MWDATSpeech` / `TranscriptionResult` | `handleTranscription` | Partial/final text → app `Transcription` |
| `speech.statePublisher` | `SpeechState` | `handleSpeechState` | Restart speech after `.stopped` when already started |
| `speech.errorPublisher` | Speech error enum | Updates `statusMessage`, `.unavailable` → UI state |
| `display.statePublisher` | `DisplayState` | Sets `displayIsStarted = (state == .started)` | Gate `display.send` |
| `session.stateStream()` | `DeviceSessionState` | Wait for `.started` before capabilities | Session lifecycle |
| `session.errorStream()` | `DeviceSessionError` | Surface session errors | Session lifecycle |

**Speech capability calls:** `session.addSpeech()`, `speech.start()`, `speech.stop()`, `session.removeSpeech()`.

**Display capability calls:** `session.addDisplay()`, `display.start()`, `display.stop()`, `display.send(_:)`.

### Apple frameworks

| Component | API | Role |
|-----------|-----|------|
| `SpokenOutput` | **`AVSpeechSynthesizerDelegate`** | `speechSynthesizer(_:didFinish:)`, `speechSynthesizer(_:didCancel:)` — resume `async speak()` continuations |
| `PhoneLiveSpeechBridge` | **`SFSpeechRecognizer.requestAuthorization`** callback | Speech recognition permission |
| `PhoneLiveSpeechBridge` | **`SFSpeechRecognizer.recognitionTask(with:resultHandler:)`** | Partial/final transcripts from mic |
| `PhoneLiveSpeechBridge` | **`AVAudioEngine.inputNode.installTap`** | PCM buffers → `SFSpeechAudioBufferRecognitionRequest.append` |
| `FormViewController` | **`UITextFieldDelegate`** | `textFieldShouldReturn` — Next/Done between fields (keyboard UX only; not used for voice) |

### App protocols (dependency injection)

| Protocol | Conformer | Role |
|----------|-----------|------|
| `SpeechInputProviding` | `GlassesSpeechInput` | `transcriptionStream()`, `listeningStateStream()` |
| `SpokenOutputProviding` | `SpokenOutput` | `speak`, `silence`, `isSpeaking` |
| `FormFieldBinding` | `FormViewController` | `setCommittedText`, `setPreviewText`, `focusField` |

### UIKit / scene

| Type | Methods |
|------|---------|
| `SceneDelegate` | `scene(_:openURLContexts:)` → `Wearables.shared.handleUrl(url)` when query contains `metaWearablesAction` |
| `AppDelegate` | `Wearables.configure()` at launch |

---

## SDK API reference (used in this sample)

### MWDATCore

| Symbol | Usage |
|--------|--------|
| `Wearables.configure()` | App launch (`AppDelegate`) |
| `Wearables.shared` | Entry point |
| `Wearables.shared.handleUrl(_:)` | Meta AI registration / permission callbacks |
| `Wearables.shared.checkPermissionStatus(.microphone)` | Before speech |
| `Wearables.shared.requestPermission(.microphone)` | DAT microphone grant |
| `DeviceSession` | `createSession`, `start`, `stop`, `stateStream`, `errorStream`, `addSpeech`, `addDisplay`, `removeSpeech` |
| `SpecificDeviceSelector` | Mock device by ID |
| `AutoDeviceSelector` | Hardware; filter `supportsDisplay()` |
| `ListenerTokenBag` / `.listen` / `.store(in:)` | Publisher subscriptions |
| `DeviceSessionError` | Typed `session.start()` errors |

### MWDATSpeech

| Symbol | Usage |
|--------|--------|
| `Speech` | From `session.addSpeech()` |
| `Speech.start()` / `Speech.stop()` | Capability lifecycle |
| `Speech.transcriptionPublisher` | Answer text |
| `Speech.statePublisher` | `SpeechState` (`.started`, `.stopped`, …) |
| `Speech.errorPublisher` | Speech errors |
| `TranscriptionResult` | `text`, `isFinal`, `confidence` |

### MWDATDisplay

| Symbol | Usage |
|--------|--------|
| `Display` | From `session.addDisplay()` |
| `Display.start()` / `Display.stop()` | Capability lifecycle |
| `Display.statePublisher` | Wait for `.started` before send |
| `Display.send(_:)` | `FlexBox`, `Text`, `.padding`, `.background` DSL |
| `DisplayState` | `.started` gates prompts |

### MWDATMockDevice

| Symbol | Usage |
|--------|--------|
| `MockDeviceKit.shared` | `enable()`, `pairGlasses(model: .metaRayBanDisplay)` |
| `MockGlasses` | `powerOn`, `unfold`, `don`, `deviceIdentifier` |
| `MockSpeechKit` | `setTranscriptionSource(.injected)`, `simulateTranscription(text:isFinal:confidence:)` |
| `MockDisplayKit` | `createPreviewView()` (Mock tab preview) |

---

## Key source files

| File | Responsibility |
|------|----------------|
| `FormViewController.swift` | Form UI, **Fill by voice** / **Stop**, `FormFieldBinding` |
| `VoiceFormCoordinator.swift` | Field loop, `AnswerWaitSession`, voice commands |
| `WearablesService.swift` | DAT session, Speech/Display, streams, mock + live bridge |
| `GlassesSpeechInput.swift` | Thin wrapper over `WearablesService` streams |
| `GlassesDisplayMirror.swift` | Display prompt helper |
| `SpokenOutput.swift` | Phone prompts via `AVSpeechSynthesizer` |
| `PhoneLiveSpeechBridge.swift` | Host mic ASR → mock injection |
| `AnswerNormalizer.swift` | Email/phone normalization, command parsing |
| `MockPanelViewController.swift` | Inject text / Live ASR toggle, display preview |
| `SceneDelegate.swift` | Composition root, TTS ↔ mic gating hooks |

---

## Permissions & Info.plist

| Permission | Key / API |
|------------|-----------|
| DAT microphone | `NSMicrophoneUsageDescription`, `requestPermission(.microphone)` |
| Apple speech recognition (Live ASR) | `NSSpeechRecognitionUsageDescription`, `SFSpeechRecognizer.requestAuthorization` |
| Meta AI / DAT | `MWDAT` plist, URL scheme, `handleUrl`, background modes (see sample `Info.plist`) |

---

## Stop and cleanup

**Stop** (`FormViewController.stopTapped`):

1. `coordinator.stop()` — cancels run/transcription tasks, `spokenOutput.silence()`.
2. `wearablesService.stopVoiceSession()` — stops live bridge, `speech.stop()`, `removeSpeech()`, `display.stop()`, `session.stop()`, clears listener bags.

---

## Related docs

- Sample overview: [README.md](./README.md)
- DAT Speech (experimental): [Speech skill / developer docs](https://wearables.developer.meta.com/docs/develop/)
- iOS API: [MWDAT reference](https://wearables.developer.meta.com/docs/reference/ios_swift/dat/latest)
