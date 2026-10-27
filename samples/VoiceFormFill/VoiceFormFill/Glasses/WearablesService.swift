/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import Foundation
import MWDATCore
import MWDATDisplay
import MWDATMockDevice
import MWDATSpeech
import UIKit

enum WearablesServiceError: LocalizedError {
  case speechUnavailable
  case sessionFailed(String)

  var errorDescription: String? {
    switch self {
    case .speechUnavailable:
      "Speech recognition is not available on this device."
    case .sessionFailed(let message):
      message
    }
  }
}

@MainActor
final class WearablesService {

  static let shared = WearablesService()

  /// Simulator and local dev use MockDeviceKit by default.
  let usesMockDevice: Bool = {
    #if targetEnvironment(simulator)
    true
    #else
    true
    #endif
  }()

  private(set) var statusMessage: String = "Idle"
  private(set) var mockDeviceID: String?
  private(set) var isSessionRunning = false

  private let wearables = Wearables.shared
  private var deviceSession: DeviceSession?
  private var speech: Speech?
  private var display: Display?
  private var mockGlasses: MockGlasses?

  private var speechTokens = ListenerTokenBag()
  private var displayTokens = ListenerTokenBag()
  private var sessionErrorTask: Task<Void, Never>?

  private var transcriptionContinuations: [UUID: AsyncStream<Transcription>.Continuation] = [:]
  private var speechStateContinuations: [UUID: AsyncStream<GlassesSpeechListeningState>.Continuation] = [:]
  private var speechListeningState: GlassesSpeechListeningState = .idle
  private var speechHasStarted = false
  private var displayIsStarted = false
  private var prefersLivePhoneASR = false
  private var liveSpeechBridge: PhoneLiveSpeechBridge?

  private init() {}

  func bootstrapMockEnvironmentIfNeeded() async {
    guard usesMockDevice else { return }
    let kit = MockDeviceKit.shared
    if kit.isEnabled {
      if mockGlasses == nil, let first = kit.pairedDevices.first {
        mockGlasses = first as? any MockGlasses
        mockDeviceID = first.deviceIdentifier
      }
      return
    }
    kit.enable()
    do {
      let glasses = try kit.pairGlasses(model: .metaRayBanDisplay)
      mockGlasses = glasses
      mockDeviceID = glasses.deviceIdentifier
      glasses.powerOn()
      glasses.unfold()
      glasses.don()
      glasses.services.speech.setTranscriptionSource(.injected)
      statusMessage = "Mock Meta Ray-Ban Display paired"
    } catch {
      statusMessage = "Mock pairing failed: \(error.localizedDescription)"
    }
  }

  func setMockSpeechSource(liveDeviceASR: Bool) {
    prefersLivePhoneASR = liveDeviceASR
    // Keep mock speech on injected text; live mic uses PhoneLiveSpeechBridge (see README).
    mockGlasses?.services.speech.setTranscriptionSource(.injected)
    Task { await applyLivePhoneSpeechBridge() }
  }

  func simulateTranscription(text: String, isFinal: Bool) {
    guard let id = mockDeviceID else { return }
    guard let glasses = mockGlasses else { return }
    glasses.services.speech.simulateTranscription(
      text: text,
      isFinal: isFinal,
      confidence: 1
    )
    _ = id
  }

  func mockDisplayPreviewView() -> UIView? {
    mockGlasses?.services.display.createPreviewView()
  }

  func setMockPoweredAndWorn(powered: Bool, worn: Bool) {
    guard let glasses = mockGlasses else { return }
    if powered {
      glasses.powerOn()
      glasses.unfold()
      if worn { glasses.don() } else { glasses.doff() }
    } else {
      glasses.doff()
      glasses.fold()
      glasses.powerOff()
    }
  }

  func startVoiceSession() async throws {
    if isSessionRunning { return }

    if usesMockDevice {
      await bootstrapMockEnvironmentIfNeeded()
    }

    let selector: any DeviceSelector
    if usesMockDevice {
      guard let mockDeviceID else {
        throw WearablesServiceError.sessionFailed(
          "Mock device is not paired yet. Open the mock panel or retry after pairing."
        )
      }
      selector = SpecificDeviceSelector(device: mockDeviceID)
    } else {
      let autoSelector = AutoDeviceSelector(
        wearables: wearables,
        filter: { $0.supportsDisplay() }
      )
      try await waitForActiveDevice(on: autoSelector)
      selector = autoSelector
    }

    let session: DeviceSession
    do {
      session = try wearables.createSession(deviceSelector: selector)
    } catch {
      throw WearablesServiceError.sessionFailed(error.localizedDescription)
    }

    deviceSession = session
    sessionErrorTask?.cancel()
    sessionErrorTask = Task { [weak self] in
      for await error in session.errorStream() {
        await MainActor.run {
          self?.statusMessage = error.localizedDescription
        }
      }
    }

    let started = Task {
      for await state in session.stateStream() {
        if state == .started { return true }
        if state == .stopped { return false }
      }
      return false
    }

    do throws(DeviceSessionError) {
      try session.start()
    } catch {
      started.cancel()
      deviceSession = nil
      throw WearablesServiceError.sessionFailed(error.localizedDescription)
    }

    guard await started.value else {
      throw WearablesServiceError.sessionFailed("Session stopped before starting.")
    }

    if try await wearables.checkPermissionStatus(.microphone) != .granted {
      guard try await wearables.requestPermission(.microphone) == .granted else {
        throw WearablesServiceError.sessionFailed("Microphone permission denied.")
      }
    }

    try attachSpeech(to: session)
    try attachDisplay(to: session)

    isSessionRunning = true
    await applyLivePhoneSpeechBridge()
    if !prefersLivePhoneASR {
      statusMessage = "Session running — speech and display ready"
    }
  }

