/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import XCTest
@testable import VoiceFormFill

final class AnswerNormalizerTests: XCTestCase {

  func testEmailNormalization() {
    XCTAssertEqual(
      AnswerNormalizer.normalize("john at example dot com", for: .email),
      "john@example.com"
    )
  }

  func testPhoneSpokenDigits() {
    XCTAssertEqual(
      AnswerNormalizer.normalize("five five five one two three four", for: .phone),
      "5551234"
    )
  }

  func testVoiceCommands() {
    XCTAssertEqual(AnswerNormalizer.isVoiceCommand("skip"), .skip)
    XCTAssertEqual(AnswerNormalizer.isVoiceCommand("Stop"), .stop)
    XCTAssertEqual(AnswerNormalizer.isVoiceCommand("done"), .commitAnswer)
    XCTAssertNil(AnswerNormalizer.isVoiceCommand("hello"))
  }
}
