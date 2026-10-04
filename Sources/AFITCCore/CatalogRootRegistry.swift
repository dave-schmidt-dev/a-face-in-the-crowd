import Foundation

public enum CatalogLifetimeError: Error, Sendable, Equatable {
    case busy, sharedCache, retired, invalidCapability, closeBusy
}

/// Process-local ownership only. Filesystem crash recovery is a separate contract.
final class CatalogRootRegistry: @unchecked Sendable {
    static let shared = CatalogRootRegistry()
    struct Owner: Sendable { let id: UUID; let root: String; let cache: String }
    private struct Root {
        var owners: Set<UUID> = []
        var constructing: Set<UUID> = []
        var operations: [UUID: Int] = [:]
        var retired: Set<UUID> = []
        var exclusive: UUID?
        var failedClose = false
        var reserved: Set<UUID> = []
        let cache: String
    }
    /// Construction is reserved before any create/protect/open/migrate effects.
    private let lock = NSLock()
    private var roots: [String: Root] = [:]
    private var cacheRoots: [String: String] = [:]

    static func canonical(_ url: URL) -> String {
        // Foundation leaves symlink parents unresolved when the final leaf does not exist.
        // Resolve the existing ancestor before appending the not-yet-created suffix.
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            suffix.append(ancestor.lastPathComponent); ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }
    func reserve(directory: URL, cache: URL, capability: CatalogExclusiveReservation? = nil) throws -> Owner {
        let root = Self.canonical(directory), cache = Self.canonical(cache)
        guard root != cache else { throw CatalogLifetimeError.sharedCache }
        lock.lock(); defer { lock.unlock() }
        if roots[root]?.failedClose == true { throw CatalogLifetimeError.busy }
        if let cacheOwner = cacheRoots[root], cacheOwner != root { throw CatalogLifetimeError.sharedCache }
        if roots[cache] != nil, cache != root { throw CatalogLifetimeError.sharedCache }
        if let bound = cacheRoots[cache], bound != root { throw CatalogLifetimeError.sharedCache }
        if let capability {
            guard capability.registry === self, capability.root == root,
                  roots[root]?.exclusive == capability.token,
                  roots[root]?.owners.isEmpty == true, roots[root]?.reserved.isEmpty == true,
                  roots[root]?.cache == cache else { throw CatalogLifetimeError.invalidCapability }
        } else if roots[root]?.exclusive != nil { throw CatalogLifetimeError.busy }
        if let existing = roots[root], existing.cache != cache { throw CatalogLifetimeError.sharedCache }
        let owner = Owner(id: UUID(), root: root, cache: cache)
        var value = roots[root] ?? Root(cache: cache)
        value.owners.insert(owner.id); value.constructing.insert(owner.id); roots[root] = value; cacheRoots[cache] = root
        return owner
    }
    /// Reserve startup without constructing or opening any catalog actor.
    func startup(directory: URL, cache: URL) throws -> CatalogExclusiveReservation {
        let root = Self.canonical(directory), cache = Self.canonical(cache)
        guard root != cache else { throw CatalogLifetimeError.sharedCache }
        lock.lock(); defer { lock.unlock() }
        guard roots[root] == nil else { throw CatalogLifetimeError.busy }
        guard cacheRoots[root] == nil, roots[cache] == nil, cacheRoots[cache] == nil else { throw CatalogLifetimeError.sharedCache }
        let token = UUID(); var value = Root(cache: cache); value.exclusive = token
        roots[root] = value; cacheRoots[cache] = root
        return CatalogExclusiveReservation(registry: self, root: root, token: token)
    }
    /// Account every reserved SQLite lifetime before opening its handle.
    func beginReserved(_ capability: CatalogExclusiveReservation) throws -> CatalogReservedTicket {
        lock.lock(); defer { lock.unlock() }
        guard capability.registry === self, var value = roots[capability.root],
              value.exclusive == capability.token, !value.failedClose,
              value.constructing.isEmpty else { throw CatalogLifetimeError.invalidCapability }
        let id = UUID(); value.reserved.insert(id); roots[capability.root] = value
        return CatalogReservedTicket(registry: self, root: capability.root, id: id)
    }
    fileprivate func endReserved(root: String, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard var value = roots[root] else { return }
        value.reserved.remove(id); roots[root] = value
    }
    fileprivate func abandonedReserved(root: String) {
        lock.lock(); defer { lock.unlock() }
        guard var value = roots[root] else { return }
        value.failedClose = true; roots[root] = value
    }
    func opened(_ owner: Owner) {
        lock.lock(); defer { lock.unlock() }
        guard var value = roots[owner.root], value.owners.contains(owner.id) else { return }
        value.constructing.remove(owner.id); roots[owner.root] = value
    }
    func begin(_ owner: Owner) throws -> CatalogOperationTicket {
        lock.lock(); defer { lock.unlock() }
        guard var value = roots[owner.root], value.owners.contains(owner.id),
              !value.retired.contains(owner.id) else { throw CatalogLifetimeError.retired }
        guard !value.failedClose, !value.constructing.contains(owner.id), value.exclusive == nil else { throw CatalogLifetimeError.busy }
        value.operations[owner.id, default: 0] += 1; roots[owner.root] = value
        return CatalogOperationTicket(registry: self, owner: owner)
    }
    fileprivate func end(_ owner: Owner) {
        lock.lock(); defer { lock.unlock() }
        guard var value = roots[owner.root], let count = value.operations[owner.id], count > 0 else { return }
        if count == 1 { value.operations.removeValue(forKey: owner.id) }
        else { value.operations[owner.id] = count - 1 }
        roots[owner.root] = value
    }
    func exclusive(_ owner: Owner) throws -> CatalogExclusiveReservation {
        lock.lock(); defer { lock.unlock() }
        guard var value = roots[owner.root], value.owners.contains(owner.id),
              !value.retired.contains(owner.id) else { throw CatalogLifetimeError.retired }
        guard !value.failedClose, value.exclusive == nil, value.owners == [owner.id], value.constructing.isEmpty, value.operations.isEmpty, value.reserved.isEmpty else {
            throw CatalogLifetimeError.busy
        }
        let token = UUID(); value.exclusive = token; roots[owner.root] = value
        return CatalogExclusiveReservation(registry: self, root: owner.root, token: token)
    }
    func validate(_ capability: CatalogExclusiveReservation, owner: Owner, retire: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard capability.registry === self, capability.root == owner.root,
              var value = roots[owner.root], value.exclusive == capability.token,
              value.owners == [owner.id], value.constructing.isEmpty, value.operations.isEmpty, value.reserved.isEmpty else { throw CatalogLifetimeError.invalidCapability }
        if retire { value.retired.insert(owner.id); roots[owner.root] = value }
        else if value.retired.contains(owner.id) { throw CatalogLifetimeError.retired }
    }
    func beginPrivileged(_ capability: CatalogExclusiveReservation, owner: Owner) throws -> CatalogOperationTicket {
        lock.lock(); defer { lock.unlock() }
        guard capability.registry === self, capability.root == owner.root,
              var value = roots[owner.root], value.exclusive == capability.token,
              value.owners == [owner.id], !value.retired.contains(owner.id), !value.failedClose,
              value.operations.isEmpty else { throw CatalogLifetimeError.invalidCapability }
        value.operations[owner.id] = 1; roots[owner.root] = value
        return CatalogOperationTicket(registry: self, owner: owner)
    }
    func closeFailed(_ owner: Owner) {
        lock.lock(); defer { lock.unlock() }
        guard var value = roots[owner.root] else { return }
        value.failedClose = true; value.retired.insert(owner.id); roots[owner.root] = value
    }
    /// Call only after sqlite3_close reports SQLITE_OK (or no handle was ever opened).
    func closed(_ owner: Owner) {
        lock.lock(); defer { lock.unlock() }
        guard var value = roots[owner.root] else { return }
        value.owners.remove(owner.id); value.constructing.remove(owner.id); value.operations.removeValue(forKey: owner.id); value.retired.remove(owner.id)
        roots[owner.root] = value; removeUnused(owner.root)
    }
    fileprivate func release(_ capability: CatalogExclusiveReservation) throws {
        lock.lock(); defer { lock.unlock() }
        guard capability.registry === self, var value = roots[capability.root],
              value.exclusive == capability.token else { throw CatalogLifetimeError.invalidCapability }
        // A busy physical close retains a terminal owner and its exclusive fence.
        guard value.retired.isEmpty, !value.failedClose, value.constructing.isEmpty, value.operations.isEmpty, value.reserved.isEmpty else { throw CatalogLifetimeError.closeBusy }
        value.exclusive = nil; roots[capability.root] = value; removeUnused(capability.root)
    }
    private func removeUnused(_ root: String) {
        guard let value = roots[root], value.owners.isEmpty, value.exclusive == nil else { return }
        roots.removeValue(forKey: root); cacheRoots.removeValue(forKey: value.cache)
    }
}

