import Foundation
import SQLite3

public enum DecisionError: Error, Sendable, Equatable {
    case staleFace, invalidName, unknownPerson, conflict, nothingToUndo, injectedFailure
    public var message: String {
        switch self {
        case .staleFace: return "This face changed or is unavailable. Refresh before deciding."
        case .invalidName: return "Enter a name between 1 and 120 characters."
        case .unknownPerson: return "This person is no longer available."
        case .conflict: return "A newer decision changed this item. Refresh before undoing."
        case .nothingToUndo: return "No decision is available to undo."
        case .injectedFailure: return "The decision was not saved."
        }
    }
}
/// Face identity binds the detected region to exact photo content and detector generation.
public struct FaceKey: Codable, Sendable, Hashable, Identifiable {
    public let photoID: UUID
    public let contentVersion: Int
    public let detectorVersion: String
    public let faceID: UUID
    public var id: String { storageKey }
    var storageKey: String { "\(photoID.uuidString)|\(contentVersion)|\(Data(detectorVersion.utf8).base64EncodedString())|\(faceID.uuidString)" }
    public init(photoID: UUID, contentVersion: Int, detectorVersion: String, faceID: UUID) {
        self.photoID = photoID; self.contentVersion = contentVersion
        self.detectorVersion = detectorVersion; self.faceID = faceID
    }
    public init(photo: PhotoIdentity, face: FaceGeometry) {
        self.init(photoID: photo.id, contentVersion: photo.contentVersion, detectorVersion: photo.analysis.detectorVersion, faceID: face.id)
    }
}
public struct PersonRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var cover: FaceKey?
    public var exemplarRevision: Int
    /// Archived source retains its UUID and provenance after a deliberate merge.
    public var mergedInto: UUID?
    public init(id: UUID = UUID(), displayName: String, cover: FaceKey? = nil, exemplarRevision: Int = 1) {
        self.id = id; self.displayName = displayName; self.cover = cover; self.exemplarRevision = exemplarRevision; self.mergedInto = nil
    }
}
extension PersonRecord {
    /// Epochs invalidate queued work; inverse actions compare domain state without rewinding them.
    func matchesDomain(_ other: PersonRecord) -> Bool {
        id == other.id && displayName == other.displayName && cover == other.cover && mergedInto == other.mergedInto
    }
}
public struct ManualFaceState: Codable, Sendable, Equatable {
    public let key: FaceKey
    public var personID: UUID?
    public var isAnchor: Bool
    public var notPerson: Bool
    public var rejectedPeople: Set<UUID>
    public var deferredPeople: Set<UUID>
    public var deferred: Bool
    public init(key: FaceKey, personID: UUID? = nil, isAnchor: Bool = false, notPerson: Bool = false,
                rejectedPeople: Set<UUID> = [], deferredPeople: Set<UUID> = [], deferred: Bool = false) {
        self.key = key; self.personID = personID; self.isAnchor = isAnchor; self.notPerson = notPerson
        self.rejectedPeople = rejectedPeople; self.deferredPeople = deferredPeople; self.deferred = deferred
    }
}
public struct FaceItem: Sendable, Identifiable {
    public let key: FaceKey
    public let photo: PhotoIdentity
    public let geometry: FaceGeometry
    public let state: ManualFaceState
    public var id: String { key.id }
}
public struct PersonSummary: Sendable, Identifiable {
    public let person: PersonRecord
    public let confirmedPhotoCount: Int
    public var id: UUID { person.id }
}
public struct PeopleSnapshot: Sendable {
    public let revision: Int
    public let people: [PersonSummary]
    public let faces: [FaceItem]
    public let undoID: UUID?
    public static let empty = PeopleSnapshot(revision: 0, people: [], faces: [], undoID: nil)
}
/// Typed wrapper; CatalogRepository retains the only writable SQLite connection.
public struct PeopleRepository: Sendable {
    let catalog: CatalogRepository
    public init(catalog: CatalogRepository) { self.catalog = catalog }
    public func snapshot() async throws -> PeopleSnapshot { try await catalog.peopleSnapshot() }
}

/// Converts upright Vision lower-left normalized coordinates into bounded upper-left raster pixels.
public enum FaceCropGeometry {
    public static func pixelRectangle(_ normalized: [Double], width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0, PeopleSQL.validGeometry(normalized) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let region = CGRect(x: normalized[0] * Double(width),
                            y: (1 - normalized[1] - normalized[3]) * Double(height),
                            width: normalized[2] * Double(width), height: normalized[3] * Double(height))
            .integral.intersection(bounds)
        guard !region.isNull, !region.isEmpty else { return nil }
        return region
    }
}

