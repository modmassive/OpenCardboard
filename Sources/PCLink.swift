import Foundation
import Network
import simd

/// The phone listens on a TCP port; the PC connects (Wi-Fi, USB hotspot, or a usbmuxd tunnel).
/// The listener restarts itself after failures and when the network changes.
final class PCLink {
    private let queue = DispatchQueue(label: "pclink", qos: .userInteractive)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var restartWork: DispatchWorkItem?
    private var port: UInt16 = 9000
    private var failCount = 0
    private var firstPath = true

    private var conn: NWConnection?
    private var buffer = Data()
    private var helloData: Data?
    private var pingTimer: DispatchSourceTimer?
    private var closeReason = ""            // queue-only

    private let lock = NSLock()
    private var _connected = false
    private var _state = "starting"
    private var _rtt = 0.0
    private var _lastClose = ""

    var onStreamConfig: ((StreamConfig) -> Void)?
    var onVideoFrame: ((VideoFrameHeader, Data) -> Void)?

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    var stateText: String { lock.lock(); defer { lock.unlock() }; return _state }
    var rttMs: Double { lock.lock(); defer { lock.unlock() }; return _rtt }
    var lastCloseReason: String { lock.lock(); defer { lock.unlock() }; return _lastClose }

    private func setState(_ s: String, connected: Bool? = nil) {
        lock.lock(); _state = s; if let c = connected { _connected = c }; lock.unlock()
    }

    // MARK: listener

    func start(port: UInt16) {
        self.port = port
        queue.async {
            self.createListener()
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] _ in
                guard let self = self else { return }
                if self.firstPath { self.firstPath = false; return }
                self.scheduleRestart(delay: 1.5)      // network changed (cable plugged, hotspot on, ...)
            }
            m.start(queue: self.queue)
            self.pathMonitor = m
        }
    }

    /// Call when the app returns to the foreground.
    func ensureListening() {
        queue.async { if !self.isConnected { self.scheduleRestart(delay: 0.2) } }
    }

    private func scheduleRestart(delay: Double) {
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isConnected else { return }
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            self.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.createListener() }
        }
        restartWork = w
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func createListener() {
        listener?.cancel()
        browser?.cancel()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            let useService = failCount < 2   // if advertising keeps failing, listen without it
            if useService { l.service = NWListener.Service(type: "_opencardboard._tcp") }
            l.stateUpdateHandler = { [weak self, weak l] st in
                guard let self = self, let l = l, l === self.listener else { return }
                switch st {
                case .ready:
                    self.failCount = 0
                    if !self.isConnected { self.setState("listening") }
                case .failed(let err):
                    self.failCount += 1
                    if !self.isConnected { self.setState("listener failed (\(err)); retrying") }
                    self.scheduleRestart(delay: 2.0)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l

            if useService {
                // Browsing the same service type helps iOS show the Local Network prompt.
                let b = NWBrowser(for: .bonjour(type: "_opencardboard._tcp", domain: nil), using: .tcp)
                b.stateUpdateHandler = { _ in }
                b.browseResultsChangedHandler = { _, _ in }
                b.start(queue: queue)
                browser = b
            }
        } catch {
            failCount += 1
            if !isConnected { setState("listen error: \(error); retrying") }
            scheduleRestart(delay: 2.0)
        }
    }

    // MARK: connection

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        buffer.removeAll()
        closeReason = ""
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self, c === self.conn else { return }
            switch st {
            case .ready:
                self.setState("PC connected", connected: true)
                if let h = self.helloData { self.sendRaw(makeFrame(.hello, h)) }
                self.startPing()
            case .failed(let err):
                if self.closeReason.isEmpty { self.closeReason = "failed: \(err)" }
                self.handleClosed()
            case .cancelled:
                self.handleClosed()
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func handleClosed() {
        let reason = closeReason.isEmpty ? "unknown" : closeReason
        lock.lock(); _lastClose = reason; lock.unlock()
        setState("PC disconnected (\(reason))", connected: false)
        stopPing()
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self = self, c === self.conn else { return }
            if let d = data, !d.isEmpty {
                self.buffer.append(d)
                self.parse(c)
            }
            if let error = error { self.closeReason = "recv: \(error)"; c.cancel(); return }
            if done { self.closeReason = "PC closed it"; c.cancel(); return }
            self.receive(c)
        }
    }

    private func parse(_ c: NWConnection) {
        while buffer.count >= headerSize {
            var r = ByteReader(buffer)
            let magic = r.get(UInt32.self)
            let type = r.get(UInt16.self)
            _ = r.get(UInt16.self)
            let len = Int(r.get(UInt32.self))
            if magic != protocolMagic || len > (64 << 20) {
                closeReason = "bad data"
                c.cancel()
                return
            }
            if buffer.count < headerSize + len { return }
            let payload = buffer.subdata(in: headerSize..<(headerSize + len))
            buffer.removeSubrange(0..<(headerSize + len))
            if let t = MsgType(rawValue: type) { handle(t, payload) }
        }
    }

    private func handle(_ t: MsgType, _ p: Data) {
        switch t {
        case .streamConfig:
            if let cfg = StreamConfig(p) { onStreamConfig?(cfg) }
        case .videoFrame:
            if let (h, d) = parseVideoFrame(p) { onVideoFrame?(h, d) }
        case .ping:
            sendRaw(makeFrame(.pong, p))
        case .pong:
            if p.count >= 8 {
                var r = ByteReader(p)
                let sent = r.get(UInt64.self)
                let now = DispatchTime.now().uptimeNanoseconds
                lock.lock(); _rtt = Double(now &- sent) / 1e6; lock.unlock()
            }
        default: break
        }
    }

    private func startPing() {
        stopPing()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            var w = ByteWriter()
            w.put(DispatchTime.now().uptimeNanoseconds)
            self?.sendRaw(makeFrame(.ping, w.data))
        }
        t.resume()
        pingTimer = t
    }

    private func stopPing() { pingTimer?.cancel(); pingTimer = nil }

    private func sendRaw(_ d: Data) {
        queue.async { [weak self] in
            self?.conn?.send(content: d, completion: .contentProcessed({ _ in }))
        }
    }

    func updateHello(_ h: Hello) {
        let d = h.encode()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.helloData = d
            if self.isConnected { self.sendRaw(makeFrame(.hello, d)) }
        }
    }

    func sendPose(seq: UInt32, time: Double, rotation: simd_float3x3) {
        guard isConnected else { return }
        sendRaw(makeFrame(.pose, encodePose(seq: seq, time: time, rotation: rotation)))
    }

    func sendRequestKeyframe() {
        guard isConnected else { return }
        sendRaw(makeFrame(.requestKeyframe, Data()))
    }
}

func localIPv4Addresses() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: ifa.ifa_name)
        if name == "lo0" { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            result.append("\(name) \(String(cString: host))")
        }
    }
    return result
}