/// Internal opaque capability: no ordinary operation can acquire its privilege implicitly.
final class CatalogExclusiveReservation: @unchecked Sendable {
    fileprivate let registry: CatalogRootRegistry
    fileprivate let root: String
    fileprivate let token: UUID
    fileprivate init(registry: CatalogRootRegistry, root: String, token: UUID) {
        self.registry = registry; self.root = root; self.token = token
    }
    var directory: URL { URL(fileURLWithPath: root, isDirectory: true) }
    func release() throws { try registry.release(self) }
    // Deliberately no automatic release: an abandoned recovery fence must fail closed.
}
final class CatalogOperationTicket {
    private let registry: CatalogRootRegistry
    private let owner: CatalogRootRegistry.Owner
    fileprivate init(registry: CatalogRootRegistry, owner: CatalogRootRegistry.Owner) {
        self.registry = registry; self.owner = owner
    }
    deinit { registry.end(owner) }
}

/// Explicit completion is legal only after physical SQLite closure (or failed open without a handle).
final class CatalogReservedTicket {
    private let registry: CatalogRootRegistry
    private let root: String
    private let id: UUID
    private var completed = false
    fileprivate init(registry: CatalogRootRegistry, root: String, id: UUID) {
        self.registry = registry; self.root = root; self.id = id
    }
    func closed() { guard !completed else { return }; completed = true; registry.endReserved(root: root, id: id) }
    deinit { if !completed { registry.abandonedReserved(root: root) } }
}
