import Foundation

extension Double {
    /// Formats a duration in seconds as "H:MM:SS" or "M:SS".
    var playerTimeString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
