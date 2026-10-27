/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import Foundation

enum VoiceFormRunOutcome: Equatable, Sendable {
  case completed
  case stopped
  case failed(String)
}

struct VoiceFormCoordinatorState: Equatable, Sendable {
  var status: String = "Ready"
  var currentFieldID: String?
  var partialAnswer: String?
  var isRunning = false
}

private enum AnswerOutcome {
  case answered(String)
  case skip
  case back
  case repeatPrompt
  case clear
  case stop
  case failed(String)
}

@MainActor
final class VoiceFormCoordinator {

  var onStateChange: ((VoiceFormCoordinatorState) -> Void)?

  private let speechInput: SpeechInputProviding
  private let spokenOutput: SpokenOutputProviding
  private let displayMirror: GlassesDisplayMirror?

  private var state = VoiceFormCoordinatorState()
  private var runTask: Task<Void, Never>?
  private var transcriptionTask: Task<Void, Never>?

  init(
    speechInput: SpeechInputProviding,
    spokenOutput: SpokenOutputProviding,
    displayMirror: GlassesDisplayMirror?
  ) {
    self.speechInput = speechInput
    self.spokenOutput = spokenOutput
    self.displayMirror = displayMirror
  }

  func stop() {
    runTask?.cancel()
    transcriptionTask?.cancel()
    spokenOutput.silence()
    updateState {
      $0.isRunning = false
      $0.status = "Stopped"
      $0.partialAnswer = nil
    }
  }

  func start(
    fields: [FormFieldDescriptor],
    binding: FormFieldBinding
  ) {
    stop()
    guard !fields.isEmpty else { return }

    updateState {
      $0.isRunning = true
      $0.status = "Starting voice fill…"
    }

    runTask = Task { [weak self] in
      guard let self else { return }
      let outcome = await self.runLoop(fields: fields, binding: binding)
      switch outcome {
      case .completed:
        self.updateState {
          $0.isRunning = false
          $0.status = "Form fill complete"
          $0.partialAnswer = nil
          $0.currentFieldID = nil
        }
      case .stopped:
        self.updateState {
          $0.isRunning = false
          $0.status = "Voice fill stopped"
        }
      case .failed(let message):
        self.updateState {
          $0.isRunning = false
          $0.status = message
        }
      }
    }
  }

  private func runLoop(
    fields: [FormFieldDescriptor],
    binding: FormFieldBinding
  ) async -> VoiceFormRunOutcome {
    var index = 0
    while index < fields.count {
      if Task.isCancelled { return .stopped }
      let field = fields[index]
      updateState {
        $0.currentFieldID = field.id
        $0.partialAnswer = nil
        $0.status = "Asking: \(field.label)"
      }
      binding.focusField(id: field.id)

      await displayMirror?.showQuestion(field.prompt)
      await spokenOutput.speak(field.prompt)

      let answerOutcome = await waitForAnswer(field: field, binding: binding)
      switch answerOutcome {
      case .answered(let text):
        let normalized = AnswerNormalizer.normalize(text, for: field.kind)
        binding.setCommittedText(normalized, forFieldID: field.id)
        binding.setPreviewText(nil, forFieldID: field.id)
        await spokenOutput.speak("Got \(normalized)")
        index += 1
      case .skip:
        index += 1
      case .back:
        index = max(0, index - 1)
      case .repeatPrompt:
        continue
      case .clear:
        binding.setCommittedText("", forFieldID: field.id)
        binding.setPreviewText(nil, forFieldID: field.id)
        continue
      case .stop:
        return .stopped
      case .failed(let message):
        return .failed(message)
      }
    }
    await spokenOutput.speak("All fields complete.")
    return .completed
  }

