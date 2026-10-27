/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import Foundation

struct Transcription: Equatable, Sendable {
  let text: String
  let isFinal: Bool
  let confidence: Float?

  init(text: String, isFinal: Bool, confidence: Float? = nil) {
    self.text = text
    self.isFinal = isFinal
    self.confidence = confidence
  }
}

enum GlassesSpeechListeningState: Equatable, Sendable {
  case idle
  case starting
  case listening
  case stopped
  case unavailable
}
