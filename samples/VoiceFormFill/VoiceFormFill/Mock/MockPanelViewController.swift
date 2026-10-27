/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import UIKit

final class MockPanelViewController: UIViewController {

  private let wearablesService: WearablesService

  private let statusLabel = UILabel()
  private let previewContainer = UIView()
  private let speechModeControl = UISegmentedControl(items: ["Inject text", "Live ASR"])
  private let injectField = UITextField()
  private let sendFinalButton = UIButton(type: .system)
  private let sendPartialButton = UIButton(type: .system)
  private let powerSwitch = UISwitch()
  private let wornSwitch = UISwitch()

  init(wearablesService: WearablesService) {
    self.wearablesService = wearablesService
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Mock Glasses"
    view.backgroundColor = .systemBackground
    layout()
    refreshPreview()
    speechModeControl.selectedSegmentIndex = 0
    speechModeControl.addTarget(self, action: #selector(speechModeChanged), for: .valueChanged)
    sendFinalButton.addTarget(self, action: #selector(sendFinal), for: .touchUpInside)
    sendPartialButton.addTarget(self, action: #selector(sendPartial), for: .touchUpInside)
    powerSwitch.addTarget(self, action: #selector(lifecycleChanged), for: .valueChanged)
    wornSwitch.addTarget(self, action: #selector(lifecycleChanged), for: .valueChanged)
    powerSwitch.isOn = true
    wornSwitch.isOn = true

    Task { @MainActor in
      await wearablesService.bootstrapMockEnvironmentIfNeeded()
      statusLabel.text = wearablesService.statusMessage
      refreshPreview()
    }
  }

  private func layout() {
    statusLabel.numberOfLines = 0
    statusLabel.font = .preferredFont(forTextStyle: .footnote)

    previewContainer.backgroundColor = .secondarySystemBackground
    previewContainer.layer.cornerRadius = 8
    previewContainer.translatesAutoresizingMaskIntoConstraints = false
    previewContainer.heightAnchor.constraint(equalToConstant: 220).isActive = true

    injectField.borderStyle = .roundedRect
    injectField.placeholder = "Type answer, then Send as speech"

    sendFinalButton.setTitle("Send final", for: .normal)
    sendPartialButton.setTitle("Send partial", for: .normal)

    let powerRow = labeledRow(title: "Powered on", control: powerSwitch)
    let wornRow = labeledRow(title: "Worn (don)", control: wornSwitch)

    let stack = UIStackView(arrangedSubviews: [
      statusLabel,
      UILabel.section("Display preview"),
      previewContainer,
      UILabel.section("Speech source"),
      speechModeControl,
      injectField,
      sendFinalButton,
      sendPartialButton,
      powerRow,
      wornRow,
    ])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    ])
  }

  private func labeledRow(title: String, control: UIControl) -> UIStackView {
    let label = UILabel()
    label.text = title
    let row = UIStackView(arrangedSubviews: [label, control])
    row.axis = .horizontal
    row.distribution = .equalSpacing
    return row
  }

  private func refreshPreview() {
    previewContainer.subviews.forEach { $0.removeFromSuperview() }
    guard let preview = wearablesService.mockDisplayPreviewView() else {
      let label = UILabel()
      label.text = "Pair mock Meta Ray-Ban Display to see preview"
      label.numberOfLines = 0
      label.textAlignment = .center
      label.translatesAutoresizingMaskIntoConstraints = false
      previewContainer.addSubview(label)
      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
        label.leadingAnchor.constraint(greaterThanOrEqualTo: previewContainer.leadingAnchor, constant: 8),
        label.trailingAnchor.constraint(lessThanOrEqualTo: previewContainer.trailingAnchor, constant: -8),
      ])
      return
    }
    preview.translatesAutoresizingMaskIntoConstraints = false
    previewContainer.addSubview(preview)
    NSLayoutConstraint.activate([
      preview.topAnchor.constraint(equalTo: previewContainer.topAnchor),
      preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
      preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
      preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
    ])
  }

  @objc private func speechModeChanged() {
    wearablesService.setMockSpeechSource(liveDeviceASR: speechModeControl.selectedSegmentIndex == 1)
  }

  @objc private func sendFinal() {
    let text = injectField.text ?? ""
    wearablesService.simulateTranscription(text: text, isFinal: true)
    injectField.text = ""
  }

  @objc private func sendPartial() {
    let text = injectField.text ?? ""
    wearablesService.simulateTranscription(text: text, isFinal: false)
  }

  @objc private func lifecycleChanged() {
    wearablesService.setMockPoweredAndWorn(powered: powerSwitch.isOn, worn: wornSwitch.isOn)
    statusLabel.text = wearablesService.statusMessage
  }
}

private extension UILabel {
  static func section(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: .headline)
    return label
  }
}
