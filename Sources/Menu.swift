import UIKit

// One menu model, two front ends: the in-headset menu (drawn into a texture, driven by the Xbox
// controller through the PC) and the touch panel (SettingsPanel) for setup with the phone in your hand.

enum MenuKind {
    case slider(min: Float, max: Float, step: Float, fmt: String)
    case toggle
    case choice([String])
    case action
}

final class MenuItem {
    let title: String
    let kind: MenuKind
    let get: () -> Float
    let set: (Float) -> Void
    let perform: () -> Void

    init(_ title: String, _ kind: MenuKind,
         get: @escaping () -> Float = { 0 },
         set: @escaping (Float) -> Void = { _ in },
         perform: @escaping () -> Void = {}) {
        self.title = title
        self.kind = kind
        self.get = get
        self.set = set
        self.perform = perform
    }

    func valueText() -> String {
        switch kind {
        case .slider(_, _, _, let fmt): return String(format: fmt, get())
        case .toggle: return get() > 0.5 ? "On" : "Off"
        case .choice(let opts):
            if opts.isEmpty { return "" }
            return opts[min(max(Int(get().rounded()), 0), opts.count - 1)]
        case .action: return "Press A"
        }
    }
}

struct MenuTab {
    let title: String
    var items: [MenuItem]
    var infoRows: (() -> [(String, String)])? = nil
}

final class MenuController {
    var tabs: [MenuTab] = []
    private(set) var tabIndex = 0
    private(set) var rowIndex = 0
    var dirty = true
    var lastInputTime = CACurrentMediaTime()
    var onOpenChanged: ((Bool) -> Void)?

    var isOpen = false {
        didSet {
            if oldValue != isOpen {
                dirty = true
                lastInputTime = CACurrentMediaTime()
                if isOpen { tabIndex = 0; rowIndex = 0; prev = PadState(); holdDir = 0 }
                onOpenChanged?(isOpen)
            }
        }
    }

    var currentTabHasInfo: Bool {
        tabIndex < tabs.count && tabs[tabIndex].infoRows != nil
    }

    private var prev = PadState()
    private var prevDirs = (up: false, down: false, left: false, right: false)
    private var holdDir = 0          // 1 up, 2 down, 3 left, 4 right
    private var holdStart = 0.0
    private var lastRepeat = 0.0

    private var items: [MenuItem] {
        tabIndex < tabs.count ? tabs[tabIndex].items : []
    }

    // MARK: input

    func handle(_ s: PadState) {
        guard isOpen else { return }
        lastInputTime = CACurrentMediaTime()
        let up = (s.buttons & 0x0001) != 0 || s.ly > 20000
        let down = (s.buttons & 0x0002) != 0 || s.ly < -20000
        let left = (s.buttons & 0x0004) != 0 || s.lx < -20000
        let right = (s.buttons & 0x0008) != 0 || s.lx > 20000
        let pressed = s.buttons & ~prev.buttons

        if up && !prevDirs.up { move(-1); beginHold(1) }
        if down && !prevDirs.down { move(1); beginHold(2) }
        if left && !prevDirs.left { adjust(-1, fast: false); beginHold(3) }
        if right && !prevDirs.right { adjust(1, fast: false); beginHold(4) }
        let stillHeld = (holdDir == 1 && up) || (holdDir == 2 && down) || (holdDir == 3 && left) || (holdDir == 4 && right)
        if !stillHeld { holdDir = 0 }
        prevDirs = (up, down, left, right)

        if (pressed & 0x1000) != 0 { activate() }          // A
        if (pressed & 0x2000) != 0 { isOpen = false }      // B
        if (pressed & 0x0100) != 0 { switchTab(-1) }       // LB
        if (pressed & 0x0200) != 0 { switchTab(1) }        // RB
        prev = s
        dirty = true
    }

    /// Key repeat while a direction is held. Call every frame.
    func tick(_ now: Double) {
        guard isOpen, holdDir != 0 else { return }
        if now - lastInputTime > 0.6 { holdDir = 0; return }     // link went quiet
        let held = now - holdStart
        if held < 0.4 { return }
        let interval = held > 1.5 ? 0.04 : 0.1
        if now - lastRepeat < interval { return }
        lastRepeat = now
        switch holdDir {
        case 1: move(-1)
        case 2: move(1)
        case 3: adjust(-1, fast: held > 1.5)
        case 4: adjust(1, fast: held > 1.5)
        default: break
        }
    }

    private func beginHold(_ dir: Int) {
        holdDir = dir
        holdStart = CACurrentMediaTime()
        lastRepeat = holdStart
    }

    private func move(_ dir: Int) {
        let n = items.count
        if n == 0 { return }
        rowIndex = (rowIndex + dir + n) % n
        dirty = true
    }

