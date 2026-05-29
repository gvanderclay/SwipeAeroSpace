import Foundation

enum SettingKey {
    static let threshold = "threshold"
    static let wrap = "wrap"
    static let natural = "natural"
    static let skipEmpty = "skip-empty"
    static let fingers = "fingers"
    static let multiSwipe = "multiSwipe"
    static let maxSteps = "maxSteps"
    static let swipeUpOverview = "swipeUpOverview"
    static let swipeUpFingers = "swipeUpFingers"
    static let menuBarExtraIsInserted = "menuBarExtraIsInserted"

    static let legacyNatural = "natrual"
}

enum SettingDefaults {
    static let threshold: Double = 1.0
    static let wrap = false
    static let natural = true
    static let skipEmpty = false
    static let fingers = FingerCount.three.rawValue
    static let multiSwipe = true
    static let maxSteps = 5
    static let swipeUpOverview = true
    static let swipeUpFingers = FingerCount.three.rawValue
    static let menuBarExtraIsInserted = true
}

enum FingerCount: String, CaseIterable, Identifiable {
    case three = "Three"
    case four = "Four"

    var id: String { rawValue }
    var count: Int { self == .three ? 3 : 4 }
    var displayName: String { rawValue }
}

enum AppSettings {
    static func migrateLegacyKeys(userDefaults: UserDefaults = .standard) {
        if userDefaults.object(forKey: SettingKey.natural) == nil,
            let old = userDefaults.object(forKey: SettingKey.legacyNatural)
        {
            userDefaults.set(old, forKey: SettingKey.natural)
            userDefaults.removeObject(forKey: SettingKey.legacyNatural)
        }
    }
}
