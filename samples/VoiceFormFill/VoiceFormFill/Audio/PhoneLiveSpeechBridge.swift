/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import AVFoundation
import Speech

/// Host-microphone speech recognition that forwards results into MockDeviceKit via
/// `simulateTranscription`. Avoids `MockSpeechSource.liveDeviceAsr`, whose internal
/// `AVAudioEngine` tap can crash when the tap format sample rate does not match hardware.
@MainActor
final class PhoneLiveSpeechBridge {

  private let onTranscription: @Sendable (String, Bool) -> Void

  private var engine = AVAudioEngine()
  nonisolated private let activeRequest = RecognitionRequestBox()
  private var task: SFSpeechRecognitionTask?
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var tapInstalled = false

  init(onTranscription: @escaping @Sendable (String, Bool) -> Void) {
    self.onTranscription = onTranscription
  }

  func start() async -> String? {
    guard let recognizer, recognizer.isAvailable else {
      return "On-device speech recognition is not available on this host."
    }

    let authorized = await Self.requestSpeechAuthorization()
    guard authorized else {
      return "Speech recognition permission was not granted."
    }

    stop()

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .measurement,
        options: [.defaultToSpeaker, .duckOthers]
      )
      try session.setActive(true)
    } catch {
      return "Failed to configure audio session: \(error.localizedDescription)"
    }

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      return "No usable microphone input (simulator mic disabled or permission denied)."
    }

    // The tap closure is defined in a nonisolated function so it is not main-actor
    // isolated. Core Audio invokes it on a realtime queue.
    Self.installInputTap(on: input, format: format, box: activeRequest)
    tapInstalled = true

    activeRequest.setAccepting(true)
    beginRecognitionTask()

    engine.prepare()
    do {
      try engine.start()
    } catch {
      stop()
      return "Failed to start microphone: \(error.localizedDescription)"
    }
    return nil
  }

  /// Drops microphone audio and any closing transcript. Safe to call off the main actor
  /// so speech playback can close the mic before the first sample of a prompt is heard.
  nonisolated func suspendCapture() {
    activeRequest.setAccepting(false)
    activeRequest.endAudio()
  }

  /// Starts a new recognition request so the next transcript does not include earlier speech.
  func resumeCapture() {
    guard tapInstalled else { return }
    activeRequest.setAccepting(true)
    beginRecognitionTask()
  }

  func stop() {
    activeRequest.setAccepting(false)
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    if engine.isRunning {
      engine.stop()
    }
    cancelRecognitionTask()
    engine = AVAudioEngine()
  }

  private func beginRecognitionTask() {
    guard activeRequest.isAccepting, let recognizer else { return }
    let generation = activeRequest.beginGeneration()
    cancelRecognitionTask()

    let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    recognitionRequest.shouldReportPartialResults = true
    activeRequest.set(recognitionRequest)

    let onTranscription = onTranscription
    let activeRequest = activeRequest
    task = recognizer.recognitionTask(with: recognitionRequest) { result, error in
      guard activeRequest.accepts(generation: generation) else { return }
      if let result {
        let text = result.bestTranscription.formattedString
        if !text.isEmpty {
          onTranscription(text, result.isFinal)
        }
        if result.isFinal {
          Task { @MainActor [weak self] in
            self?.beginRecognitionTask()
          }
        }
      } else if error != nil {
        Task { @MainActor [weak self] in
          self?.beginRecognitionTask()
        }
      }
    }
  }

  private func cancelRecognitionTask() {
    activeRequest.endAudio()
    task?.cancel()
    activeRequest.set(nil)
    task = nil
  }

  /// Defined outside the main actor so the tap callback is not isolated to it.
  /// Core Audio delivers buffers on `RealtimeMessenger`, and a main-actor closure
  /// traps in `dispatch_assert_queue`.
  private nonisolated static func installInputTap(
    on input: AVAudioInputNode,
    format: AVAudioFormat,
    box: RecognitionRequestBox
  ) {
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
      box.append(buffer)
    }
  }

  /// TCC invokes this callback off the main queue. A `@MainActor` method would isolate
  /// that closure to the main actor and trap in `dispatch_assert_queue`.
  private nonisolated static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }
}

/// Holds the active `SFSpeechAudioBufferRecognitionRequest` for the audio tap thread.
private final class RecognitionRequestBox: @unchecked Sendable {
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var accepting = true
  private var generation = 0

  var isAccepting: Bool {
    lock.lock()
    defer { lock.unlock() }
    return accepting
  }

  func setAccepting(_ accepting: Bool) {
    lock.lock()
    self.accepting = accepting
    if !accepting {
      generation += 1
    }
    lock.unlock()
  }

  func beginGeneration() -> Int {
    lock.lock()
    defer { lock.unlock() }
    generation += 1
    return generation
  }

  func accepts(generation: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return accepting && self.generation == generation
  }

  func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock()
    self.request = request
    lock.unlock()
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0 else { return }
    lock.lock()
    if accepting {
      request?.append(buffer)
    }
    lock.unlock()
  }

  func endAudio() {
    lock.lock()
    request?.endAudio()
    request = nil
    lock.unlock()
  }
}
