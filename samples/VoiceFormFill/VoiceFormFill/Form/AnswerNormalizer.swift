/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import Foundation

enum AnswerNormalizer {

  static func normalize(_ raw: String, for kind: FormFieldKind) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    switch kind {
    case .text, .notes:
      return trimmed
    case .email:
      return normalizeEmail(trimmed)
    case .phone:
      return normalizePhone(trimmed)
    case .number:
      return normalizeNumber(trimmed)
    }
  }

  static func isVoiceCommand(_ text: String) -> VoiceCommand? {
    let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch key {
    case "skip", "next":
      return .skip
    case "back", "previous":
      return .back
    case "repeat", "again":
      return .repeatPrompt
    case "clear", "erase":
      return .clear
    case "stop", "cancel", "quit":
      return .stop
    case "done", "finish", "ok", "okay":
      return .commitAnswer
    default:
      return nil
    }
  }

  private static func normalizeEmail(_ text: String) -> String {
    var value = text.lowercased()
    value = value.replacingOccurrences(of: " at ", with: "@")
    value = value.replacingOccurrences(of: " dot ", with: ".")
    value = value.replacingOccurrences(of: " dot", with: ".")
    value = value.replacingOccurrences(of: "dot ", with: ".")
    value = value.replacingOccurrences(of: " ", with: "")
    return value
  }

  private static func normalizePhone(_ text: String) -> String {
    let words = text.lowercased()
    var digits = ""
    for component in words.split(separator: " ") {
      if let digit = wordToDigit[String(component)] {
        digits.append(digit)
      } else {
        for char in component where char.isNumber {
          digits.append(char)
        }
      }
    }
    if digits.isEmpty {
      return text.filter(\.isNumber)
    }
    return digits
  }

  private static func normalizeNumber(_ text: String) -> String {
    let lowered = text.lowercased()
    if let parsed = Int(lowered.filter(\.isNumber)), !lowered.filter(\.isNumber).isEmpty {
      return String(parsed)
    }
    var digits = ""
    for word in lowered.split(separator: " ") {
      if let digit = wordToDigit[String(word)] {
        digits.append(digit)
      }
    }
    return digits.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : digits
  }

  private static let wordToDigit: [String: Character] = [
    "zero": "0", "oh": "0", "o": "0",
    "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
    "six": "6", "seven": "7", "eight": "8", "nine": "9",
  ]
}

enum VoiceCommand: Equatable, Sendable {
  case skip
  case back
  case repeatPrompt
  case clear
  case stop
  /// Commit the in-progress partial transcript (say "done" after your answer).
  case commitAnswer
}
