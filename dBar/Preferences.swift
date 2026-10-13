import Foundation

/// The meter's options, stored in UserDefaults and shared by the view (`@AppStorage`) and the
/// status item controller.
enum Preferences {
    static let showsLoudnessKey = "showsLoudness"
    static let measuresInBackgroundKey = "measuresLoudnessInBackground"

    /// Capture keeps running after the meter closes, so integrated loudness keeps accumulating.
    /// Only applies while loudness is shown.
    static var keepsMeasuringWhenClosed: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: showsLoudnessKey) && defaults.bool(forKey: measuresInBackgroundKey)
    }
}
