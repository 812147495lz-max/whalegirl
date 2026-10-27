import AppKit
import WhaleCore
import os

@MainActor
extension AppCoordinator {
    var quietMode: Bool {
        get { UserDefaults.standard.bool(forKey: "quietMode") }
        set { UserDefaults.standard.set(newValue, forKey: "quietMode") }
    }

    var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }

    var userScale: Double {
        get {
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: "userScaleFormatVersion") >= 3 {
                let saved = defaults.double(forKey: "userScale")
                return saved == 0 ? 0.9 : DisplayGeometry.clampedPreferenceScale(saved)
            }

            // Previous releases stored absolute scale values up to 130%.
            // Normalize them, then make the new default 90% of the old appearance.
            let previous = defaults.object(forKey: "userScale") as? Double
            let previousFormat = defaults.integer(forKey: "userScaleFormatVersion")
            let normalized = DisplayGeometry.migratedScale(from: previous)
            let migrated = (previous == nil || (previousFormat >= 2 && abs(normalized - 1.0) < 0.001))
                ? 0.9
                : normalized
            defaults.set(migrated, forKey: "userScale")
            defaults.set(3, forKey: "userScaleFormatVersion")
            return migrated
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(DisplayGeometry.clampedPreferenceScale(newValue), forKey: "userScale")
            defaults.set(3, forKey: "userScaleFormatVersion")
        }
    }

    var displayScale: Double { userScale * 1.3 }
}
