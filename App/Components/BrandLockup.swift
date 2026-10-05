import SwiftUI

/// Typographic stand-in for the A / Face / in the / Crowd lockup (07-DESIGN-SYSTEM.md).
/// System heavy condensed type only: no bundled fonts and no film-derived artwork. Emphasis on
/// Face and Crowd, a restrained red/blue mix and small optical offsets; "in the" stays legible.
/// Read as one heading so VoiceOver says the full product name once.
struct BrandLockup: View {
    @Environment(\.tokens) private var tokens
    @ScaledMetric(relativeTo: .largeTitle) private var display: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: -6) {
            Text("A").font(.title.weight(.black)).foregroundStyle(tokens.brandRed).padding(.leading, 18)
            Text("Face").font(.system(size: display, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(tokens.primary)
            Text("in the").font(.title3.weight(.heavy)).fontWidth(.condensed)
                .foregroundStyle(tokens.textPrimary).padding(.leading, 26)
            Text("Crowd").font(.system(size: display, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(tokens.brandRed).padding(.leading, 6)
            Rectangle().fill(tokens.brandRed).frame(width: 56, height: 4).padding(.top, 14)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A Face in the Crowd")
        .accessibilityAddTraits(.isHeader)
    }
}
