import UIKit

/// Touch version of the same menu, for setup with the phone in your hand (long-press to open).
final class SettingsPanel: UIView {
    var tabsProvider: (() -> [MenuTab])?
    var onClose: (() -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var refreshers: [() -> Void] = []
    private var infoLabels: [(UILabel, () -> [(String, String)])] = []
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.88)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
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
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func label(_ text: String, size: CGFloat = 14, bold: Bool = false) -> UILabel {
        let l = UILabel()
        l.text = text
        l.textColor = .white
        l.font = .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return l
    }

    private func refreshAll(except idx: Int?) {
        for (i, r) in refreshers.enumerated() where i != idx { r() }
    }

    func rebuild() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        refreshers = []
        infoLabels = []
        let tabs = tabsProvider?() ?? []

        stack.addArrangedSubview(label("OpenCardboard settings  (long-press to close)", size: 15, bold: true))

        for tab in tabs {
            let header = label(tab.title.uppercased(), size: 13, bold: true)
            header.textColor = UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1)
            stack.addArrangedSubview(header)

            for it in tab.items {
                let idx = refreshers.count
                switch it.kind {
                case .slider(let mn, let mx, let st, _):
                    let name = label(it.title)
                    name.widthAnchor.constraint(equalToConstant: 130).isActive = true
                    let slider = UISlider()
                    slider.minimumValue = mn
                    slider.maximumValue = mx
                    slider.value = it.get()
                    let val = label(it.valueText())
                    val.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                    val.textAlignment = .right
                    val.widthAnchor.constraint(equalToConstant: 80).isActive = true
                    slider.addAction(UIAction { [weak self, weak slider, weak val] _ in
                        guard let self = self, let slider = slider, let val = val else { return }
                        it.set((slider.value / st).rounded() * st)
                        val.text = it.valueText()
                        self.refreshAll(except: idx)
                    }, for: .valueChanged)
                    refreshers.append { [weak slider, weak val] in
                        slider?.value = it.get()
                        val?.text = it.valueText()
                    }
                    let row = UIStackView(arrangedSubviews: [name, slider, val])
                    row.spacing = 8
                    row.alignment = .center
                    stack.addArrangedSubview(row)

                case .toggle:
                    let name = label(it.title)
                    let sw = UISwitch()
                    sw.isOn = it.get() > 0.5
                    sw.addAction(UIAction { [weak self, weak sw] _ in
                        guard let self = self, let sw = sw else { return }
                        it.set(sw.isOn ? 1 : 0)
                        self.refreshAll(except: idx)
                    }, for: .valueChanged)
                    refreshers.append { [weak sw] in sw?.isOn = it.get() > 0.5 }
                    let row = UIStackView(arrangedSubviews: [name, UIView(), sw])
                    row.spacing = 8
                    row.alignment = .center
                    stack.addArrangedSubview(row)

                case .choice(let opts):
                    let name = label(it.title)
                    stack.addArrangedSubview(name)
                    let seg = UISegmentedControl(items: opts)
                    seg.selectedSegmentIndex = Int(it.get().rounded())
                    seg.addAction(UIAction { [weak self, weak seg] _ in
                        guard let self = self, let seg = seg else { return }
                        it.set(Float(seg.selectedSegmentIndex))
                        self.refreshAll(except: idx)
                    }, for: .valueChanged)
                    refreshers.append { [weak seg] in seg?.selectedSegmentIndex = Int(it.get().rounded()) }
                    stack.addArrangedSubview(seg)

                case .action:
                    let b = UIButton(type: .system)
                    b.setTitle(it.title, for: .normal)
                    b.contentHorizontalAlignment = .leading
                    b.addAction(UIAction { [weak self] _ in
                        it.perform()
                        self?.refreshAll(except: nil)
                    }, for: .touchUpInside)
                    refreshers.append {}
                    stack.addArrangedSubview(b)
                }
            }

            if let rows = tab.infoRows {
                let l = UILabel()
                l.numberOfLines = 0
                l.textColor = .green
                l.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                stack.addArrangedSubview(l)
                infoLabels.append((l, rows))
            }
        }

        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        stack.addArrangedSubview(close)
    }

    private func updateInfo() {
        for (l, rows) in infoLabels {
            l.text = rows().map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        }
    }

    func show() {
        isHidden = false
        rebuild()
        updateInfo()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateInfo()
        }
    }

    func hide() {
        isHidden = true
        timer?.invalidate()
        timer = nil
    }
}
