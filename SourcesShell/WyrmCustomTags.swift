import SwiftUI
import UIKit
import PhotosUI

// Custom tags (OM-style note): the player's own picture as a tag, and a free
// choice of rope colours. Shown on this phone only: the arena and the NTL tag
// network only ever carry the numbers of the built-in tags, so nothing here is
// sent to anyone.

// MARK: - Model

struct WyrmCustomTagItem: Codable, Identifiable, Equatable {
    var id: String
    /// Rope colours, 0xRRGGBB: the thick line and the tapering tip.
    var c1: UInt32
    var c2: UInt32
}

struct WyrmCustomTagIndex: Codable, Equatable {
    var items: [WyrmCustomTagItem] = []
    /// The picture being worn; nil wears the tag chosen from the built-in list.
    var activeID: String? = nil
    /// Rope colours for the built-in tags, when switched on.
    var originalColorsOn: Bool = false
    var originalC1: UInt32 = 0xFFDAF5
    var originalC2: UInt32 = 0x8562D0
}

/// The library of pictures and what the engine is told. Main thread only.
final class WyrmCustomTagStore: ObservableObject {
    static let shared = WyrmCustomTagStore()
    static let maxTags = 24
    /// Longest side of a stored picture, in pixels (a built-in tag's cell is
    /// about 130).
    static let maxSide: CGFloat = 160

    @Published private(set) var index = WyrmCustomTagIndex()

    private var cache: [String: UIImage] = [:]
    private let directory: URL
    private var saveWork: DispatchWorkItem?
    /// The picture the engine was last handed, so a colour change does not
    /// make it decode and upload the same picture again.
    private var lastSentID: String?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("WyrmCustomTags", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let decoded = try? JSONDecoder().decode(WyrmCustomTagIndex.self, from: data) {
            index = decoded
            // A picture whose file went missing is dropped.
            index.items.removeAll { !FileManager.default.fileExists(atPath: fileURL($0.id).path) }
            if let active = index.activeID, !index.items.contains(where: { $0.id == active }) {
                index.activeID = nil
            }
        }
    }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).png")
    }

    func image(for id: String) -> UIImage? {
        if let cached = cache[id] { return cached }
        guard let loaded = UIImage(contentsOfFile: fileURL(id).path) else { return nil }
        cache[id] = loaded
        return loaded
    }

    // MARK: Changes

    /// Adds a picture and wears it. False if the library is full or the
    /// picture could not be used.
    @discardableResult
    func add(_ picked: UIImage) -> Bool {
        guard index.items.count < Self.maxTags,
              let prepared = Self.prepared(picked),
              let data = prepared.pngData() else { return false }
        let id = UUID().uuidString
        do { try data.write(to: fileURL(id), options: .atomic) } catch { return false }
        cache[id] = prepared
        let colours = Self.automaticColours(prepared)
        index.items.append(WyrmCustomTagItem(id: id, c1: colours.0, c2: colours.1))
        index.activeID = id
        commit()
        return true
    }

    func activate(_ id: String) {
        guard index.items.contains(where: { $0.id == id }) else { return }
        index.activeID = id
        commit()
    }

    /// Back to the tag chosen from the built-in list.
    func useOriginalTag() {
        guard index.activeID != nil else { return }
        index.activeID = nil
        commit()
    }

    func delete(_ id: String) {
        guard let position = index.items.firstIndex(where: { $0.id == id }) else { return }
        index.items.remove(at: position)
        cache[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
        if index.activeID == id {
            index.activeID = nil
            lastSentID = nil
        }
        commit()
    }

    func setColours(_ id: String, c1: UInt32? = nil, c2: UInt32? = nil) {
        guard let position = index.items.firstIndex(where: { $0.id == id }) else { return }
        if let c1 { index.items[position].c1 = c1 & 0xFFFFFF }
        if let c2 { index.items[position].c2 = c2 & 0xFFFFFF }
        commit()
    }

    func resetColours(_ id: String) {
        guard let image = image(for: id) else { return }
        let colours = Self.automaticColours(image)
        setColours(id, c1: colours.0, c2: colours.1)
    }

    func setOriginalColours(on: Bool? = nil, c1: UInt32? = nil, c2: UInt32? = nil) {
        if let on { index.originalColorsOn = on }
        if let c1 { index.originalC1 = c1 & 0xFFFFFF }
        if let c2 { index.originalC2 = c2 & 0xFFFFFF }
        commit()
    }

    // MARK: Saving and the engine

    private func commit() {
        saveSoon()
        pushToEngine()
    }

    private func saveSoon() {
        saveWork?.cancel()
        let snapshot = index
        let url = directory.appendingPathComponent("index.json")
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func pushToEngine() {
        if let id = index.activeID,
           let item = index.items.first(where: { $0.id == id }),
           let source = image(for: id) {
            var ready = lastSentID == id
            if !ready, let data = Self.engineData(source) {
                ready = data.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
                    return WyrmCustomTagSetImage(base, data.count)
                }
                if ready { lastSentID = id }
            }
            WyrmCustomTagConfigure(ready, true, item.c1, item.c2)
        } else {
            WyrmCustomTagConfigure(false, index.originalColorsOn, index.originalC1, index.originalC2)
        }
    }

    // MARK: Pictures

    /// The picture fitted into maxSide, keeping its shape and its see-through
    /// parts, with its orientation applied.
    private static func prepared(_ image: UIImage) -> UIImage? {
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        guard width > 0, height > 0 else { return nil }
        let ratio = min(1, maxSide / max(width, height))
        let target = CGSize(width: max(1, (width * ratio).rounded()),
                            height: max(1, (height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// What the engine stores: the picture turned a quarter anticlockwise, so
    /// its top is towards the rope like Wyrm's own tags (the picker turns those
    /// back the other way).
    private static func engineData(_ image: UIImage) -> Data? {
        guard let cg = image.cgImage,
              let turned = turnedAnticlockwise(cg) else { return nil }
        return UIImage(cgImage: turned).pngData()
    }

    private static func turnedAnticlockwise(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: CGFloat(h), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// A starting pair of rope colours from the picture: a darker shade of its
    /// average for the thick line and a lighter one for the tip, as Wyrm's own
    /// tags pair them.
    private static func automaticColours(_ image: UIImage) -> (UInt32, UInt32) {
        guard let cg = image.cgImage else { return (0x555555, 0xAAAAAA) }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (0x555555, 0xAAAAAA)
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3])
            if alpha < 40 { continue }
            a += alpha
            r += Double(pixels[offset]); g += Double(pixels[offset + 1]); b += Double(pixels[offset + 2])
        }
        guard a > 0 else { return (0x555555, 0xAAAAAA) }
        func average(_ sum: Double) -> Double { min(255, max(0, sum / a * 255)) }
        let base = (average(r), average(g), average(b))
        func pack(_ c: (Double, Double, Double)) -> UInt32 {
            (UInt32(c.0.rounded()) << 16) | (UInt32(c.1.rounded()) << 8) | UInt32(c.2.rounded())
        }
        let dark = (base.0 * 0.55, base.1 * 0.55, base.2 * 0.55)
        let light = (base.0 + (255 - base.0) * 0.35, base.1 + (255 - base.1) * 0.35, base.2 + (255 - base.2) * 0.35)
        return (pack(dark), pack(light))
    }
}

// MARK: - Colours

private extension Color {
    init(wyrmCustomHex rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }

    var wyrmCustomHex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }
}

// MARK: - Picker

struct WyrmCustomTagImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                DispatchQueue.main.async { self.onPick(nil) }
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async { self.onPick(object as? UIImage) }
            }
        }
    }
}

