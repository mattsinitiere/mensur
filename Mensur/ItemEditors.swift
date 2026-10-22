import SwiftUI
import PhotosUI

// Editors for everything placed on a plan besides walls and openings: markers, photo pins, stairs, ceiling
// features and furniture; a space's name and finishes; the furniture library; and taking reference photos.

// A field for a length in meters, as elsewhere in the app's editors.
private struct MetersField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        HStack {
            Text(title); Spacer()
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                .multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(maxWidth: 120).accessibilityLabel("\(title) in meters")
        }
    }
}

struct ItemEditor: View {
    @EnvironmentObject private var store: ProjectStore
    let id: UUID
    let onSave: (RoomProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoomProject
    @State private var confirmDelete = false
    private let original: RoomProject
    init(room: RoomProject, id: UUID, onSave: @escaping (RoomProject) -> Void) {
        self.id = id; self.onSave = onSave; self.original = room; _draft = State(initialValue: room)
    }
    var body: some View {
        NavigationStack {
            Form {
                switch draft.itemKind(id) {
                case .marker: markerForm
                case .photo: photoForm
                case .stair: stairForm
                case .ceiling: ceilingForm
                case .object: objectForm
                default: Text("This item is no longer on the plan.").foregroundStyle(.secondary)
                }
                Section { Button(deleteTitle, role: .destructive) { confirmDelete = true } }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(draft); dismiss() }.bold() }
            }
            .confirmationDialog(deleteTitle + "?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(deleteTitle, role: .destructive) {
                    if let photo = original.photos?.first(where: { $0.id == id }) { store.deletePhotoFile(original, photo) }
                    draft.removeItem(id); onSave(draft); dismiss()
                }
            }
        }
    }
    private var title: String {
        switch draft.itemKind(id) {
        case .marker: return draft.markers?.first { $0.id == id }?.kind.title ?? "Marker"
        case .photo: return "Photo"
        case .stair: return "Stair"
        case .ceiling: return draft.ceilings?.first { $0.id == id }.map { $0.label.isEmpty ? $0.kind.title : $0.label } ?? "Ceiling"
        case .object: return draft.objects.first { $0.id == id }?.label ?? "Furniture"
        default: return "Item"
        }
    }
    private var deleteTitle: String { draft.itemKind(id) == .photo ? "Delete photo" : "Remove from plan" }

    // Bindings into the draft's arrays by identifier.
    private func binding<T>(_ path: WritableKeyPath<RoomProject, [T]?>, where match: @escaping (T) -> Bool) -> Binding<T>? {
        guard let i = draft[keyPath: path]?.firstIndex(where: match) else { return nil }
        return Binding(get: { draft[keyPath: path]![i] }, set: { draft[keyPath: path]![i] = $0 })
    }

    @ViewBuilder private var markerForm: some View {
        if let m = binding(\.markers, where: { $0.id == id }) {
            Section {
                Picker("Type", selection: m.kind) {
                    ForEach([MarkerCategory.electrical, .plumbing, .hvac, .other], id: \.self) { category in
                        Section(category.rawValue.capitalized == "Hvac" ? "HVAC" : category.rawValue.capitalized) {
                            ForEach(MarkerKind.allCases.filter { $0.category == category }) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                    }
                }
                TextField("Label (circuit, model, note)", text: m.label)
                Toggle("Mounted on a wall", isOn: Binding(get: { m.wrappedValue.height != nil }, set: { m.wrappedValue.height = $0 ? (m.wrappedValue.kind.typicalHeight ?? 1.0) : nil }))
                if m.wrappedValue.height != nil { MetersField(title: "Height above floor", value: Binding(get: { m.wrappedValue.height ?? 0 }, set: { m.wrappedValue.height = max(0, $0) })) }
                TextField("Notes", text: m.note, axis: .vertical).lineLimit(2...6)
            } footer: { Text("Drag the marker on the plan to move it. Wall-mounted markers also appear on that wall’s elevation in the PDF.") }
        }
    }
    @ViewBuilder private var photoForm: some View {
        if let photo = binding(\.photos, where: { $0.id == id }) {
            Section {
                if let image = UIImage(contentsOfFile: store.photoURL(original, photo.wrappedValue).path) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Label("The photo hasn’t arrived on this device yet. It comes over with the next sync.", systemImage: "photo").foregroundStyle(.secondary)
                }
                TextField("Caption", text: photo.caption, axis: .vertical).lineLimit(1...4)
                LabeledContent("Taken", value: photo.wrappedValue.takenAt.formatted(date: .abbreviated, time: .shortened))
            } footer: { Text("Reference only: photos are never used to build the plan or the 3D model. They go in the multi-page PDF.") }
        }
    }
    @ViewBuilder private var stairForm: some View {
        if let s = binding(\.stairs, where: { $0.id == id }) {
            Section {
                TextField("Name", text: s.label)
                Picker("Direction", selection: s.up) { Text("Up from this floor").tag(true); Text("Down from this floor").tag(false) }
                Stepper("Risers: \(s.wrappedValue.risers)", value: s.risers, in: 1...40)
                MetersField(title: "Width", value: Binding(get: { s.wrappedValue.width }, set: { s.wrappedValue.width = min(10, max(0.3, $0)) }))
                MetersField(title: "Run (length)", value: Binding(get: { s.wrappedValue.length }, set: { v in
                    let run = min(30, max(0.3, v)); s.wrappedValue.b = s.wrappedValue.a + s.wrappedValue.direction * run }))
                Stepper("Connects to: \(s.wrappedValue.toFloor.map { FloorLevel(building: "x", floor: $0).displayName } ?? "not set")",
                        onIncrement: { s.wrappedValue.toFloor = (s.wrappedValue.toFloor ?? (draft.level?.floor ?? 0)) + 1 },
                        onDecrement: { s.wrappedValue.toFloor = (s.wrappedValue.toFloor ?? (draft.level?.floor ?? 0)) - 1 })
                Button("Turn 90°", systemImage: "rotate.right") { draft.rotate(id, by: .pi / 2) }
                Button("Reverse direction", systemImage: "arrow.left.arrow.right") { let a = s.wrappedValue.a; s.wrappedValue.a = s.wrappedValue.b; s.wrappedValue.b = a }
            } footer: { Text("Riser height: \(draft.units.length(((draft.level?.elevation ?? 3.0) / Double(max(1, s.wrappedValue.risers))))) if this floor is \(draft.units.length(draft.level?.elevation ?? 3.0)) high. In a building, Building view lines this stair up with the one on the floor it connects to.") }
        }
    }
    @ViewBuilder private var ceilingForm: some View {
        if let f = binding(\.ceilings, where: { $0.id == id }) {
            Section {
                Picker("Type", selection: f.kind) { ForEach(CeilingKind.allCases) { Text($0.title).tag($0) } }
                TextField("Name", text: f.label)
                MetersField(title: "Width", value: Binding(get: { f.wrappedValue.width }, set: { f.wrappedValue.width = min(100, max(0.05, $0)) }))
                MetersField(title: "Length", value: Binding(get: { f.wrappedValue.length }, set: { v in
                    let l = min(100, max(0.05, v)), c = (f.wrappedValue.a + f.wrappedValue.b) * 0.5, d = f.wrappedValue.direction
                    f.wrappedValue.a = c - d * (l / 2); f.wrappedValue.b = c + d * (l / 2) }))
                MetersField(title: f.wrappedValue.kind == .slope ? "Low end height" : f.wrappedValue.kind == .vault ? "Spring height" : "Underside height",
                            value: Binding(get: { f.wrappedValue.low }, set: { f.wrappedValue.low = min(30, max(0.5, $0)) }))
                if f.wrappedValue.kind == .slope || f.wrappedValue.kind == .vault {
                    MetersField(title: f.wrappedValue.kind == .slope ? "High end height" : "Crown height",
                                value: Binding(get: { f.wrappedValue.high ?? f.wrappedValue.low }, set: { f.wrappedValue.high = min(30, max(0.5, $0)) }))
                }
                Button("Turn 90°", systemImage: "rotate.right") { draft.rotate(id, by: .pi / 2) }
            } footer: {
                Text((f.wrappedValue.detected ? "Found in the LiDAR ceiling points; check the heights with a tape. " : "") + "Heights are above the floor. Ceiling area and room volume in Quantities include this feature.")
            }
        }
    }
    @ViewBuilder private var objectForm: some View {
        if let i = draft.objects.firstIndex(where: { $0.id == id }) {
            let o = Binding(get: { draft.objects[i] }, set: { draft.objects[i] = $0 })
            Section {
                TextField("Name", text: o.label)
                MetersField(title: "Width", value: Binding(get: { o.wrappedValue.size.x }, set: { o.wrappedValue.size.x = min(100, max(0.02, $0)) }))
                MetersField(title: "Depth", value: Binding(get: { o.wrappedValue.size.z }, set: { o.wrappedValue.size.z = min(100, max(0.02, $0)) }))
                MetersField(title: "Height", value: Binding(get: { o.wrappedValue.size.y }, set: { v in
                    let h = min(100, max(0.01, v)); o.wrappedValue.size.y = h; o.wrappedValue.center.y = h / 2 }))
                HStack {
                    Text("Rotation"); Spacer()
                    TextField("Degrees", value: Binding(get: { (o.wrappedValue.yaw * 180 / .pi).rounded() }, set: { o.wrappedValue.yaw = $0 * .pi / 180 }), format: .number)
                        .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).frame(maxWidth: 90).accessibilityLabel("Rotation in degrees")
                    Text("°")
                }
                Button("Turn 90°", systemImage: "rotate.right") { draft.rotate(id, by: .pi / 2) }
                Toggle("Exclude from plan and exports", isOn: o.excluded)
            }
        }
    }
}

