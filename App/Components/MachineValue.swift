import SwiftUI

extension View {
    /// Stable raw state key (an enum case name) for UI automation, read through
    /// `XCUIElement.value`. Debug builds only: a Release build never exposes implementation
    /// vocabulary, and VoiceOver never speaks the key after the human label.
    @ViewBuilder func machineValue(_ key: String) -> some View {
        #if DEBUG
        accessibilityValue(key)
        #else
        self
        #endif
    }
}
