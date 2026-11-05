import UIKit

final class SettingsPanel: UIView {
    var onChange: ((LensSettings, Bool) -> Void)?   // (settings, isFinal)
    var onRecenter: (() -> Void)?
    var onClose: (() -> Void)?
    var onForceTest: ((Bool) -> Void)?
    var statusProvider: (() -> String)?

    private var settings: LensSettings
    private var slot: Int
    private var rows: [(WritableKeyPath<LensSettings, Float>, UISlider, UILabel, String)] = []
    private let statusLabel = UILabel()
    private var timer: Timer?

    init(settings: LensSettings, slot: Int) {
        self.settings = settings
        self.slot = slot
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.82)
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func label(_ text: String, size: CGFloat = 13) -> UILabel {
        let l = UILabel()
        l.text = text
        l.textColor = .white
        l.font = .systemFont(ofSize: size)
        return l
    }

    private func build() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24)
        ])

        stack.addArrangedSubview(label("Settings (long-press anywhere to close)", size: 15))

        let seg = UISegmentedControl(items: ["Preset 1", "Preset 2", "Preset 3"])
        seg.selectedSegmentIndex = slot
        seg.addAction(UIAction { [weak self, weak seg] _ in
            guard let self = self, let seg = seg else { return }
            self.slot = seg.selectedSegmentIndex
            SettingsStore.shared.slot = self.slot
            self.settings = SettingsStore.shared.load(self.slot)
            self.refreshControls()
            self.onChange?(self.settings, true)
        }, for: .valueChanged)
        stack.addArrangedSubview(seg)

        addRow(stack, "IPD (mm)", \.ipdMM, 50, 80, "%.1f")
        addRow(stack, "Lens sep (mm)", \.lensSeparationMM, 45, 80, "%.1f")
        addRow(stack, "Screen-lens (mm)", \.screenToLensMM, 20, 70, "%.1f")
        addRow(stack, "k1", \.k1, 0, 1, "%.3f")
        addRow(stack, "k2", \.k2, 0, 1, "%.3f")

        let testRow = UIStackView()
        testRow.spacing = 8
        let sw = UISwitch()
        sw.addAction(UIAction { [weak self, weak sw] _ in
            self?.onForceTest?(sw?.isOn ?? false)
        }, for: .valueChanged)
        testRow.addArrangedSubview(label("Force test scene"))
        testRow.addArrangedSubview(sw)
        stack.addArrangedSubview(testRow)

        let buttons = UIStackView()
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }
        buttons.addArrangedSubview(button("Recenter") { [weak self] in self?.onRecenter?() })
        buttons.addArrangedSubview(button("Reset preset") { [weak self] in
            guard let self = self else { return }
            self.settings = LensSettings()
            SettingsStore.shared.save(self.settings, slot: self.slot)
            self.refreshControls()
            self.onChange?(self.settings, true)
        })
        buttons.addArrangedSubview(button("Close") { [weak self] in self?.onClose?() })
        stack.addArrangedSubview(buttons)

        statusLabel.numberOfLines = 0
        statusLabel.textColor = .green
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(statusLabel)
    }

    private func addRow(_ stack: UIStackView, _ title: String,
                        _ kp: WritableKeyPath<LensSettings, Float>,
                        _ lo: Float, _ hi: Float, _ fmt: String) {
        let name = label(title)
        name.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let slider = UISlider()
        slider.minimumValue = lo
        slider.maximumValue = hi
        slider.value = settings[keyPath: kp]
        let val = label(String(format: fmt, slider.value))
        val.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        val.textAlignment = .right
        val.widthAnchor.constraint(equalToConstant: 56).isActive = true

        slider.addAction(UIAction { [weak self, weak slider, weak val] _ in
            guard let self = self, let slider = slider, let val = val else { return }
            self.settings[keyPath: kp] = slider.value
            val.text = String(format: fmt, slider.value)
            SettingsStore.shared.save(self.settings, slot: self.slot)
            self.onChange?(self.settings, false)
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.onChange?(self.settings, true)
        }, for: [.touchUpInside, .touchUpOutside])

        let row = UIStackView(arrangedSubviews: [name, slider, val])
        row.spacing = 8
        row.alignment = .center
        stack.addArrangedSubview(row)
        rows.append((kp, slider, val, fmt))
    }

    private func refreshControls() {
        for (kp, slider, val, fmt) in rows {
            slider.value = settings[keyPath: kp]
            val.text = String(format: fmt, slider.value)
        }
    }

    private func updateStatus() { statusLabel.text = statusProvider?() ?? "" }

    func show() {
        isHidden = false
        updateStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    func hide() {
        isHidden = true
        timer?.invalidate()
        timer = nil
    }
}
