/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import Foundation

@MainActor
final class GlassesDisplayMirror {

  private let wearablesService: WearablesService

  init(wearablesService: WearablesService) {
    self.wearablesService = wearablesService
  }

  func showQuestion(_ text: String) async {
    await wearablesService.sendDisplayPrompt(text)
  }
}
