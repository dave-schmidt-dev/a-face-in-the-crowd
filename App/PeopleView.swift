import SwiftUI
import AFITCCore

struct PeopleView: View {
    @ObservedObject var services: AppServices
    let surface: Color
    let secondary: Color
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedFace: FaceItem?
    var body: some View {
        let coverFaces = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0) })
        VStack(alignment: .leading, spacing: 24) {
            Text("People").font(.largeTitle.bold())
            DecisionStatus(services: services)
            #if DEBUG
            if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-refresh-burst") {
                Text(services.syntheticRefreshProbe).accessibilityIdentifier("people-refresh-probe")
            }
            #endif
            if !services.hasLoadedPeopleSnapshot {
                Text(services.peopleRefreshWarning == nil ? "Opening People data" : "People data unavailable. Cached Library photos remain available.")
                    .accessibilityIdentifier("people-data-unavailable")
            } else {
            if services.peopleSnapshot.people.allSatisfy({ $0.person.mergedInto != nil }) {
                Text("Name an unidentified face to add a person.").foregroundStyle(secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(services.peopleSnapshot.people.filter { $0.person.mergedInto == nil }) { summary in
                        NavigationLink(value: summary.id) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let key = summary.person.cover, let cover = coverFaces[key] {
                                    FacePreview(services: services, face: cover, wholePhoto: false)
                                } else { Label("Cover unavailable", systemImage: "person.crop.square") }
                                Text(summary.person.displayName).font(.headline)
                                Text("\(summary.confirmedPhotoCount) confirmed photos").font(.subheadline)
                                Text("Record \(summary.id.uuidString.prefix(8))").font(.caption)
                                Text("Possible matching unavailable").font(.caption).foregroundStyle(secondary)
                            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .padding(16).background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityIdentifier("person-\(summary.id.uuidString)")
                    }
                }
            }
            Text("Unidentified faces").font(.title2.bold())
            Text("Names apply only to the face you select. Detection may miss people.").foregroundStyle(secondary)
            let unidentified = services.peopleSnapshot.faces.filter { $0.state.personID == nil && !$0.state.notPerson }
            Text("\(unidentified.count) unidentified faces").font(.subheadline).accessibilityIdentifier("unidentified-count")
            if unidentified.isEmpty { Text("No unidentified detected faces in the current index.").foregroundStyle(secondary) }
            faceGrid(unidentified, identifier: "unidentified-face")
            let falseDetections = services.peopleSnapshot.faces.filter { $0.state.notPerson }
            if !falseDetections.isEmpty {
                DisclosureGroup("False detections") {
                    Text("Only regions you explicitly marked Not a person appear here.").font(.subheadline)
                    faceGrid(falseDetections, identifier: "false-detection-face")
                }
            }
            }
        }
        .sheet(item: $selectedFace) { face in
            NavigationStack { ManualFaceView(services: services, face: face, initialPerson: nil) }
        }
        .task { if services.peopleRefreshWarning == nil { await services.refreshPeople() } }
    }
    private func faceGrid(_ faces: [FaceItem], identifier: String) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(faces) { face in
                Button { selectedFace = face } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        FacePreview(services: services, face: face, wholePhoto: false)
                        Text(face.state.notPerson ? "False detection" :
                             (face.state.deferred || !face.state.deferredPeople.isEmpty ? "Deferred face" : "Unidentified face"))
                        Text(face.photo.relativePath).font(.caption).lineLimit(2)
                    }.padding(16).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil)
                    .accessibilityIdentifier(identifier)
            }
        }
    }
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 180))]
    }
}

struct DecisionStatus: View {
    @ObservedObject var services: AppServices
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = services.decisionError { Text(message).accessibilityIdentifier("decision-error") }
            if let warning = services.peopleRefreshWarning {
                Text(warning).accessibilityIdentifier("people-refresh-warning")
                Button("Refresh People") { Task { await services.refreshPeople() } }
                    .frame(minHeight: 48).disabled(services.isSavingDecision).accessibilityIdentifier("refresh-people")
            }
            if services.peopleSnapshot.undoID != nil {
                Button("Undo last decision") { Task { await services.undoDecision() } }
                    .frame(minHeight: 48).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("decision-undo")
            }
            if services.isSavingDecision { ProgressView("Saving decision") }
            else if services.isRefreshingPeople { ProgressView("Refreshing People").accessibilityIdentifier("people-refresh-progress") }
        }
    }
}

/// All raster reads/crops use bounded orientation-normalized cached previews off the UI executor.
struct FacePreview: View {
    @ObservedObject var services: AppServices
    let face: FaceItem
    let wholePhoto: Bool
    @State private var image: UIImage?
    @State private var loading = true
    @State private var decodeToken = UUID()
    @State private var releasedForMemory = false
    private var decodeRequest: String {
        "\(face.key.id)|\(wholePhoto)|\(services.previewURL(face.photo)?.path ?? "")"
    }
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: wholePhoto ? 360 : 160)
                    .accessibilityLabel(wholePhoto ? "Whole photo context" : "Selected face crop")
            } else if loading { ProgressView("Opening preview") }
            else if releasedForMemory {
                Label("Preview released to free memory", systemImage: "photo")
                    .accessibilityLabel("Preview released to free memory")
                    .accessibilityIdentifier("face-preview-released")
            } else { Label("Preview unavailable offline", systemImage: "photo") }
        }
        .frame(height: wholePhoto ? 360 : 160)
        .onDisappear { releaseDecodedPreview() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            releaseDecodedPreview(forMemory: true)
        }
        .task(id: decodeRequest) {
            let token = UUID()
            decodeToken = token; image = nil; loading = true; releasedForMemory = false
            let url = services.previewURL(face.photo), rectangle = face.geometry.rectangle, whole = wholePhoto
            let decoded = await Task.detached(priority: .utility) {
                guard let url, let full = UIImage(contentsOfFile: url.path), let raster = full.cgImage else { return nil as UIImage? }
                if whole { return full }
                guard let crop = FaceCropGeometry.pixelRectangle(rectangle, width: raster.width, height: raster.height),
                      let cropped = raster.cropping(to: crop) else { return nil }
                return UIImage(cgImage: cropped)
            }.value
            #if DEBUG
            // Causal runtime fixture: warn after a real decode but before its result can publish.
            // Normal DEBUG use and all release builds never select this hook.
            if decoded != nil, services.usesSyntheticFixture,
               ProcessInfo.processInfo.arguments.contains("--uitest-face-preview-memory-warning") {
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            }
            #endif
            // Detached work can outlive SwiftUI's parent task or a memory-warning invalidation.
            guard !Task.isCancelled, decodeToken == token else { return }
            image = decoded; loading = false
        }
    }
    private func releaseDecodedPreview(forMemory: Bool = false) {
        guard image != nil || loading else { return }
        decodeToken = UUID()
        image = nil; loading = false; releasedForMemory = forMemory
    }
}
