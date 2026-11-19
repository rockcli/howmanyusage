import AppKit
import Foundation
import Testing
@testable import HowManyUsage

struct StatusIconTests {
    @Test @MainActor func fixedMenuIconUsesSystemTint() {
        let icon = Render.staticStatusBarsImage()
        #expect(icon.size == NSSize(width: 22, height: 12))
        #expect(icon.isTemplate)
        #expect(icon.tiffRepresentation != nil)
    }
}
