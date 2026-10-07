import Foundation
import AFITCCore

/// Human decisions retain their session guard, committed-success boundary and shared
/// saved-analysis refresh. No decision starts a source scan or admits model work.
extension AppServices {
    @discardableResult public func decide(_ decision: ManualDecision) async -> Bool {
        guard !isSavingDecision, let decisionService, let operation = catalogSession.begin("decision") else { return false }
        isSavingDecision = true; decisionError = nil
        defer { if sessionIsCurrent(operation.session) { isSavingDecision = false }; catalogSession.finish(operation) }
        let work = Task { try await decisionService.apply(decision) }
        catalogSession.bind(operation) { work.cancel() }
        do { _ = try await work.value }
        catch {
            if sessionIsCurrent(operation.session) { decisionError = (error as? DecisionError)?.message ?? "The decision was not saved. Try again." }
            return false
        }
        // A committed write remains successful even if its retired session must not publish.
        guard sessionIsCurrent(operation.session) else { return true }
        #if DEBUG
        armCommittedRefreshFault(merge: false)
        #endif
        await refreshPeople()
        await faceGroups.refresh()
        guard sessionIsCurrent(operation.session) else { return true }
        if peopleRefreshWarning != nil { peopleRefreshWarning = "Decision saved. People view could not be refreshed; refresh before another decision." }
        return true
    }
    public func previewMerge(source: UUID, survivor: UUID) async -> MergePreview? {
        guard let decisionService, let operation = catalogSession.begin("merge-preview") else { return nil }
        defer { catalogSession.finish(operation) }
        clearDecisionError()
        let errorGeneration = decisionErrorGeneration
        let work = Task { try await decisionService.previewMerge(source: source, survivor: survivor) }
        catalogSession.bind(operation) { work.cancel() }
        do {
            let preview = try await work.value
            return sessionIsCurrent(operation.session) ? preview : nil
        } catch {
            if sessionIsCurrent(operation.session), decisionErrorGeneration == errorGeneration {
                decisionError = (error as? DecisionError)?.message ?? "Merge preview unavailable. Refresh and try again."
            }
            return nil
        }
    }
    @discardableResult public func merge(_ preview: MergePreview, resolutions: [MergeResolution]) async -> Bool {
        guard !isSavingDecision, let decisionService, let operation = catalogSession.begin("merge") else { return false }
        isSavingDecision = true; decisionError = nil
        defer { if sessionIsCurrent(operation.session) { isSavingDecision = false }; catalogSession.finish(operation) }
        let work = Task { try await decisionService.merge(preview, resolutions: resolutions) }
        catalogSession.bind(operation) { work.cancel() }
        do { _ = try await work.value }
        catch {
            if sessionIsCurrent(operation.session) { decisionError = (error as? DecisionError)?.message ?? "Merge was not saved. Refresh and try again." }
            return false
        }
        guard sessionIsCurrent(operation.session) else { return true }
        #if DEBUG
        armCommittedRefreshFault(merge: true)
        #endif
        await refreshPeople()
        await faceGroups.refresh()
        guard sessionIsCurrent(operation.session) else { return true }
        if peopleRefreshWarning != nil { peopleRefreshWarning = "Merge saved. People view could not be refreshed; refresh before another decision." }
        return true
    }
    public func undoDecision() async {
        guard !isSavingDecision, let undoService, let id = peopleSnapshot.undoID,
              let operation = catalogSession.begin("undo") else { return }
        isSavingDecision = true; decisionError = nil
        defer { if sessionIsCurrent(operation.session) { isSavingDecision = false }; catalogSession.finish(operation) }
        let work = Task { try await undoService.undo(id) }
        catalogSession.bind(operation) { work.cancel() }
        do {
            try await work.value
            guard sessionIsCurrent(operation.session) else { return }
            await refreshPeople()
            await faceGroups.refresh()
        } catch {
            if sessionIsCurrent(operation.session) { decisionError = (error as? DecisionError)?.message ?? "Undo was not saved. Try again." }
        }
    }

}
