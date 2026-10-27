/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import Foundation

enum FormFieldKind: Sendable {
  case text
  case email
  case phone
  case number
  case notes
}

struct FormFieldDescriptor: Sendable, Equatable {
  let id: String
  let label: String
  let prompt: String
  let kind: FormFieldKind

  init(id: String, label: String, kind: FormFieldKind) {
    self.id = id
    self.label = label
    self.kind = kind
    self.prompt = "\(label)?"
  }
}

@MainActor
protocol FormFieldBinding: AnyObject {
  func setCommittedText(_ text: String, forFieldID id: String)
  func setPreviewText(_ text: String?, forFieldID id: String)
  func focusField(id: String)
}