// A space's name and its finish tags, shown on the plan and in the room schedule.
struct SpaceEditor: View {
    let space: Geometry.Space
    let defaultName: String
    let onSave: (SpaceLabel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: SpaceLabel
    static let floors = ["LVP", "Carpet tile", "Broadloom carpet", "Hardwood", "Porcelain tile", "Polished concrete", "Sealed concrete", "VCT", "Epoxy", "Laminate"]
    static let walls = ["Paint · eggshell", "Paint · satin", "Paint · semi-gloss", "Wallcovering", "Ceramic tile", "FRP", "Wood paneling"]
    static let ceilings = ["ACT 2×2", "ACT 2×4", "Painted drywall", "Exposed structure", "Wood slat"]
    static let bases = ["Rubber 4″", "Rubber 6″", "Wood 3¼″", "Wood 5¼″", "Tile cove", "None"]
    init(space: Geometry.Space, label: SpaceLabel?, defaultName: String, onSave: @escaping (SpaceLabel) -> Void) {
        self.space = space; self.defaultName = defaultName; self.onSave = onSave
        _label = State(initialValue: label ?? SpaceLabel(name: "", anchor: Geometry.labelPoint(space.points)))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField(defaultName, text: $label.name) } header: { Text("Name") } footer: { Text("Leave it empty to use \(defaultName).") }
                Section {
                    finish("Floor", \.floorFinish, Self.floors)
                    finish("Walls", \.wallFinish, Self.walls)
                    finish("Ceiling", \.ceilingFinish, Self.ceilings)
                    finish("Base", \.baseFinish, Self.bases)
                } header: { Text("Finishes") } footer: { Text("Shown under the space’s name on the plan, and in the room schedule of the PDF set.") }
            }
            .navigationTitle(label.name.isEmpty ? defaultName : label.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(label); dismiss() }.bold() }
            }
        }
    }
    private func finish(_ title: String, _ path: WritableKeyPath<SpaceLabel, String?>, _ options: [String]) -> some View {
        HStack {
            TextField(title, text: Binding(get: { label[keyPath: path] ?? "" }, set: { label[keyPath: path] = $0 }))
            Menu { ForEach(options, id: \.self) { option in Button(option) { label[keyPath: path] = option } } } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel("Common \(title.lowercased()) finishes")
        }
    }
}

// Standard furniture and fixtures, by room type; choosing one drops it on the plan at its real size.
struct FurnitureLibrary: View {
    let units: DisplayUnits
    let onPick: (FurnitureItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                ForEach(FurnitureCatalog.categories, id: \.self) { category in
                    let items = FurnitureCatalog.items.filter { $0.category == category && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                    if !items.isEmpty {
                        Section(category) {
                            ForEach(items) { item in
                                Button { onPick(item); dismiss() } label: {
                                    HStack {
                                        Text(item.name).foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(units.length(item.size.x)) × \(units.length(item.size.z))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Sofa, desk, refrigerator…")
            .navigationTitle("Add furniture").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// The camera, for a reference photo taken from the plan (iPhone and iPad).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

enum PhotoFiles {
    // A JPEG at most 2048 px on its long side, the size reference photos are kept at.
    static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height), scale = min(1, 2048 / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
