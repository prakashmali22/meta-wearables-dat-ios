/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 */

import UIKit

final class FormViewController: UIViewController, FormFieldBinding, UITextFieldDelegate {

  private let wearablesService: WearablesService
  private let spokenOutput: SpokenOutputProviding
  private let speechInput: SpeechInputProviding
  private let displayMirror: GlassesDisplayMirror

  private var coordinator: VoiceFormCoordinator!
  private var fieldDescriptors: [FormFieldDescriptor] = []
  private var textFieldsByID: [String: UITextField] = [:]
  private var orderedFieldIDs: [String] = []

  private lazy var keyboardDismissToolbar: UIToolbar = {
    let toolbar = UIToolbar()
    toolbar.sizeToFit()
    let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
    let done = UIBarButtonItem(
      title: "Done",
      style: .done,
      target: self,
      action: #selector(dismissKeyboard)
    )
    toolbar.items = [flex, done]
    return toolbar
  }()

  private let statusLabel = UILabel()
  private let fillButton = UIButton(type: .system)
  private let stopButton = UIButton(type: .system)
  private let stack = UIStackView()

  init(
    wearablesService: WearablesService,
    spokenOutput: SpokenOutputProviding,
    speechInput: SpeechInputProviding,
    displayMirror: GlassesDisplayMirror
  ) {
    self.wearablesService = wearablesService
    self.spokenOutput = spokenOutput
    self.speechInput = speechInput
    self.displayMirror = displayMirror
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Voice Form"
    view.backgroundColor = .systemBackground

    coordinator = VoiceFormCoordinator(
      speechInput: speechInput,
      spokenOutput: spokenOutput,
      displayMirror: displayMirror
    )
    coordinator.onStateChange = { [weak self] state in
      self?.statusLabel.text = state.status
      if let partial = state.partialAnswer, let id = state.currentFieldID {
        self?.setPreviewText(partial, forFieldID: id)
      }
    }

    configureLayout()
    buildFormFields()
  }

  private func configureLayout() {
    statusLabel.numberOfLines = 0
    statusLabel.font = .preferredFont(forTextStyle: .footnote)
    statusLabel.textColor = .secondaryLabel
    statusLabel.text = "Tap Fill by voice after pairing mock glasses."

    fillButton.setTitle("Fill by voice", for: .normal)
    fillButton.addTarget(self, action: #selector(fillTapped), for: .touchUpInside)

    stopButton.setTitle("Stop", for: .normal)
    stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)

    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false

    let buttonRow = UIStackView(arrangedSubviews: [fillButton, stopButton])
    buttonRow.axis = .horizontal
    buttonRow.spacing = 12
    buttonRow.distribution = .fillEqually

    let scroll = UIScrollView()
    scroll.keyboardDismissMode = .interactive
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let tapToDismiss = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
    tapToDismiss.cancelsTouchesInView = false
    scroll.addGestureRecognizer(tapToDismiss)
    view.addSubview(scroll)
    scroll.addSubview(stack)

    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(buttonRow)

    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
      stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
    ])
  }

  private func buildFormFields() {
    let specs: [(String, String, FormFieldKind, UIKeyboardType)] = [
      ("name", "Please Enter your Name", .text, .default),
      ("email", "Please Enter your Email", .email, .emailAddress),
      ("phone", "Please Enter your Phone", .phone, .phonePad),
      ("notes", "Please Enter some Notes", .notes, .default),
    ]

    for (index, spec) in specs.enumerated() {
      let label = UILabel()
      label.text = spec.1
      label.font = .preferredFont(forTextStyle: .subheadline)

      let field = UITextField()
      field.borderStyle = .roundedRect
      field.keyboardType = spec.3
      field.autocapitalizationType = spec.2 == .email ? .none : .words
      field.placeholder = spec.1
      field.delegate = self
      field.inputAccessoryView = keyboardDismissToolbar
      field.returnKeyType = index == specs.count - 1 ? .done : .next

      textFieldsByID[spec.0] = field
      orderedFieldIDs.append(spec.0)
      fieldDescriptors.append(FormFieldDescriptor(id: spec.0, label: spec.1, kind: spec.2))

      stack.addArrangedSubview(label)
      stack.addArrangedSubview(field)
    }
  }

  @objc private func dismissKeyboard() {
    view.endEditing(true)
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    guard
      let currentID = textFieldsByID.first(where: { $0.value === textField })?.key,
      let currentIndex = orderedFieldIDs.firstIndex(of: currentID)
    else {
      dismissKeyboard()
      return true
    }

    let nextIndex = currentIndex + 1
    if nextIndex < orderedFieldIDs.count {
      textFieldsByID[orderedFieldIDs[nextIndex]]?.becomeFirstResponder()
    } else {
      dismissKeyboard()
    }
    return true
  }

  @objc private func fillTapped() {
    dismissKeyboard()
    Task { @MainActor in
      fillButton.isEnabled = false
      defer { fillButton.isEnabled = true }
      do {
        try await wearablesService.startVoiceSession()
        coordinator.start(fields: fieldDescriptors, binding: self)
      } catch {
        statusLabel.text = error.localizedDescription
      }
    }
  }

  @objc private func stopTapped() {
    coordinator.stop()
    wearablesService.stopVoiceSession()
  }

  func setCommittedText(_ text: String, forFieldID id: String) {
    textFieldsByID[id]?.text = text
    textFieldsByID[id]?.textColor = .label
    textFieldsByID[id]?.sendActions(for: .editingChanged)
  }

  func setPreviewText(_ text: String?, forFieldID id: String) {
    guard let field = textFieldsByID[id] else { return }
    if let text, !text.isEmpty {
      field.text = text
      field.textColor = .tertiaryLabel
    } else if field.textColor == .tertiaryLabel {
      field.text = ""
      field.textColor = .label
    }
      debugPrint("field id \(id), text \(String(describing: text)), color \(String(describing: field.textColor))")
  }

  func focusField(id: String) {
    textFieldsByID[id]?.becomeFirstResponder()
  }
}
