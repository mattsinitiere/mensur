import SwiftUI

struct SurfaceEditor: View {
    let room: RoomProject
    let onSave: (PlanSurface, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlanSurface
    @State private var offset = 0.0
    @State private var width = 1.0
    @State private var measured = ""
    @State private var joinCorners = true
    @State private var errorMessage: String?
    private let original: PlanSurface
    init(surface: PlanSurface, room: RoomProject, onSave: @escaping (PlanSurface, Bool) -> Void) {
        self.room = room; self.onSave = onSave; self.original = surface; _draft = State(initialValue: surface)
        _width = State(initialValue: surface.length)
        if let wall = room.walls.first(where: { $0.id == surface.parentID }) {
            _offset = State(initialValue: min((surface.a - wall.a).dot(wall.direction), (surface.b - wall.a).dot(wall.direction)))
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Element") {
                    TextField("Name", text: $draft.label)
                    LabeledContent("Type", value: draft.kind.title)
                    LabeledContent("Recognition confidence", value: draft.confidence.rawValue.capitalized)
                    Text("Recognition confidence is not measurement accuracy.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Position and size · meters") {
                    if draft.kind != .wall {
                        Picker("Parent wall", selection: $draft.parentID) {
                            Text("Unassigned").tag(Optional<UUID>.none)
                            ForEach(room.walls) { wall in Text(wall.label).tag(Optional(wall.id)) }
                        }
                    }
                    if draft.kind != .wall && draft.parentID != nil {
                        numeric("Offset from wall start", value: $offset)
                        numeric("Width", value: $width)
                    } else {
                        numeric("Start X", value: $draft.a.x); numeric("Start Z", value: $draft.a.z)
                        numeric("End X", value: $draft.b.x); numeric("End Z", value: $draft.b.z)
                    }
                    numeric("Bottom above room datum", value: $draft.bottom)
                    numeric("Height", value: $draft.height)
                    if draft.kind == .wall {
                        Toggle("Move connected corners too", isOn: $joinCorners)
                        Text("Moves wall ends within 80 mm of the original corners. Recheck adjoining walls and openings after a change.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Coordinates use the scan’s local origin. All entry fields are in meters; 1 foot = 0.3048 m.").font(.caption).foregroundStyle(.secondary)
                }
                if draft.kind == .window {
                    Section {
                        Stepper("Panes across: \((draft.dividers?.count ?? 0) + 1)", value: Binding(
                            get: { (draft.dividers?.count ?? 0) + 1 },
                            set: { n in draft.dividers = (1..<max(1, n)).map { Double($0) * draft.length / Double(n) } }), in: 1...8)
                        Stepper("Panes up: \((draft.rails?.count ?? 0) + 1)", value: Binding(
                            get: { (draft.rails?.count ?? 0) + 1 },
                            set: { n in draft.rails = (1..<max(1, n)).map { Double($0) * draft.height / Double(n) } }), in: 1...4)
                    } header: { Text("Panes") } footer: {
                        Text(original.dividers != nil || original.rails != nil
                             ? "Found from the camera during the scan. Changing a count spaces the dividers evenly; they show on the plan, the 3D model, the PDF schedule and the DXF."
                             : "Dividers between panes show on the plan, the 3D model, the PDF schedule and the DXF.")
                    }
                }
                Section("Independent length check") {
                    if let reference = draft.originalLength { LabeledContent("Original scan length", value: room.units.length(reference)) }
                    TextField("Laser / tape measurement in meters", text: $measured).keyboardType(.decimalPad)
                    Button("Apply measured length") { applyMeasurement() }
                    Text("Keeps the start point fixed and changes the length along the existing direction. This checks length only; it does not calibrate the whole scan.").font(.caption).foregroundStyle(.secondary)
                    if let check = draft.lengthCheck {
                        LabeledContent("Measured", value: room.units.length(check.measuredMeters))
                        LabeledContent("Difference from reference", value: String(format: "%+.0f mm", check.difference * 1000))
                        Button("Clear length check", role: .destructive) { draft.lengthCheck = nil }
                    }
                }
                Section("Surface review") {
                    Toggle("Reflective / glass risk", isOn: $draft.reflectiveRisk)
                    Toggle("I reviewed this surface visually", isOn: $draft.reviewed)
                    Toggle("Exclude from corrected outputs", isOn: $draft.excluded)
                    if draft.kind == .wall { Text("Excluding a wall also excludes its attached windows, doors, and mirrors. Undo restores them.").font(.caption).foregroundStyle(.secondary) }
                    if let caveat = draft.geometryCaveat { Text(caveat).foregroundStyle(.orange).font(.caption) }
                    if let note = draft.reviewNote { Text(note).foregroundStyle(.orange).font(.caption) }
                    TextField("Notes, missing geometry, or measurement method", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle(draft.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold() }
            }
        }
    }
    private func numeric(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: value, format: .number.precision(.fractionLength(0...3))).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).frame(maxWidth: 130).accessibilityLabel(title + " in meters") }
    }
    private func resolved() -> PlanSurface {
        if draft.kind != .wall, let wall = room.walls.first(where: { $0.id == draft.parentID }) {
            return Geometry.attach(draft, to: wall, offset: offset, width: width)
        }
        return draft
    }
    private func applyMeasurement() {
        let formatter = NumberFormatter(); formatter.locale = .current
        guard let value = formatter.number(from: measured)?.doubleValue, value.isFinite, value >= 0.01, value <= 100 else {
            errorMessage = "Enter a length between 0.01 and 100 meters."; return
        }
        let current = resolved()
        let reference = original.originalLength ?? original.length
        draft.lengthCheck = .init(measuredMeters: value, referenceMeters: reference)
        if draft.kind != .wall && draft.parentID != nil { width = value }
        else { draft.b = draft.a + current.direction * value }
        errorMessage = nil
    }
    private func save() {
        var result = resolved()
        result.label = String(result.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if result.label.isEmpty { errorMessage = "Give this element a name."; return }
        // An unchanged existing element closes without a save, so it creates no undo step or "edited" mark.
        if result == original && room.surfaces.contains(where: { $0.id == original.id }) { dismiss(); return }
        if let check = result.lengthCheck, abs(result.length - check.measuredMeters) >= 0.005 { result.lengthCheck = nil }
        // Dividers keep their proportions when the window is resized.
        if original.length > 0.01, abs(result.length - original.length) > 0.001 { result.dividers = result.dividers?.map { $0 * result.length / original.length } }
        if original.height > 0.01, abs(result.height - original.height) > 0.001 { result.rails = result.rails?.map { $0 * result.height / original.height } }
        if result.dividers?.isEmpty == true { result.dividers = nil }
        if result.rails?.isEmpty == true { result.rails = nil }
        if result != original { result.evidence = original.evidence == .manual ? .manual : .edited }
        var candidate = room
        Geometry.replace(result, in: &candidate, joinCorners: joinCorners)
        if result.excluded && result.kind == .wall {
            for i in candidate.surfaces.indices where candidate.surfaces[i].parentID == result.id { candidate.surfaces[i].excluded = true }
        }
        do {
            _ = try candidate.validated()
            if !result.excluded, let issue = Geometry.openingIssue(result, in: candidate) { errorMessage = issue; return }
            onSave(result, joinCorners); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct RoomNotesEditor: View {
    @State var room: RoomProject
    let onSave: (RoomProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locating = false
    @State private var locationFailed = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Room name", text: $room.name)
                    TextField("Address", text: Binding(get: { room.address ?? "" }, set: { room.address = $0 }), axis: .vertical)
                        .lineLimit(1...3).textContentType(.fullStreetAddress)
                    #if !targetEnvironment(macCatalyst)
                    Button {
                        locating = true; locationFailed = false
                        Task { if let a = await LocationAddress.shared.lookUp() { room.address = a } else { locationFailed = true }; locating = false }
                    } label: { HStack { Label("Use current location", systemImage: "location"); if locating { Spacer(); ProgressView() } } }
                    .disabled(locating)
                    #endif
                } header: { Text("Room") } footer: {
                    if locationFailed { Text("Couldn’t find an address here. Check location access for Mensur in Settings, or type it in.").foregroundStyle(.orange) }
                }
                Section("Notes") { TextEditor(text: $room.notes).frame(minHeight: 180) }
            }.navigationTitle("Room details")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            room.name = String(room.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                            let address = String((room.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
                            room.address = address.isEmpty ? nil : address
                            onSave(room); dismiss()
                        }
                            .disabled(room.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