/// Shared SQL primitives are internal and always execute on the catalog actor or migration transaction.
enum PeopleSQL {
    static let schema = """
    CREATE TABLE catalog_revision(singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL);
    INSERT INTO catalog_revision VALUES(1,0);
    CREATE TABLE people(id TEXT PRIMARY KEY, payload BLOB NOT NULL);
    CREATE TABLE current_faces(key TEXT PRIMARY KEY, photo_id TEXT NOT NULL REFERENCES photos(id), payload BLOB NOT NULL);
    CREATE INDEX current_faces_photo ON current_faces(photo_id);
    CREATE TABLE manual_faces(key TEXT PRIMARY KEY, person_id TEXT REFERENCES people(id), anchor INTEGER NOT NULL, payload BLOB NOT NULL);
    CREATE INDEX manual_faces_person ON manual_faces(person_id);
    CREATE TABLE pair_negatives(face_key TEXT NOT NULL, person_id TEXT NOT NULL REFERENCES people(id), PRIMARY KEY(face_key, person_id));
    CREATE TABLE deferrals(face_key TEXT NOT NULL, scope TEXT NOT NULL, PRIMARY KEY(face_key, scope));
    CREATE TABLE decisions(id TEXT PRIMARY KEY, payload BLOB NOT NULL, undo_of TEXT UNIQUE REFERENCES decisions(id));
    """
    static func statement(_ db: OpaquePointer, _ sql: String, strings: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw CatalogSchema.failure(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, string) in strings.enumerated() {
            guard sqlite3_bind_text(result, Int32(index + 1), string, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(result); throw CatalogSchema.failure(db)
            }
        }
        return result
    }
    static func run(_ db: OpaquePointer, _ sql: String, strings: [String] = [], data: Data? = nil) throws {
        let statement = try statement(db, sql, strings: strings); defer { sqlite3_finalize(statement) }
        if let data {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let status = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(strings.count + 1), $0.baseAddress, Int32(data.count), transient) }
            guard status == SQLITE_OK else { throw CatalogSchema.failure(db) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CatalogSchema.failure(db) }
    }
    static func rows<T: Decodable>(_ db: OpaquePointer, _ sql: String, strings: [String] = []) throws -> [T] {
        let statement = try statement(db, sql, strings: strings); defer { sqlite3_finalize(statement) }
        var result: [T] = []; var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw ScanError.database }
            result.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: size)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CatalogSchema.failure(db) }
        return result
    }
    static func scalar(_ db: OpaquePointer, _ sql: String, strings: [String] = []) throws -> Int {
        let statement = try statement(db, sql, strings: strings); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CatalogSchema.failure(db) }
        let value = try CatalogCounters.integer(statement)
        guard value >= 0 else { throw CounterError.invalidStoredValue }
        return value
    }
    static func syncPhoto(_ db: OpaquePointer, _ photo: PhotoIdentity) throws {
        let previous: [FaceKey] = try rows(db, "SELECT payload FROM current_faces WHERE photo_id=?", strings: [photo.id.uuidString])
        let incoming = photo.missing != true && photo.analysis.status == .successful && photo.analysis.contentVersion == photo.contentVersion
            ? photo.analysis.faces.filter { validGeometry($0.rectangle) }.map { FaceKey(photo: photo, face: $0) } : []
        if Set(previous) != Set(incoming) {
            let affected: [PersonRecord] = try rows(db, "SELECT DISTINCT p.payload FROM people p JOIN manual_faces m ON m.person_id=p.id JOIN current_faces c ON c.key=m.key WHERE c.photo_id=? AND m.anchor=1", strings: [photo.id.uuidString])
            for var person in affected { person.exemplarRevision = try CatalogCounters.successor(person.exemplarRevision, minimum: 1); try writePerson(db, person) }
        }
        try run(db, "DELETE FROM current_faces WHERE photo_id=?", strings: [photo.id.uuidString])
        guard photo.missing != true, photo.analysis.status == .successful,
              photo.analysis.contentVersion == photo.contentVersion else { return }
        for face in photo.analysis.faces {
            guard validGeometry(face.rectangle) else { continue }
            let key = FaceKey(photo: photo, face: face)
            try run(db, "INSERT INTO current_faces(key,photo_id,payload) VALUES(?,?,?)", strings: [key.storageKey, photo.id.uuidString], data: JSONEncoder().encode(key))
        }
    }
    static func validGeometry(_ rectangle: [Double]) -> Bool {
        rectangle.count == 4 && rectangle.allSatisfy { $0.isFinite } && rectangle[0] >= 0 && rectangle[1] >= 0 &&
        rectangle[2] > 0 && rectangle[3] > 0 && rectangle[0] + rectangle[2] <= 1.000001 && rectangle[1] + rectangle[3] <= 1.000001
    }
    static func backfill(_ db: OpaquePointer) throws {
        let statement = try statement(db, "SELECT payload FROM photos")
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw ScanError.database }
            let photo = try JSONDecoder().decode(PhotoIdentity.self, from: Data(bytes: bytes, count: count))
            try syncPhoto(db, photo)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CatalogSchema.failure(db) }
    }
    static func person(_ db: OpaquePointer, _ id: UUID) throws -> PersonRecord {
        let people: [PersonRecord] = try rows(db, "SELECT payload FROM people WHERE id=?", strings: [id.uuidString])
        guard let person = people.first else { throw DecisionError.unknownPerson }; return person
    }
    static func faceState(_ db: OpaquePointer, _ key: FaceKey) throws -> ManualFaceState {
        let states: [ManualFaceState] = try rows(db, "SELECT payload FROM manual_faces WHERE key=?", strings: [key.storageKey])
        return states.first ?? ManualFaceState(key: key)
    }
    static func currentPhoto(_ db: OpaquePointer, _ key: FaceKey) throws -> PhotoIdentity {
        let photos: [PhotoIdentity] = try rows(db, "SELECT payload FROM photos WHERE id=?", strings: [key.photoID.uuidString])
        guard let photo = photos.first, photo.missing != true, photo.contentVersion == key.contentVersion,
              photo.analysis.contentVersion == key.contentVersion, photo.analysis.status == .successful,
              photo.analysis.detectorVersion == key.detectorVersion,
              let face = photo.analysis.faces.first(where: { $0.id == key.faceID }), validGeometry(face.rectangle),
              try scalar(db, "SELECT COUNT(*) FROM current_faces WHERE key=?", strings: [key.storageKey]) == 1 else { throw DecisionError.staleFace }
        return photo
    }
    static func writePerson(_ db: OpaquePointer, _ person: PersonRecord) throws {
        try run(db, "INSERT INTO people VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", strings: [person.id.uuidString], data: JSONEncoder().encode(person))
    }
    static func writeFace(_ db: OpaquePointer, _ state: ManualFaceState) throws {
        try run(db, "INSERT INTO manual_faces VALUES(?,NULLIF(?,''),?,?) ON CONFLICT(key) DO UPDATE SET person_id=excluded.person_id, anchor=excluded.anchor, payload=excluded.payload", strings: [state.key.storageKey, state.personID?.uuidString ?? "", state.isAnchor ? "1" : "0"], data: JSONEncoder().encode(state))
        // Empty assignment uses SQL NULL, not a fictional person foreign key.
        if state.personID == nil { try run(db, "UPDATE manual_faces SET person_id=NULL WHERE key=?", strings: [state.key.storageKey]) }
        try run(db, "DELETE FROM pair_negatives WHERE face_key=?", strings: [state.key.storageKey])
        for person in state.rejectedPeople { try run(db, "INSERT INTO pair_negatives VALUES(?,?)", strings: [state.key.storageKey, person.uuidString]) }
        try run(db, "DELETE FROM deferrals WHERE face_key=?", strings: [state.key.storageKey])
        for person in state.deferredPeople { try run(db, "INSERT INTO deferrals VALUES(?,?)", strings: [state.key.storageKey, person.uuidString]) }
        if state.deferred { try run(db, "INSERT INTO deferrals VALUES(?, 'face')", strings: [state.key.storageKey]) }
    }
}

