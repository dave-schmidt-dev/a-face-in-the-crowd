import SwiftUI
import AFITCCore

struct PersonChips: View {
    let people: [PersonRecord]
    @Binding var selected: Set<UUID>
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], alignment: .leading, spacing: 12) {
            ForEach(people.filter { $0.mergedInto == nil }) { person in
                Button {
                    if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(person.displayName)
                            Text("Record \(person.id.uuidString.prefix(8))").font(.caption)
                        }
                    }.foregroundStyle(DesignTokens(scheme: scheme).primary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(8)
                }
                .background(DesignTokens(scheme: scheme).surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DesignTokens(scheme: scheme).border,
                    lineWidth: selected.contains(person.id) ? 2 : 1))
                .accessibilityIdentifier("search-person-\(person.id.uuidString)")
                .accessibilityAddTraits(selected.contains(person.id) ? .isSelected : [])
            }
        }
    }
}