// MARK: - Preview

/// A still of the rope and picture: the rope hangs from a dot standing for the
/// head, in the two chosen colours, and the picture hangs from its end.
private struct WyrmCustomTagPreview: View {
    let image: UIImage?
    let c1: UInt32
    let c2: UInt32

    var body: some View {
        Canvas { context, size in
            let start = CGPoint(x: 22, y: size.height * 0.28)
            let end = CGPoint(x: size.width * 0.58, y: size.height * 0.66)
            var rope = Path()
            rope.move(to: start)
            rope.addQuadCurve(to: end, control: CGPoint(x: size.width * 0.28, y: size.height * 0.98))
            context.stroke(rope, with: .color(Color(wyrmCustomHex: c1)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            for width in [4.0, 3.0, 2.0] {
                context.stroke(rope, with: .color(Color(wyrmCustomHex: c2).opacity(0.5)),
                               style: StrokeStyle(lineWidth: CGFloat(width), lineCap: .round, lineJoin: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: start.x - 12, y: start.y - 12, width: 24, height: 24)),
                         with: .color(Color.gray.opacity(0.55)))
            if let image {
                let height: CGFloat = min(size.height * 0.62, 84)
                let ratio = image.size.width / max(1, image.size.height)
                let width = height * ratio
                let rect = CGRect(x: end.x - width * 0.12, y: end.y - height * 0.5, width: width, height: height)
                context.draw(Image(uiImage: image), in: rect)
            }
        }
        .frame(height: 124)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ATheme.card.opacity(0.88)))
    }
}

