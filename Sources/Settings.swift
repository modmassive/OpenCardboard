import Foundation

/// Defaults are approximate Cardboard v1 numbers. Everything is editable in-app.
struct LensSettings: Codable, Equatable {
    var ipdMM: Float = 64
    var lensSeparationMM: Float = 60
    var screenToLensMM: Float = 42
    var k1: Float = 0.441
    var k2: Float = 0.156
}

final class SettingsStore {
    static let shared = SettingsStore()
    private let d = UserDefaults.standard

    var slot: Int {
        get { min(max(d.integer(forKey: "slot"), 0), 2) }
        set { d.set(newValue, forKey: "slot") }
    }

    func load(_ slot: Int) -> LensSettings {
        if let data = d.data(forKey: "preset\(slot)"),
           let s = try? JSONDecoder().decode(LensSettings.self, from: data) { return s }
        return LensSettings()
    }

    func save(_ s: LensSettings, slot: Int) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: "preset\(slot)") }
    }
}
