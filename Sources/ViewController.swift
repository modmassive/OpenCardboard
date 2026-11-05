import UIKit
import MetalKit

final class ViewController: UIViewController, UIGestureRecognizerDelegate {
    private var renderer: Renderer!
    private var panel: SettingsPanel!

    override func loadView() {
        view = MTKView(frame: UIScreen.main.bounds)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let mtk = view as! MTKView
        guard let r = Renderer(view: mtk) else { fatalError("Metal setup failed") }
        renderer = r
        mtk.delegate = r

        let slot = SettingsStore.shared.slot
        let s = SettingsStore.shared.load(slot)
        r.setLens(s, notify: true)

        panel = SettingsPanel(settings: s, slot: slot)
        panel.isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onChange = { [weak self] s, final in self?.renderer.setLens(s, notify: final) }
        panel.onRecenter = { [weak self] in self?.renderer.recenter() }
        panel.onForceTest = { [weak self] on in self?.renderer.forceTest = on }
        panel.onClose = { [weak self] in self?.panel.hide() }
        panel.statusProvider = { [weak self] in self?.renderer.statusText() ?? "" }
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.widthAnchor.constraint(equalToConstant: 440)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 1.0
        hold.delegate = self
        view.addGestureRecognizer(hold)
    }

    @objc private func tapped() { renderer.recenter() }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        if panel.isHidden { panel.show() } else { panel.hide() }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if !panel.isHidden, let v = touch.view, v.isDescendant(of: panel) { return false }
        return true
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
}
