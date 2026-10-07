import SwiftUI
import AFITCCore

/// Names are not unique, so a short record suffix appears only where two active people share one.
enum PersonNames {
    static func isAmbiguous(_ person: PersonRecord, among people: [PersonRecord]) -> Bool {
        let key = person.displayName.lowercased()
        return people.filter { $0.mergedInto == nil && $0.displayName.lowercased() == key }.count > 1
    }
    static func label(_ person: PersonRecord, among people: [PersonRecord]) -> String {
        isAmbiguous(person, among: people) ? "\(person.displayName) · Record \(person.id.uuidString.prefix(4))" : person.displayName
    }
}

struct PersonChips: View {
    let people: [PersonRecord]
    @Binding var selected: Set<UUID>
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 160))]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(people.filter { $0.mergedInto == nil }) { person in
                Button {
                    if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(person.displayName).fixedSize(horizontal: false, vertical: true)
                            if PersonNames.isAmbiguous(person, among: people) {
                                Text("Record \(person.id.uuidString.prefix(4))").font(.caption)
                            }
                        }
                    }.foregroundStyle(selected.contains(person.id) ? tokens.onPrimary : tokens.primary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.vertical, 8).padding(.horizontal, 14)
                }
                .background(selected.contains(person.id) ? tokens.primary : tokens.surface,
                            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous)
                    .strokeBorder(tokens.controlBoundary, lineWidth: 1))
                .accessibilityIdentifier("search-person-\(person.id.uuidString)")
                .accessibilityAddTraits(selected.contains(person.id) ? .isSelected : [])
            }
        }
    }
}