    private func switchTab(_ dir: Int) {
        let n = tabs.count
        if n == 0 { return }
        tabIndex = (tabIndex + dir + n) % n
        rowIndex = 0
        dirty = true
    }

    private func adjust(_ dir: Int, fast: Bool) {
        guard rowIndex < items.count else { return }
        let it = items[rowIndex]
        switch it.kind {
        case .slider(let mn, let mx, let st, _):
            let step = st * (fast ? 5 : 1)
            var v = it.get() + Float(dir) * step
            v = (v / st).rounded() * st
            it.set(min(mx, max(mn, v)))
        case .toggle:
            it.set(dir > 0 ? 1 : 0)
        case .choice(let opts):
            let i = Int(it.get().rounded()) + dir
            it.set(Float(min(max(i, 0), max(opts.count - 1, 0))))
        case .action:
            break
        }
        dirty = true
    }

    private func activate() {
        guard rowIndex < items.count else { return }
        let it = items[rowIndex]
        switch it.kind {
        case .toggle: it.set(it.get() > 0.5 ? 0 : 1)
        case .choice(let opts):
            if !opts.isEmpty { it.set(Float((Int(it.get().rounded()) + 1) % opts.count)) }
        case .action: it.perform()
        case .slider: break
        }
        dirty = true
    }

    // MARK: drawing (1280 x 800, premultiplied RGBA, uploaded to a texture by the renderer)

    func makeImage() -> CGImage? {
        let W: CGFloat = 1280, H: CGFloat = 800
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: fmt)
        let accent = UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1.0)
        let gray = UIColor(white: 0.65, alpha: 1.0)

        let img = renderer.image { _ in
            UIColor(white: 0.04, alpha: 0.93).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerRadius: 36).fill()

            func text(_ s: String, _ rect: CGRect, size: CGFloat, color: UIColor = .white,
                      weight: UIFont.Weight = .regular, align: NSTextAlignment = .left) {
                let p = NSMutableParagraphStyle()
                p.alignment = align
                p.lineBreakMode = .byTruncatingTail
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: size, weight: weight),
                    .foregroundColor: color,
                    .paragraphStyle: p
                ]
                (s as NSString).draw(in: rect, withAttributes: attrs)
            }

            let n = max(tabs.count, 1)
            let tabW = (W - 48) / CGFloat(n)
            for (i, t) in tabs.enumerated() {
                let rect = CGRect(x: 24 + CGFloat(i) * tabW, y: 18, width: tabW - 8, height: 64)
                if i == tabIndex {
                    accent.setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: 16).fill()
                }
                text(t.title, CGRect(x: rect.minX, y: rect.minY + 12, width: rect.width, height: 44),
                     size: 34, weight: i == tabIndex ? .bold : .regular, align: .center)
            }

            var y: CGFloat = 104
            if tabIndex < tabs.count {
                let tab = tabs[tabIndex]
                for (i, it) in tab.items.enumerated() {
                    let rowRect = CGRect(x: 24, y: y, width: W - 48, height: 52)
                    if i == rowIndex {
                        accent.withAlphaComponent(0.35).setFill()
                        UIBezierPath(roundedRect: rowRect, cornerRadius: 12).fill()
                    }
                    text(it.title, CGRect(x: 44, y: y + 8, width: 560, height: 40), size: 32)
                    switch it.kind {
                    case .slider(let mn, let mx, _, _):
                        let frac = CGFloat(max(0, min(1, (it.get() - mn) / max(mx - mn, 0.0001))))
                        let track = CGRect(x: 640, y: y + 21, width: 330, height: 10)
                        UIColor(white: 0.3, alpha: 1).setFill()
                        UIBezierPath(roundedRect: track, cornerRadius: 5).fill()
                        accent.setFill()
                        UIBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: track.width * frac, height: 10),
                                     cornerRadius: 5).fill()
                        text(it.valueText(), CGRect(x: 985, y: y + 8, width: 255, height: 40), size: 32, align: .right)
                    default:
                        text(it.valueText(), CGRect(x: 640, y: y + 8, width: 600, height: 40), size: 32,
                             color: i == rowIndex ? .white : UIColor(white: 0.8, alpha: 1), align: .right)
                    }
                    y += 56
                }
                if let info = tab.infoRows {
                    for (k, v) in info() {
                        text(k, CGRect(x: 44, y: y + 4, width: 420, height: 36), size: 30, color: gray)
                        text(v, CGRect(x: 470, y: y + 4, width: 770, height: 36), size: 30, align: .right)
                        y += 42
                    }
                }
            }
            text("D-pad move / change     A select     B close     LB RB tabs     hold LB+RB close",
                 CGRect(x: 24, y: H - 54, width: W - 48, height: 36), size: 25, color: gray, align: .center)
        }
        return img.cgImage
    }
}