// MARK: - Section

/// "My tags": pictures of the player's own, and rope colours. Inserted above
/// the built-in tag grid by Scripts/wyrm-custom-tags-install.py.
struct WyrmCustomTagSection: View {
    @ObservedObject private var store = WyrmCustomTagStore.shared
    @State private var showingPicker = false
    @State private var notice: String?

    private var activeItem: WyrmCustomTagItem? {
        guard let id = store.index.activeID else { return nil }
        return store.index.items.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MY TAGS").font(.androidWyrm(11, .bold)).tracking(1).foregroundColor(ATheme.quiet)
                Spacer()
                Button { showingPicker = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 12, weight: .semibold))
                        Text("Add picture").font(.androidWyrm(12, .bold))
                    }
                    .foregroundColor(ATheme.onInk)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(ATheme.ink))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a picture as a tag")
            }
            Text("Only you see these, on this phone.").font(.androidWyrm(11)).foregroundColor(ATheme.quiet)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                tile(selected: store.index.activeID == nil) {
                    store.useOriginalTag()
                } content: {
                    Text("LISTED").font(.androidWyrm(9, .bold)).tracking(0.7)
                }
                ForEach(store.index.items) { item in
                    tile(selected: store.index.activeID == item.id) {
                        store.activate(item.id)
                    } content: {
                        if let image = store.image(for: item.id) {
                            Image(uiImage: image).resizable().interpolation(.high).scaledToFit().padding(8)
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { store.delete(item.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            if let notice {
                Text(notice).font(.androidWyrm(11.5)).foregroundColor(.red)
            }

            if let item = activeItem {
                VStack(alignment: .leading, spacing: 12) {
                    WyrmCustomTagPreview(image: store.image(for: item.id), c1: item.c1, c2: item.c2)
                    colourRow("Chain", binding: Binding(
                        get: { Color(wyrmCustomHex: item.c1) },
                        set: { store.setColours(item.id, c1: $0.wyrmCustomHex) }))
                    colourRow("Chain tip", binding: Binding(
                        get: { Color(wyrmCustomHex: item.c2) },
                        set: { store.setColours(item.id, c2: $0.wyrmCustomHex) }))
                    HStack(spacing: 10) {
                        smallButton("Reset colours", systemImage: "arrow.counterclockwise") {
                            store.resetColours(item.id)
                        }
                        smallButton("Delete", systemImage: "trash") { store.delete(item.id) }
                    }
                }
                .padding(12).background(ATheme.card.opacity(0.88)).cornerRadius(14)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { store.index.originalColorsOn },
                                     set: { store.setOriginalColours(on: $0) })) {
                    Text("Chain colour for listed tags").font(.androidWyrm(12.5, .semibold))
                }
                if store.index.originalColorsOn {
                    colourRow("Chain", binding: Binding(
                        get: { Color(wyrmCustomHex: store.index.originalC1) },
                        set: { store.setOriginalColours(c1: $0.wyrmCustomHex) }))
                    colourRow("Chain tip", binding: Binding(
                        get: { Color(wyrmCustomHex: store.index.originalC2) },
                        set: { store.setOriginalColours(c2: $0.wyrmCustomHex) }))
                }
            }
            .padding(12).background(ATheme.card.opacity(0.88)).cornerRadius(14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .sheet(isPresented: $showingPicker) {
            WyrmCustomTagImagePicker { picked in
                showingPicker = false
                guard let picked else { return }
                if !store.add(picked) {
                    notice = store.index.items.count >= WyrmCustomTagStore.maxTags
                        ? "That is the most pictures you can keep. Delete one first."
                        : "That picture could not be used."
                } else {
                    notice = nil
                }
            }
        }
    }

    private func tile<Content: View>(selected: Bool, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 15).fill(ATheme.card.opacity(0.92))
                content()
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16, weight: .bold))
                        .foregroundColor(ATheme.ink).padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 15)
                .stroke(selected ? ATheme.ink : ATheme.rule, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func colourRow(_ title: String, binding: Binding<Color>) -> some View {
        HStack {
            Text(title).font(.androidWyrm(12, .semibold))
            Spacer()
            ColorPicker("", selection: binding, supportsOpacity: false).labelsHidden()
        }
    }

    private func smallButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(.androidWyrm(12, .bold))
            }
            .foregroundColor(ATheme.ink)
            .padding(.horizontal, 12).frame(height: 34)
            .background(Capsule().fill(ATheme.well))
        }
        .buttonStyle(.plain)
    }
}
