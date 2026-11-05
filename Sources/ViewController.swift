import UIKit
import MetalKit

final class ViewController: UIViewController {
    private var renderer: Renderer!

    override func loadView() {
        view = MTKView(frame: UIScreen.main.bounds)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let mtk = view as! MTKView
        guard let r = Renderer(view: mtk) else { fatalError("Metal setup failed") }
        renderer = r
        mtk.delegate = r
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @objc private func tapped() { renderer.recenter() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
}