  func stopVoiceSession() {
    stopLivePhoneSpeechBridge()
    speech?.stop()
    try? deviceSession?.removeSpeech()
    display?.stop()
    deviceSession?.stop()
    sessionErrorTask?.cancel()
    sessionErrorTask = nil
    speechTokens = ListenerTokenBag()
    displayTokens = ListenerTokenBag()
    speech = nil
    display = nil
    deviceSession = nil
    speechHasStarted = false
    displayIsStarted = false
    publishSpeechState(.idle)
    isSessionRunning = false
    statusMessage = "Session stopped"
  }

  func transcriptionStream() -> AsyncStream<Transcription> {
    AsyncStream { continuation in
      let id = UUID()
      transcriptionContinuations[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          self?.transcriptionContinuations.removeValue(forKey: id)
        }
      }
    }
  }

  func speechListeningStateStream() -> AsyncStream<GlassesSpeechListeningState> {
    AsyncStream { continuation in
      let id = UUID()
      speechStateContinuations[id] = continuation
      continuation.yield(speechListeningState)
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          self?.speechStateContinuations.removeValue(forKey: id)
        }
      }
    }
  }

  func sendDisplayPrompt(_ text: String) async {
    guard let display, displayIsStarted else { return }
    do {
      try await display.send(
        FlexBox(direction: .column, spacing: 12) {
          Text(text, style: .heading)
        }
        .padding(24)
        .background(.card)
      )
    } catch {
      statusMessage = "Display send failed: \(error.localizedDescription)"
    }
  }

  /// `AutoDeviceSelector` fills its active device from `devicesStream()` asynchronously.
  /// Wait until a display-capable device is eligible before `createSession`, or the SDK
  /// throws `noEligibleDevice`.
  private func applyLivePhoneSpeechBridge() async {
    stopLivePhoneSpeechBridge()
    guard prefersLivePhoneASR, isSessionRunning, usesMockDevice else { return }

    let bridge = PhoneLiveSpeechBridge { [weak self] text, isFinal in
      Task { @MainActor in
        self?.simulateTranscription(text: text, isFinal: isFinal)
      }
    }
    if let error = await bridge.start() {
      statusMessage = error
      return
    }
    liveSpeechBridge = bridge
    statusMessage = "Session running — live phone ASR → mock speech"
  }

  /// Closes the phone mic immediately. Invoked on the main thread from speech playback.
  func suspendLiveCapture() {
    liveSpeechBridge?.suspendCapture()
  }

  /// Opens a fresh recognition request after a prompt finishes.
  func resumeLiveCapture() {
    liveSpeechBridge?.resumeCapture()
  }

  private func stopLivePhoneSpeechBridge() {
    liveSpeechBridge?.stop()
    liveSpeechBridge = nil
  }

  private func waitForActiveDevice(on selector: AutoDeviceSelector) async throws {
    if selector.activeDevice != nil { return }
    for await deviceId in selector.activeDeviceStream() {
      if deviceId != nil { return }
    }
    throw WearablesServiceError.sessionFailed("No display-capable device available.")
  }

  private func attachSpeech(to session: DeviceSession) throws {
    publishSpeechState(.starting)
    let attached: Speech?
    do {
      attached = try session.addSpeech()
    } catch {
      publishSpeechState(.unavailable)
      throw WearablesServiceError.speechUnavailable
    }
    guard let speech = attached else {
      publishSpeechState(.unavailable)
      throw WearablesServiceError.speechUnavailable
    }
    self.speech = speech
    speechHasStarted = false

    speech.transcriptionPublisher.listen { [weak self] result in
      Task { @MainActor in
        self?.handleTranscription(result)
      }
    }.store(in: speechTokens)

    speech.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        self?.handleSpeechState(state)
      }
    }.store(in: speechTokens)

    speech.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        if error == .unavailable {
          self?.publishSpeechState(.unavailable)
        }
        self?.statusMessage = error.description
      }
    }.store(in: speechTokens)

    speech.start()
  }

  private func attachDisplay(to session: DeviceSession) throws {
    let capability = try session.addDisplay()
    display = capability

    capability.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        self?.displayIsStarted = (state == .started)
      }
    }.store(in: displayTokens)

    capability.start()
  }

  private func handleTranscription(_ result: MWDATSpeech.TranscriptionResult) {
    let confidence = result.confidence >= 0 ? result.confidence : nil
    let transcription = Transcription(
      text: result.text,
      isFinal: result.isFinal,
      confidence: confidence
    )
    for continuation in transcriptionContinuations.values {
      continuation.yield(transcription)
    }
  }

  private func handleSpeechState(_ state: SpeechState) {
    switch state {
    case .started:
      speechHasStarted = true
      publishSpeechState(.listening)
    case .stopped:
      if speechHasStarted {
        publishSpeechState(.stopped)
        speech?.start()
      }
    default:
      break
    }
  }

  private func publishSpeechState(_ state: GlassesSpeechListeningState) {
    speechListeningState = state
    for continuation in speechStateContinuations.values {
      continuation.yield(state)
    }
  }
}