  private func waitForAnswer(
    field: FormFieldDescriptor,
    binding: FormFieldBinding
  ) async -> AnswerOutcome {
    if Task.isCancelled { return .stop }

    transcriptionTask?.cancel()
    let session = AnswerWaitSession(
      field: field,
      binding: binding,
      speechInput: speechInput,
      spokenOutput: spokenOutput,
      onPartialState: { [weak self] partial in
        self?.updateState { $0.partialAnswer = partial }
      }
    )
    async let answer = session.outcome()
    transcriptionTask = Task {
      await session.run()
    }
    return await answer
  }

  private func updateState(_ mutate: (inout VoiceFormCoordinatorState) -> Void) {
    mutate(&state)
    onStateChange?(state)
  }
}

@MainActor
private final class AnswerWaitSession {
  private let field: FormFieldDescriptor
  private let binding: FormFieldBinding
  private let speechInput: SpeechInputProviding
  private let spokenOutput: SpokenOutputProviding
  private let onPartialState: (String) -> Void

  private var latestPartial = ""
  private var debounceGeneration = 0
  private var debounceTask: Task<Void, Never>?
  private var finished = false
  private var result: AnswerOutcome = .stop
  private var outcomeContinuation: CheckedContinuation<Void, Never>?

  init(
    field: FormFieldDescriptor,
    binding: FormFieldBinding,
    speechInput: SpeechInputProviding,
    spokenOutput: SpokenOutputProviding,
    onPartialState: @escaping (String) -> Void
  ) {
    self.field = field
    self.binding = binding
    self.speechInput = speechInput
    self.spokenOutput = spokenOutput
    self.onPartialState = onPartialState
  }

  func outcome() async -> AnswerOutcome {
    await withCheckedContinuation { continuation in
      outcomeContinuation = continuation
    }
    return result
  }

  func run() async {
    for await transcription in speechInput.transcriptionStream() {
      if finished || Task.isCancelled {
        finish(with: .stop)
        return
      }
      if spokenOutput.isSpeaking { continue }

      let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }

        debugPrint("transcription text:", transcription)
      if !transcription.isFinal {
        latestPartial = text
        binding.setPreviewText(transcription.text, forFieldID: field.id)
        onPartialState(transcription.text)
        if let command = AnswerNormalizer.isVoiceCommand(text),
          let commandOutcome = Self.outcome(for: command, latestPartial: latestPartial) {
          finish(with: commandOutcome)
          return
        }
        scheduleSilenceCommit()
        continue
      }

      cancelSilenceCommit()

      if let command = AnswerNormalizer.isVoiceCommand(text),
        let commandOutcome = Self.outcome(for: command, latestPartial: latestPartial) {
        finish(with: commandOutcome)
        return
      }

      finish(with: .answered(text))
      return
    }
    finish(with: .stop)
  }

  private func finish(with outcome: AnswerOutcome) {
    guard !finished else { return }
    finished = true
    result = outcome
    cancelSilenceCommit()
    outcomeContinuation?.resume()
    outcomeContinuation = nil
  }

  private func scheduleSilenceCommit() {
    debounceGeneration += 1
    let generation = debounceGeneration
    debounceTask?.cancel()
    debounceTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      self.commitAfterSilence(generation: generation)
    }
  }

  private func commitAfterSilence(generation: Int) {
    guard !finished, generation == debounceGeneration else { return }
    guard let candidate = commitCandidate() else { return }
    if AnswerNormalizer.isVoiceCommand(candidate) != nil { return }
    finish(with: .answered(candidate))
  }

  private func cancelSilenceCommit() {
    debounceTask?.cancel()
    debounceTask = nil
  }

  private func commitCandidate() -> String? {
    let candidate = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
    return candidate.isEmpty ? nil : candidate
  }

  private static func outcome(
    for command: VoiceCommand,
    latestPartial: String
  ) -> AnswerOutcome? {
    switch command {
    case .skip:
      return .skip
    case .back:
      return .back
    case .repeatPrompt:
      return .repeatPrompt
    case .clear:
      return .clear
    case .stop:
      return .stop
    case .commitAnswer:
      let candidate = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !candidate.isEmpty else { return nil }
      return .answered(candidate)
    }
  }
}
