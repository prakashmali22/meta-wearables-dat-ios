/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import AVFoundation
import Foundation

protocol SpokenOutputProviding: AnyObject, Sendable {
  var isSpeaking: Bool { get }
  func speak(_ words: String) async
  func silence()
}

final class SpokenOutput: NSObject, SpokenOutputProviding, @unchecked Sendable {

  private let synthesizer = AVSpeechSynthesizer()
  private let lock = NSLock()
  private let allowSpeakerWhenNoBluetooth: Bool

  private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
  private var linesInFlight = 0

  /// Called synchronously before playback so the mic can close before the prompt is heard.
  var prepareForSpeech: (@Sendable () -> Void)?
  /// Called after playback and a short tail, before `speak` returns.
  var finishSpeech: (@Sendable () async -> Void)?

  var isSpeaking: Bool { lock.withLock { linesInFlight > 0 } }

  init(allowSpeakerWhenNoBluetooth: Bool) {
    self.allowSpeakerWhenNoBluetooth = allowSpeakerWhenNoBluetooth
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ words: String) async {
    let line = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return }

    if !allowSpeakerWhenNoBluetooth, !hasBluetoothAudioRoute {
      return
    }

    let session = AVAudioSession.sharedInstance()
    if session.category == .soloAmbient || session.category == .playback {
      try? session.setCategory(
        .playAndRecord,
        mode: .spokenAudio,
        options: [.defaultToSpeaker, .duckOthers]
      )
    }

    let utterance = AVSpeechUtterance(string: line)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

    prepareForSpeech?()
    await withCheckedContinuation { continuation in
      lock.withLock {
        waiting[ObjectIdentifier(utterance)] = continuation
        linesInFlight += 1
      }
      synthesizer.speak(utterance)
    }
    // The speaker is still in the room after the utterance ends. Keep the mic closed
    // so that tail is not transcribed as the user's answer.
    try? await Task.sleep(for: .milliseconds(400))
    await finishSpeech?()
  }

  func silence() {
    synthesizer.stopSpeaking(at: .immediate)
  }

  private var hasBluetoothAudioRoute: Bool {
    AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
      switch output.portType {
      case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: true
      default: false
      }
    }
  }

  private func finish(_ utterance: AVSpeechUtterance) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      guard let waiter = waiting.removeValue(forKey: ObjectIdentifier(utterance)) else {
        return nil
      }
      linesInFlight -= 1
      return waiter
    }
    continuation?.resume()
  }
}

extension SpokenOutput: AVSpeechSynthesizerDelegate {
  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    finish(utterance)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    finish(utterance)
  }
}
