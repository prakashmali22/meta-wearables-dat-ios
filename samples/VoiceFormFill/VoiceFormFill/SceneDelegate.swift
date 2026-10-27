/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import MWDATCore
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let wearablesService = WearablesService.shared
    let spokenOutput = SpokenOutput(allowSpeakerWhenNoBluetooth: wearablesService.usesMockDevice)
    spokenOutput.prepareForSpeech = {
      let suspend = {
        WearablesService.shared.suspendLiveCapture()
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated(suspend)
      } else {
        DispatchQueue.main.sync {
          MainActor.assumeIsolated(suspend)
        }
      }
    }
    spokenOutput.finishSpeech = {
      await WearablesService.shared.resumeLiveCapture()
    }
    let speechInput = GlassesSpeechInput(wearablesService: wearablesService)
    let displayMirror = GlassesDisplayMirror(wearablesService: wearablesService)

    let formVC = FormViewController(
      wearablesService: wearablesService,
      spokenOutput: spokenOutput,
      speechInput: speechInput,
      displayMirror: displayMirror
    )
    let mockVC = MockPanelViewController(wearablesService: wearablesService)

    let formNav = UINavigationController(rootViewController: formVC)
    formNav.tabBarItem = UITabBarItem(title: "Form", image: UIImage(systemName: "doc.text"), tag: 0)

    let mockNav = UINavigationController(rootViewController: mockVC)
    mockNav.tabBarItem = UITabBarItem(
      title: "Mock",
      image: UIImage(systemName: "eyeglasses"),
      tag: 1
    )

    let tabBar = UITabBarController()
    tabBar.viewControllers = [formNav, mockNav]

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = tabBar
    window.makeKeyAndVisible()
    self.window = window

    Task { @MainActor in
      await wearablesService.bootstrapMockEnvironmentIfNeeded()
    }

    for urlContext in connectionOptions.urlContexts {
      handle(url: urlContext.url)
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      handle(url: context.url)
    }
  }

  private func handle(url: URL) {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else {
      return
    }
    Task {
      _ = try? await Wearables.shared.handleUrl(url)
    }
  }
}
