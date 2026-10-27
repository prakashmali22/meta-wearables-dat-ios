/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import Foundation

@MainActor
protocol SpeechInputProviding: AnyObject {
  func transcriptionStream() -> AsyncStream<Transcription>
  func listeningStateStream() -> AsyncStream<GlassesSpeechListeningState>
}

@MainActor
final class GlassesSpeechInput: SpeechInputProviding {

  private let wearablesService: WearablesService

  init(wearablesService: WearablesService) {
    self.wearablesService = wearablesService
  }

  func transcriptionStream() -> AsyncStream<Transcription> {
    wearablesService.transcriptionStream()
  }

  func listeningStateStream() -> AsyncStream<GlassesSpeechListeningState> {
    wearablesService.speechListeningStateStream()
  }
}