extension CatalogRepository {
    public func peopleSnapshot() throws -> PeopleSnapshot {
        try peopleRead { db in
            let records: [PersonRecord] = try PeopleSQL.rows(db, "SELECT payload FROM people ORDER BY rowid")
            let summaries = try records.map { person in
                PersonSummary(person: person, confirmedPhotoCount: try PeopleSQL.scalar(db, "SELECT COUNT(DISTINCT c.photo_id) FROM current_faces c JOIN manual_faces m ON m.key=c.key WHERE m.person_id=?", strings: [person.id.uuidString]))
            }
            let keys: [FaceKey] = try PeopleSQL.rows(db, "SELECT payload FROM current_faces ORDER BY rowid")
            let faces = try keys.map { key -> FaceItem in
                let photo = try PeopleSQL.currentPhoto(db, key)
                return FaceItem(key: key, photo: photo, geometry: photo.analysis.faces.first { $0.id == key.faceID }!, state: try PeopleSQL.faceState(db, key))
            }
            let decisions: [DecisionRecord] = try PeopleSQL.rows(db, "SELECT d.payload FROM decisions d WHERE d.undo_of IS NULL AND NOT EXISTS(SELECT 1 FROM decisions u WHERE u.undo_of=d.id) ORDER BY d.rowid DESC LIMIT 1")
            return PeopleSnapshot(revision: try PeopleSQL.scalar(db, "SELECT revision FROM catalog_revision"), people: summaries, faces: faces, undoID: decisions.first?.id)
        }
    }
}
