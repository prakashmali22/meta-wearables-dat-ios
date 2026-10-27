/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import XCTest
@testable import VoiceFormFill

@MainActor
final class VoiceFormCoordinatorTests: XCTestCase {

  func testFillsFieldFromFinalTranscript() async {
    let speech = FakeSpeechInput()
    let spoken = FakeSpokenOutput()
    let binding = FakeFormBinding()
    let coordinator = VoiceFormCoordinator(
      speechInput: speech,
      spokenOutput: spoken,
      displayMirror: nil
    )

    let fields = [FormFieldDescriptor(id: "name", label: "Name", kind: .text)]
    coordinator.start(fields: fields, binding: binding)

    for _ in 0..<20 {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(25))
    }

    speech.push(Transcription(text: "Ada Lovelace", isFinal: true))

    for _ in 0..<40 where binding.committed["name"] == nil {
      try? await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(binding.committed["name"], "Ada Lovelace")
  }

  func testSkipCommandOnPartialTranscript() async {
    let speech = FakeSpeechInput()
    let spoken = FakeSpokenOutput()
    let binding = FakeFormBinding()
    let coordinator = VoiceFormCoordinator(
      speechInput: speech,
      spokenOutput: spoken,
      displayMirror: nil
    )

    let fields = [
      FormFieldDescriptor(id: "name", label: "Name", kind: .text),
      FormFieldDescriptor(id: "email", label: "Email", kind: .email),
    ]
    coordinator.start(fields: fields, binding: binding)

    for _ in 0..<20 {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(25))
    }

    speech.push(Transcription(text: "skip", isFinal: false))

    for _ in 0..<40 {
      try? await Task.sleep(for: .milliseconds(25))
      if binding.committed["email"] != nil { break }
    }
    XCTAssertNil(binding.committed["name"])
    speech.push(Transcription(text: "ada@example.com", isFinal: true))
    for _ in 0..<40 where binding.committed["email"] == nil {
      try? await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(binding.committed["email"], "ada@example.com")
  }
}

@MainActor
private final class FakeSpeechInput: SpeechInputProviding {
  private var continuation: AsyncStream<Transcription>.Continuation?

  func transcriptionStream() -> AsyncStream<Transcription> {
    AsyncStream { continuation = $0 }
  }

  func listeningStateStream() -> AsyncStream<GlassesSpeechListeningState> {
    AsyncStream { $0.finish() }
  }

  func push(_ transcription: Transcription) {
    continuation?.yield(transcription)
  }
}

private final class FakeSpokenOutput: SpokenOutputProviding, @unchecked Sendable {
  var isSpeaking = false
  private(set) var lines: [String] = []

  func speak(_ words: String) async {
    lines.append(words)
  }

  func silence() {}
}

@MainActor
private final class FakeFormBinding: FormFieldBinding {
  var committed: [String: String] = [:]

  func setCommittedText(_ text: String, forFieldID id: String) {
    committed[id] = text
  }

  func setPreviewText(_ text: String?, forFieldID id: String) {}

  func focusField(id: String) {}
}
