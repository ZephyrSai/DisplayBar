import Foundation
import Darwin

enum Memory {
    private static var pending = false

    /// Hands freed malloc pages back to macOS shortly after UI is torn down, so closing
    /// the menu or a window actually lowers the footprint instead of keeping the peak.
    static func trimSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            pending = false
            autoreleasepool {}
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
