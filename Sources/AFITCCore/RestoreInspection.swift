import Foundation
import SQLite3
import Darwin

/// Reusable B inspection. Reserved startup owns this object through checked physical closure.
final class RestoreInspection {
    private var handle: OpaquePointer?
    private let ticket: CatalogReservedTicket?
    init(file: URL, reservation: CatalogExclusiveReservation? = nil, readOnly: Bool = true) throws {
        ticket = try reservation.map { try CatalogRootRegistry.shared.beginReserved($0) }
        var opening: OpaquePointer?
        var parent = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(file.deletingLastPathComponent().path, &parent) != nil else {
            ticket?.closed(); throw RestoreValidationError.unsafeEntry
        }
        let path = String(cString: parent) + "/" + file.lastPathComponent
        let status = sqlite3_open_v2(path, &opening, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        handle = opening
        if status != SQLITE_OK || opening == nil {
            try close(); throw RestoreValidationError.schema
        }
    }
    deinit {
        if let handle, sqlite3_close(handle) == SQLITE_OK { ticket?.closed() }
        else if handle == nil { ticket?.closed() }
    }
    /// SQLITE_BUSY retains both the actual handle and its root ticket for explicit retry.
    func close() throws {
        if let handle {
            guard sqlite3_close(handle) == SQLITE_OK else { throw CatalogLifetimeError.closeBusy }
            self.handle = nil
        }
        ticket?.closed()
    }
    func inspect(manifest: BackupManifest, progress: @escaping @Sendable (RestoreValidationProgress) -> Void = { _ in }) throws {
        guard let db = handle else { throw ScanError.database }
        // The Apple SDK does not expose extension-loading APIs to this Swift module. Reject SQL function calls except
        // the fixed count aggregate used by this validator, and all attach/write actions.
        sqlite3_set_authorizer(db, { _, action, _, name, _, _ in
            if action == SQLITE_FUNCTION { return name.map { String(cString: $0).lowercased() == "count" ? SQLITE_OK : SQLITE_DENY } ?? SQLITE_DENY }
            return [SQLITE_SELECT, SQLITE_READ, SQLITE_PRAGMA].contains(action) ? SQLITE_OK : SQLITE_DENY
        }, nil)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(BackupManifest.maximumCatalogBytes))
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 65536); sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 32)
        sqlite3_limit(db, SQLITE_LIMIT_EXPR_DEPTH, 64); sqlite3_limit(db, SQLITE_LIMIT_VDBE_OP, 100000)
        let work = RestoreSQLWork(progress)
        sqlite3_progress_handler(db, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<RestoreSQLWork>.fromOpaque(pointer).takeUnretainedValue().tick()
        }, Unmanaged.passUnretained(work).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        // cell_size_check catches malformed b-tree pages in the untrusted file; sqlite3_db_config is variadic and unavailable here.
        try CatalogSchema.execute(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA cell_size_check=ON; PRAGMA mmap_size=0")
        try Task.checkCancellation()
        let dbVersion = try CatalogSchema.version(db)
        guard dbVersion == manifest.schemaVersion else { throw RestoreValidationError.schema }
        guard dbVersion == 3 || dbVersion == 4 else { throw ScanError.unsupportedSchema }
        guard try Self.schema(db) == Self.canonicalSchema(version: dbVersion) else { throw RestoreValidationError.schema }
        work.stage = .integrity
        do { try BackupFiles.validate(db, expectedVersion: dbVersion) } catch { try Task.checkCancellation(); throw RestoreValidationError.schema }
        let (revision, counts) = try BackupFiles.summary(db)
        guard revision == manifest.revision, counts == manifest.counts else { throw RestoreValidationError.domain }
        work.stage = .domain
        try RestoreDomain.validate(db, revision: revision, version: dbVersion, work: work)
        try Task.checkCancellation()
    }
    private static func schema(_ db: OpaquePointer) throws -> [String: String] {
        let statement = try PeopleSQL.statement(db, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name")
        defer { sqlite3_finalize(statement) }; var result: [String: String] = [:]; var count = 0; var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation(); count += 1; guard count <= 64 else { throw RestoreValidationError.schema }
            let values = (0...3).map { index in sqlite3_column_text(statement, Int32(index)).map { String(cString: $0) } ?? "NULL" }
            guard result.updateValue(values.joined(separator: "\n"), forKey: values[1]) == nil else { throw RestoreValidationError.schema }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { try Task.checkCancellation(); throw RestoreValidationError.schema }; return result
    }
    private static func canonicalSchema(version: Int) throws -> [String: String] {
        var handle: OpaquePointer?; guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let db = handle else { throw ScanError.database }
        var closed = false; defer { if !closed { sqlite3_close(db) } }
        for migration in CatalogSchema.migrations where migration.version <= version {
            try CatalogSchema.execute(db, migration.sql)
        }
        let value = try schema(db)
        guard sqlite3_close(db) == SQLITE_OK else { throw CatalogLifetimeError.closeBusy }; closed = true
        return value
    }
    /// Test-only internal borrow remains counted until the inspector physically closes.
    func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else { throw ScanError.database }; return try body(handle)
    }
}
final class RestoreSQLWork {
    let progress: @Sendable (RestoreValidationProgress) -> Void
    var stage: RestoreValidationStage = .schema
    private var instructions = 0
    private var nodes = 0
    private var items = 0
    private var rows = 0
    init(_ progress: @escaping @Sendable (RestoreValidationProgress) -> Void) { self.progress = progress }
    func tick() -> Int32 {
        instructions += 1000
        progress(RestoreValidationProgress(stage: stage, completed: instructions, total: nil, unit: .sqliteInstructions))
        return Task.isCancelled ? 1 : 0
    }
    func node() throws {
        nodes += 1
        if nodes % 256 == 0 {
            progress(RestoreValidationProgress(stage: stage, completed: nodes, total: nil, unit: .jsonNodes))
            try Task.checkCancellation()
        }
    }
    func item() throws {
        items += 1
        if items % 256 == 0 {
            progress(RestoreValidationProgress(stage: stage, completed: items, total: nil, unit: .domainItems))
            try Task.checkCancellation()
        }
    }
    func row() throws {
        try Task.checkCancellation(); rows += 1
        progress(RestoreValidationProgress(stage: stage, completed: rows, total: nil, unit: .rows))
        try Task.checkCancellation()
    }
}
enum RestoreDomain {
    static let keys: [String: Set<String>] = [
        "manifest": ["formatVersion","schemaVersion","createdAt","revision","counts","catalogBytes","catalogSHA256"],
        "counts": ["photos","people","currentFaces","manualFaceStates","negativePairs","deferrals","decisionEvents"],
        "photo": ["id","relativePath","dateAdded","contentVersion","previewPath","metadata","contentHash","missing","verifiedAt","analysis","captureDate"],
        "person": ["id","displayName","cover","exemplarRevision","mergedInto"],
        "key": ["photoID","contentVersion","detectorVersion","faceID"],
        "state": ["key","personID","isAnchor","notPerson","rejectedPeople","deferredPeople","deferred"],
        "geometry": ["id","rectangle","landmarks"], "analysis": ["status","detectorVersion","contentVersion","faces","reason"],
        "metadata": ["revision","size","modified"], "captureDate": ["localWallClock","sourceOffset","provenance"],
        "checkpoint": ["phase","discovered","processed","skipped","failed","enumerationFinished","message"],
        "decision": ["id","kind","before","after","createdPersonID","date","revision","undoOf","mergeResolutions"],
        "effect": ["people","face","faces"], "resolution": ["key","choice"]]
    static func shape(_ data: Data, context: String, work: RestoreSQLWork? = nil) throws {
        let limit = context == "manifest" ? BackupManifest.maximumManifestBytes : BackupManifest.maximumCatalogBytes
        guard data.count <= limit else { throw BackupError.limitExceeded }
        var elements = 0
        func walk(_ value: Any, _ context: String?, _ depth: Int) throws {
            elements += 1; guard depth <= 24 else { throw BackupError.limitExceeded }
            if let work { try work.node() }
            else if elements % 256 == 0 { try Task.checkCancellation() }
            if let object = value as? [String: Any] {
                guard let context, let allowed = keys[context], Set(object.keys).isSubset(of: allowed) else { throw RestoreValidationError.domain }
                for (name, child) in object {
                    let next: String?
                    switch name {
                    case "before", "after": next = "effect"
                    case "people": next = "person"
                    case "face": next = "state"
                    case "faces": next = context == "analysis" ? "geometry" : "state"
                    case "key", "cover": next = "key"
                    case "mergeResolutions": next = "resolution"
                    default: next = keys[name] != nil ? name : nil
                    }
                    try walk(child, next, depth + 1)
                }
            } else if let values = value as? [Any] { for value in values { try walk(value, context, depth + 1) } }
            else if let number = value as? NSNumber { guard number.doubleValue.isFinite else { throw RestoreValidationError.domain } }
            else if let text = value as? String { guard text.utf8.count <= 4096, !text.contains("\0") else { throw RestoreValidationError.domain } }
            else if !(value is NSNull) { throw RestoreValidationError.domain }
        }
        try Task.checkCancellation()
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        try Task.checkCancellation(); try walk(value, context, 0); try Task.checkCancellation()
    }
    static func rows<T: Decodable>(_ db: OpaquePointer, _ sql: String, context: String, work: RestoreSQLWork) throws -> [(String, String?, T)] {
        let statement = try PeopleSQL.statement(db, sql); defer { sqlite3_finalize(statement) }
        var values: [(String, String?, T)] = []; var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try work.row()
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard sqlite3_column_type(statement, 0) == SQLITE_BLOB, count > 0, count <= BackupManifest.maximumCatalogBytes,
                  let bytes = sqlite3_column_blob(statement, 0), let id = sqlite3_column_text(statement, 1) else { throw RestoreValidationError.domain }
            let data = Data(bytes: bytes, count: count); try shape(data, context: context, work: work)
            values.append((String(cString: id), sqlite3_column_text(statement, 2).map { String(cString: $0) }, try JSONDecoder().decode(T.self, from: data)))
            try Task.checkCancellation(); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { try Task.checkCancellation(); throw RestoreValidationError.domain }; return values
    }
    static func key(_ key: FaceKey) throws {
        guard key.contentVersion > 0, !key.detectorVersion.isEmpty, key.detectorVersion.utf8.count <= 256 else { throw RestoreValidationError.domain }
    }
    static func person(_ person: PersonRecord) throws {
        guard person.exemplarRevision > 0, !person.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              person.displayName.count <= 120, !person.displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw RestoreValidationError.domain }
        if let cover = person.cover { try key(cover) }
    }
    static func validate(_ db: OpaquePointer, revision: Int, version: Int = 3, work: RestoreSQLWork) throws {
        let personRows: [(String, String?, PersonRecord)] = try rows(db, "SELECT payload,id,NULL FROM people", context: "person", work: work)
        var people: [UUID: PersonRecord] = [:]
        for (id, _, record) in personRows {
            try work.item()
            try person(record)
            guard UUID(uuidString: id) == record.id, people.updateValue(record, forKey: record.id) == nil else { throw RestoreValidationError.domain }
        }
        func canonical(_ id: UUID) throws -> UUID {
            var next = id; var visited = Set<UUID>()
            while true {
                try work.item()
                guard visited.insert(next).inserted, let person = people[next] else { throw RestoreValidationError.domain }
                guard let target = person.mergedInto else { return next }; next = target
            }
        }
        for id in people.keys { _ = try canonical(id) }
        let photoRows: [(String, String?, PhotoIdentity)] = try rows(db, "SELECT payload,id,path FROM photos", context: "photo", work: work)
        var photos: [UUID: PhotoIdentity] = [:]; var expectedKeys = Set<FaceKey>()
        for (id, path, photo) in photoRows {
            try work.item()
            let parts = photo.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard UUID(uuidString: id) == photo.id, path == photo.relativePath, photo.contentVersion > 0,
                  photos.updateValue(photo, forKey: photo.id) == nil, !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), photo.dateAdded.timeIntervalSince1970.isFinite,
                  photo.analysis.contentVersion > 0, !photo.analysis.detectorVersion.isEmpty else { throw RestoreValidationError.domain }
            if let preview = photo.previewPath {
                guard !preview.isEmpty, preview != ".", preview != "..", !preview.contains("/"), !preview.contains("\\") else { throw RestoreValidationError.domain }
            }
            if let size = photo.metadata?.size, size < 0 { throw RestoreValidationError.domain }
            if let verified = photo.verifiedAt, !verified.timeIntervalSince1970.isFinite { throw RestoreValidationError.domain }
            if let modified = photo.metadata?.modified, !modified.timeIntervalSince1970.isFinite { throw RestoreValidationError.domain }
            if let hash = photo.contentHash {
                guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RestoreValidationError.domain }
            }
            var faces = Set<UUID>()
            for face in photo.analysis.faces {
            try work.item()
                guard faces.insert(face.id).inserted, face.rectangle.count == 4, face.rectangle.allSatisfy({ $0.isFinite }),
                      face.landmarks.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }) else { throw RestoreValidationError.domain }
                if photo.missing != true, photo.analysis.status == .successful, photo.analysis.contentVersion == photo.contentVersion,
                   PeopleSQL.validGeometry(face.rectangle) { expectedKeys.insert(FaceKey(photo: photo, face: face)) }
            }
        }
        let faceRows: [(String, String?, FaceKey)] = try rows(db, "SELECT payload,key,photo_id FROM current_faces", context: "key", work: work)
        var current = Set<FaceKey>()
        for (id, photoID, face) in faceRows {
            try work.item()
            try key(face)
            guard id == face.storageKey, UUID(uuidString: photoID ?? "") == face.photoID, current.insert(face).inserted else { throw RestoreValidationError.domain }
        }
        guard current == expectedKeys else { throw RestoreValidationError.domain }
        let stateRows: [(String, String?, ManualFaceState)] = try rows(db, "SELECT payload,key,person_id FROM manual_faces", context: "state", work: work)
        var states: [String: ManualFaceState] = [:]; var negatives = Set<String>(); var deferrals = Set<String>()
        for (id, personID, state) in stateRows {
            try work.item()
            try key(state.key)
            guard id == state.key.storageKey, personID.flatMap(UUID.init(uuidString:)) == state.personID,
                  states.updateValue(state, forKey: id) == nil else { throw RestoreValidationError.domain }
            if let person = state.personID { _ = try canonical(person) }
            for person in state.rejectedPeople { _ = try canonical(person); negatives.insert(id + "\n" + person.uuidString) }
            for person in state.deferredPeople { _ = try canonical(person); deferrals.insert(id + "\n" + person.uuidString) }
            if state.deferred { deferrals.insert(id + "\nface") }
            guard try PeopleSQL.scalar(db, "SELECT anchor FROM manual_faces WHERE key=?", strings: [id]) == (state.isAnchor ? 1 : 0) else { throw RestoreValidationError.domain }
            if current.contains(state.key) {
                if let person = state.personID {
                    let active = try canonical(person)
                    let rejected = try Set(state.rejectedPeople.map(canonical)); let deferred = try Set(state.deferredPeople.map(canonical))
                    guard !state.notPerson, !state.deferred, !rejected.contains(active), !deferred.contains(active) else { throw RestoreValidationError.domain }
                } else if state.isAnchor { throw RestoreValidationError.domain }
            }
        }
        guard try pairs(db, "SELECT face_key,person_id FROM pair_negatives", work: work) == negatives,
              try pairs(db, "SELECT face_key,scope FROM deferrals", work: work) == deferrals else { throw RestoreValidationError.domain }
        for person in people.values {
            try work.item()
            if let cover = person.cover, current.contains(cover) {
                guard let state = states[cover.storageKey], state.personID == person.id, state.isAnchor else { throw RestoreValidationError.domain }
            }
        }
        let decisions: [(String, String?, DecisionRecord)] = try rows(db, "SELECT payload,id,undo_of FROM decisions", context: "decision", work: work)
        var records: [UUID: DecisionRecord] = [:]
        for (id, undo, record) in decisions {
            try work.item()
            guard UUID(uuidString: id) == record.id, undo.flatMap(UUID.init(uuidString:)) == record.undoOf,
                  record.revision > 0, record.revision <= revision, record.date.timeIntervalSince1970.isFinite,
                  ["name","confirm","reject","unsure","unassign","not-person","rename","merge","undo"].contains(record.kind),
                  (record.kind == "undo") == (record.undoOf != nil), records.updateValue(record, forKey: record.id) == nil else { throw RestoreValidationError.domain }
            for effect in [record.before, record.after] {
            try work.item()
                guard effect.face == nil || effect.faces == nil else { throw RestoreValidationError.domain }
                for historical in effect.people { try work.item(); try person(historical) }
                for historical in effect.allFaces { try work.item(); try key(historical.key) }
            }
            for choice in record.mergeResolutions ?? [] { try work.item(); try key(choice.key) }
        }
        for record in records.values {
            try work.item()
            if let undo = record.undoOf {
                guard let target = records[undo], target.undoOf == nil, target.revision < record.revision else { throw RestoreValidationError.domain }
            }
        }
        let checkpoints: [(String, String?, ScanProgress)] = try rows(db, "SELECT payload,CAST(singleton AS TEXT),NULL FROM scan_checkpoint", context: "checkpoint", work: work)
        guard checkpoints.count <= 1 else { throw RestoreValidationError.domain }
        for (id, _, checkpoint) in checkpoints {
            guard id == "1", [checkpoint.discovered,checkpoint.processed,checkpoint.skipped,checkpoint.failed].allSatisfy({ $0 >= 0 }) else { throw RestoreValidationError.domain }
        }
        let binding = try PeopleSQL.statement(db, "SELECT payload FROM source_binding"); defer { sqlite3_finalize(binding) }
        let status = sqlite3_step(binding)
        if status == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(binding, 0), sqlite3_column_bytes(binding, 0) > 0 else { throw RestoreValidationError.domain }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(binding, 0)))
            let identity = try JSONDecoder().decode(String?.self, from: data)
            guard identity.map({ $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true, sqlite3_step(binding) == SQLITE_DONE else { throw RestoreValidationError.domain }
        } else if status != SQLITE_DONE { throw RestoreValidationError.domain }
        guard try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM scan_lease WHERE singleton=1 AND generation>=0") == 1,
              try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM catalog_revision WHERE singleton=1 AND revision>=0") == 1 else { throw RestoreValidationError.domain }
        if version >= 4 {
            guard try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM face_vectors") == 0,
                  try PeopleSQL.scalar(db, "SELECT COUNT(*) FROM photo_analysis_records") == 0 else { throw RestoreValidationError.domain }
            try validateSuppressionAndSeparation(db, work: work)
        }
    }
    private static func validateSuppressionAndSeparation(_ db: OpaquePointer, work: RestoreSQLWork) throws {
        let suppStmt = try PeopleSQL.statement(db, "SELECT face_key, photo_id, content_version, content_hash, created_at FROM face_suppression")
        defer { sqlite3_finalize(suppStmt) }
        var suppStatus = sqlite3_step(suppStmt)
        while suppStatus == SQLITE_ROW {
            try work.row()
            guard sqlite3_column_text(suppStmt, 0) != nil,
                  let photoIDText = sqlite3_column_text(suppStmt, 1),
                  UUID(uuidString: String(cString: photoIDText)) != nil,
                  sqlite3_column_int(suppStmt, 2) > 0,
                  let hashText = sqlite3_column_text(suppStmt, 3),
                  String(cString: hashText).utf8.count == 64,
                  sqlite3_column_double(suppStmt, 4).isFinite else {
                throw RestoreValidationError.domain
            }
            suppStatus = sqlite3_step(suppStmt)
        }
        guard suppStatus == SQLITE_DONE else { throw RestoreValidationError.domain }

        let sepStmt = try PeopleSQL.statement(db, "SELECT face_key_a, face_key_b, created_at FROM group_separations")
        defer { sqlite3_finalize(sepStmt) }
        var sepStatus = sqlite3_step(sepStmt)
        while sepStatus == SQLITE_ROW {
            try work.row()
            guard let keyAText = sqlite3_column_text(sepStmt, 0),
                  let keyBText = sqlite3_column_text(sepStmt, 1),
                  String(cString: keyAText) != String(cString: keyBText),
                  sqlite3_column_double(sepStmt, 2).isFinite else {
                throw RestoreValidationError.domain
            }
            sepStatus = sqlite3_step(sepStmt)
        }
        guard sepStatus == SQLITE_DONE else { throw RestoreValidationError.domain }
    }
    static func pairs(_ db: OpaquePointer, _ sql: String, work: RestoreSQLWork) throws -> Set<String> {
        let statement = try PeopleSQL.statement(db, sql); defer { sqlite3_finalize(statement) }
        var values = Set<String>(); var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try work.row()
            guard let key = sqlite3_column_text(statement, 0), let target = sqlite3_column_text(statement, 1),
                  values.insert(String(cString: key) + "\n" + String(cString: target)).inserted else { throw RestoreValidationError.domain }
            try Task.checkCancellation(); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { try Task.checkCancellation(); throw RestoreValidationError.domain }; return values
    }
}
