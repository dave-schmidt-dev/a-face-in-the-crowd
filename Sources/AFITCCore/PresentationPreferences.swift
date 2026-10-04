import Foundation

/// Input state only. Query snapshots, grants, paths, raster data and coverage never enter this type.
public struct PresentationPreferences: Codable, Sendable, Equatable {
    public var version = 1
    public var search = SearchInputPreferences()
    public var anchors: [String: UUID] = [:]
    public var drafts: [UUID: PersonNameDraft] = [:]
    public init() {}
    public func validated() throws {
        guard version == 1, search.selected.count <= 128, (1...64).contains(search.requestedPages),
              anchors.count <= 132, drafts.count <= 128 else { throw PresentationPreferenceError.bounds }
        for key in anchors.keys {
            guard ["Library", "People", "Search"].contains(key) ||
                (key.hasPrefix("Person-") && UUID(uuidString: String(key.dropFirst(7))) != nil) else { throw PresentationPreferenceError.corrupt }
        }
        for (id, draft) in drafts {
            guard id == draft.personID, draft.dirty, draft.baseRevision >= 1,
                  draft.baseName.count <= 120, !draft.ownerText.contains("\0"), !draft.baseName.contains("\0") else { throw PresentationPreferenceError.corrupt }
        }
    }
}
public struct SearchInputPreferences: Codable, Sendable, Equatable {
    public var mode = SearchMode.together
    public var selected: Set<UUID> = []
    public var requestedPages = 1
    public init() {}
}
public enum PersonDraftConflict: String, Codable, Sendable { case changed, unavailable }
public struct PersonNameDraft: Codable, Sendable, Equatable {
    public let personID: UUID
    public var baseName: String
    public var baseRevision: Int
    public var ownerText: String
    public var dirty: Bool
    public var conflict: PersonDraftConflict?
    public init(person: PersonRecord) {
        personID = person.id; baseName = person.displayName; baseRevision = person.exemplarRevision
        ownerText = person.displayName; dirty = false; conflict = nil
    }
    public mutating func edit(_ text: String) { ownerText = text; dirty = text != baseName }
    /// Refresh never overwrites dirty owner input or retargets it to a merged survivor.
    public mutating func reconcile(_ person: PersonRecord?) {
        guard let person, person.id == personID, person.mergedInto == nil else {
            if dirty { conflict = .unavailable }; return
        }
        if dirty {
            if person.displayName != baseName || person.exemplarRevision != baseRevision { conflict = .changed }
        } else {
            baseName = person.displayName; baseRevision = person.exemplarRevision; ownerText = person.displayName; conflict = nil
        }
    }
    public mutating func reviewAgainst(_ person: PersonRecord) {
        guard person.id == personID, person.mergedInto == nil else { conflict = .unavailable; return }
        baseName = person.displayName; baseRevision = person.exemplarRevision; conflict = nil
        dirty = ownerText != baseName
    }
}
public enum PresentationPreferenceError: Error, Sendable, Equatable {
    case bounds, corrupt, unsupported, unsafe, staleEpoch, resetting, io, injectedFailure
}
