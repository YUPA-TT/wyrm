import SwiftUI
import UIKit
import PhotosUI

// Custom tags: the player's own picture as a tag, free rope colours, and a size
// and position for the tag worn. Shown on this phone only: the arena and the
// NTL tag network only ever carry the numbers of the built-in tags, so nothing
// here is sent to anyone.

// MARK: - Model

struct WyrmCustomTagItem: Codable, Identifiable, Equatable {
    var id: String
    /// Rope colours, 0xRRGGBB: the thick line and the tapering tip.
    var c1: UInt32
    var c2: UInt32
    /// 1 is the tag's usual size.
    var scale: Double = 1
    /// Where it hangs, as a fraction of its own width (along the rope, away
    /// from the head) and height (across it). 0 and 0 is the usual place.
    var along: Double = 0
    var across: Double = 0
    /// Quarter turns clockwise given to the picture.
    var turns: Int = 0

    init(id: String, c1: UInt32, c2: UInt32) {
        self.id = id
        self.c1 = c1
        self.c2 = c2
    }

    // An older library has no size or position; they default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        c1 = try c.decode(UInt32.self, forKey: .c1)
        c2 = try c.decode(UInt32.self, forKey: .c2)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        along = try c.decodeIfPresent(Double.self, forKey: .along) ?? 0
        across = try c.decodeIfPresent(Double.self, forKey: .across) ?? 0
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
    }
}

struct WyrmCustomTagIndex: Codable, Equatable {
    var items: [WyrmCustomTagItem] = []
    /// The picture being worn; nil wears the tag chosen from the built-in list.
    var activeID: String? = nil
    /// Rope colours for the built-in tags, when switched on.
    var originalColorsOn: Bool = false
    var originalC1: UInt32 = 0xFFDAF5
    var originalC2: UInt32 = 0x8562D0
    /// Size and position for the built-in tags.
    var originalScale: Double = 1
    var originalAlong: Double = 0
    var originalAcross: Double = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([WyrmCustomTagItem].self, forKey: .items) ?? []
        activeID = try c.decodeIfPresent(String.self, forKey: .activeID)
        originalColorsOn = try c.decodeIfPresent(Bool.self, forKey: .originalColorsOn) ?? false
        originalC1 = try c.decodeIfPresent(UInt32.self, forKey: .originalC1) ?? 0xFFDAF5
        originalC2 = try c.decodeIfPresent(UInt32.self, forKey: .originalC2) ?? 0x8562D0
        originalScale = try c.decodeIfPresent(Double.self, forKey: .originalScale) ?? 1
        originalAlong = try c.decodeIfPresent(Double.self, forKey: .originalAlong) ?? 0
        originalAcross = try c.decodeIfPresent(Double.self, forKey: .originalAcross) ?? 0
    }
}

/// The library of pictures and what the engine is told. Main thread only.
final class WyrmCustomTagStore: ObservableObject {
    static let shared = WyrmCustomTagStore()
    static let maxTags = 24
    /// Longest side of a stored picture, in pixels.
    static let maxSide: CGFloat = 256

    @Published private(set) var index = WyrmCustomTagIndex()

    private var cache: [String: UIImage] = [:]
    private var storedCache: [String: UIImage] = [:]
    private let directory: URL
    private var saveWork: DispatchWorkItem?
    /// The picture (and its turn) the engine was last handed, so a colour or
    /// position change does not make it decode and upload it again.
    private var lastSentKey: String?

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

    func item(_ id: String) -> WyrmCustomTagItem? {
        index.items.first { $0.id == id }
    }

    func image(for id: String) -> UIImage? {
        if let cached = cache[id] { return cached }
        guard let loaded = UIImage(contentsOfFile: fileURL(id).path) else { return nil }
        cache[id] = loaded
        return loaded
    }

    /// The picture as the engine holds it: turned as the item says, then a
    /// quarter anticlockwise so its top is towards the rope, as Wyrm's own tags
    /// are stored (the picker turns those back the other way).
    func storedImage(for id: String) -> UIImage? {
        guard let item = item(id), let source = image(for: id) else { return nil }
        let key = "\(id)#\(item.turns)"
        if let cached = storedCache[key] { return cached }
        guard let cg = source.cgImage,
              let turned = Self.turned(cg, clockwiseQuarters: item.turns + 3) else { return nil }
        let result = UIImage(cgImage: turned)
        storedCache[key] = result
        return result
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
        storedCache = storedCache.filter { !$0.key.hasPrefix(id) }
        try? FileManager.default.removeItem(at: fileURL(id))
        if index.activeID == id {
            index.activeID = nil
            lastSentKey = nil
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

    func setAdjust(_ id: String, scale: Double? = nil, along: Double? = nil, across: Double? = nil) {
        guard let position = index.items.firstIndex(where: { $0.id == id }) else { return }
        if let scale { index.items[position].scale = min(2.5, max(0.3, scale)) }
        if let along { index.items[position].along = min(1.0, max(-0.5, along)) }
        if let across { index.items[position].across = min(1.0, max(-1.0, across)) }
        commit()
    }

    func resetAdjust(_ id: String) {
        guard let position = index.items.firstIndex(where: { $0.id == id }) else { return }
        index.items[position].scale = 1
        index.items[position].along = 0
        index.items[position].across = 0
        commit()
    }

    func turn(_ id: String) {
        guard let position = index.items.firstIndex(where: { $0.id == id }) else { return }
        index.items[position].turns = (index.items[position].turns + 1) % 4
        commit()
    }

    func setOriginalColours(on: Bool? = nil, c1: UInt32? = nil, c2: UInt32? = nil) {
        if let on { index.originalColorsOn = on }
        if let c1 { index.originalC1 = c1 & 0xFFFFFF }
        if let c2 { index.originalC2 = c2 & 0xFFFFFF }
        commit()
    }

    func setOriginalAdjust(scale: Double? = nil, along: Double? = nil, across: Double? = nil) {
        if let scale { index.originalScale = min(2.5, max(0.3, scale)) }
        if let along { index.originalAlong = min(1.0, max(-0.5, along)) }
        if let across { index.originalAcross = min(1.0, max(-1.0, across)) }
        commit()
    }

    func resetOriginalAdjust() {
        index.originalScale = 1
        index.originalAlong = 0
        index.originalAcross = 0
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
        if let id = index.activeID, let item = item(id), let stored = storedImage(for: id) {
            let key = "\(id)#\(item.turns)"
            var ready = lastSentKey == key
            if !ready, let data = Self.engineData(stored) ?? stored.pngData() {
                ready = data.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
                    return WyrmCustomTagSetImage(base, data.count)
                }
                if ready { lastSentKey = key }
            }
            WyrmCustomTagConfigure(ready, true, item.c1, item.c2,
                                   Float(item.scale), Float(item.along), Float(item.across))
        } else {
            WyrmCustomTagConfigure(false, index.originalColorsOn, index.originalC1, index.originalC2,
                                   Float(index.originalScale), Float(index.originalAlong),
                                   Float(index.originalAcross))
        }
    }

    /// What the engine says about the picture: 1 ready, 0 waiting, -1 failed.
    static func engineStatus() -> (code: Int, text: String) {
        var buffer = [CChar](repeating: 0, count: 200)
        let code = WyrmCustomTagStatus(&buffer, buffer.count)
        return (Int(code), String(cString: buffer))
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

    /// The picture turned by whole quarter turns clockwise.
    private static func turned(_ image: CGImage, clockwiseQuarters: Int) -> CGImage? {
        let quarters = ((clockwiseQuarters % 4) + 4) % 4
        let w = image.width, h = image.height
        let swapped = quarters % 2 == 1
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: swapped ? h : w, height: swapped ? w : h,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        switch quarters {
        case 1: // clockwise
            context.translateBy(x: 0, y: CGFloat(w))
            context.rotate(by: -.pi / 2)
        case 2:
            context.translateBy(x: CGFloat(w), y: CGFloat(h))
            context.rotate(by: .pi)
        case 3: // anticlockwise
            context.translateBy(x: CGFloat(h), y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // MARK: Engine picture

    /// The picture as PNG bytes for the engine, with the colour of its
    /// see-through pixels filled in from their neighbours. A picture drawn
    /// through Core Graphics keeps no colour where it is fully see-through
    /// (it reads back black), and the engine's smooth scaling then blends that
    /// black into every edge: a dark halo, or a black ground behind a soft
    /// shadow. The PNG is written here, uncompressed, because the system
    /// encoder may premultiply it again and lose the colour.
    private static func engineData(_ image: UIImage) -> Data? {
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // To straight alpha, remembering which pixels can be seen at all and
        // the average colour of those.
        var filled = [Bool](repeating: false, count: w * h)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumA = 0.0
        for i in 0..<(w * h) {
            let a = Int(px[i * 4 + 3])
            if a == 0 { continue }
            filled[i] = true
            for c in 0..<3 {
                px[i * 4 + c] = UInt8(min(255, (Int(px[i * 4 + c]) * 255 + a / 2) / a))
            }
            sumR += Double(px[i * 4]) * Double(a)
            sumG += Double(px[i * 4 + 1]) * Double(a)
            sumB += Double(px[i * 4 + 2]) * Double(a)
            sumA += Double(a)
        }

        // Spread the colour of the visible edge outwards, a pixel a pass.
        for _ in 0..<8 {
            var next = px
            var nextFilled = filled
            var changed = false
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    if filled[i] { continue }
                    var r = 0, g = 0, b = 0, n = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            if dx == 0 && dy == 0 { continue }
                            let nx = x + dx, ny = y + dy
                            if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                            let j = ny * w + nx
                            if filled[j] {
                                r += Int(px[j * 4]); g += Int(px[j * 4 + 1]); b += Int(px[j * 4 + 2])
                                n += 1
                            }
                        }
                    }
                    if n > 0 {
                        next[i * 4] = UInt8(r / n)
                        next[i * 4 + 1] = UInt8(g / n)
                        next[i * 4 + 2] = UInt8(b / n)
                        nextFilled[i] = true
                        changed = true
                    }
                }
            }
            px = next
            filled = nextFilled
            if !changed { break }
        }

        // Whatever is left, far from any edge, takes the picture's average.
        if sumA > 0 {
            let ar = UInt8(min(255, sumR / sumA))
            let ag = UInt8(min(255, sumG / sumA))
            let ab = UInt8(min(255, sumB / sumA))
            for i in 0..<(w * h) where !filled[i] {
                px[i * 4] = ar
                px[i * 4 + 1] = ag
                px[i * 4 + 2] = ab
            }
        }
        return pngBytes(px, width: w, height: h)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func appendChunk(_ out: inout [UInt8], _ kind: String, _ body: [UInt8]) {
        var typed = [UInt8](kind.utf8)
        typed.append(contentsOf: body)
        out.append(contentsOf: bigEndian(UInt32(body.count)))
        out.append(contentsOf: typed)
        out.append(contentsOf: bigEndian(crc32(typed)))
    }

    /// 8-bit RGBA, straight alpha, stored (uncompressed) deflate blocks.
    private static func pngBytes(_ px: [UInt8], width w: Int, height h: Int) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((w * 4 + 1) * h)
        for y in 0..<h {
            raw.append(0)
            raw.append(contentsOf: px[(y * w * 4)..<((y + 1) * w * 4)])
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        var z: [UInt8] = [0x78, 0x01]
        var position = 0
        while position < raw.count {
            let n = min(65535, raw.count - position)
            z.append(position + n >= raw.count ? 1 : 0)
            z.append(UInt8(n & 0xFF))
            z.append(UInt8((n >> 8) & 0xFF))
            z.append(UInt8(~n & 0xFF))
            z.append(UInt8((~n >> 8) & 0xFF))
            z.append(contentsOf: raw[position..<(position + n)])
            position += n
        }
        z.append(contentsOf: bigEndian((b << 16) | a))

        var header = bigEndian(UInt32(w))
        header.append(contentsOf: bigEndian(UInt32(h)))
        header.append(contentsOf: [8, 6, 0, 0, 0])
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        appendChunk(&out, "IHDR", header)
        appendChunk(&out, "IDAT", z)
        appendChunk(&out, "IEND", [])
        return Data(out)
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
        // The picture as it is, not a converted copy that may have lost its see-through parts.
        configuration.preferredAssetRepresentationMode = .current
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
            // A PNG is read from its own bytes: asking for a UIImage instead can
            // hand back a flattened copy whose see-through parts have turned black.
            let png = "public.png"
            if provider.hasItemConformingToTypeIdentifier(png) {
                provider.loadDataRepresentation(forTypeIdentifier: png) { data, _ in
                    let image = data.flatMap { UIImage(data: $0) }
                    DispatchQueue.main.async { self.onPick(image) }
                }
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async { self.onPick(object as? UIImage) }
            }
        }
    }
}

// MARK: - Preview

/// A still of the rope and picture, laid out the way the engine lays the tag
/// out: the box hangs from the rope's end, turned to the rope's last segment,
/// 17 % of its width back and half its height up, then moved by the position
/// sliders. The rope hangs from a dot standing for the head.
private struct WyrmCustomTagPreview: View {
    let stored: UIImage?
    let item: WyrmCustomTagItem

    var body: some View {
        Canvas { context, size in
            let start = CGPoint(x: 22, y: size.height * 0.28)
            let control = CGPoint(x: size.width * 0.3, y: size.height * 0.95)
            let end = CGPoint(x: size.width * 0.52, y: size.height * 0.62)
            var rope = Path()
            rope.move(to: start)
            rope.addQuadCurve(to: end, control: control)
            context.stroke(rope, with: .color(Color(wyrmCustomHex: item.c1)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            for width in [4.0, 3.0, 2.0] {
                context.stroke(rope, with: .color(Color(wyrmCustomHex: item.c2).opacity(0.5)),
                               style: StrokeStyle(lineWidth: CGFloat(width), lineCap: .round, lineJoin: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: start.x - 12, y: start.y - 12, width: 24, height: 24)),
                         with: .color(Color.gray.opacity(0.55)))
            guard let stored else { return }

            // The engine's box, in its units (the longer side is 170).
            let longest = max(stored.size.width, stored.size.height)
            guard longest > 0 else { return }
            let fit = 170 / longest
            let w = stored.size.width * fit * CGFloat(item.scale)
            let h = stored.size.height * fit * CGFloat(item.scale)
            let bx = -w * 0.17 + CGFloat(item.along) * w
            let by = -h * 0.5 + CGFloat(item.across) * h

            var local = context
            local.translateBy(x: end.x, y: end.y)
            local.rotate(by: .radians(Double(atan2(end.y - control.y, end.x - control.x))))
            let unit = size.height * 0.5 / 170
            local.scaleBy(x: unit, y: unit)
            local.draw(Image(uiImage: stored), in: CGRect(x: bx, y: by, width: w, height: h))
        }
        .frame(height: 150)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ATheme.card.opacity(0.88)))
    }
}

// MARK: - Section

/// "My tags": pictures of the player's own, rope colours, and a size and
/// position for the tag worn. Inserted above the built-in tag grid by
/// Scripts/wyrm-custom-tags-install.py.
struct WyrmCustomTagSection: View {
    @ObservedObject private var store = WyrmCustomTagStore.shared
    @State private var showingPicker = false
    @State private var notice: String?
    @State private var engine: (code: Int, text: String) = (0, "")
    private let ticker = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    private var activeItem: WyrmCustomTagItem? {
        guard let id = store.index.activeID else { return nil }
        return store.item(id)
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
                    WyrmCustomTagPreview(stored: store.storedImage(for: item.id), item: item)
                    engineLine
                    colourRow("Chain", binding: Binding(
                        get: { Color(wyrmCustomHex: store.item(item.id)?.c1 ?? item.c1) },
                        set: { store.setColours(item.id, c1: $0.wyrmCustomHex) }))
                    colourRow("Chain tip", binding: Binding(
                        get: { Color(wyrmCustomHex: store.item(item.id)?.c2 ?? item.c2) },
                        set: { store.setColours(item.id, c2: $0.wyrmCustomHex) }))
                    adjustSlider("Size", value: Binding(
                        get: { store.item(item.id)?.scale ?? 1 },
                        set: { store.setAdjust(item.id, scale: $0) }), range: 0.3...2.5)
                    adjustSlider("Along the chain", value: Binding(
                        get: { store.item(item.id)?.along ?? 0 },
                        set: { store.setAdjust(item.id, along: $0) }), range: -0.5...1.0)
                    adjustSlider("Up and down", value: Binding(
                        get: { store.item(item.id)?.across ?? 0 },
                        set: { store.setAdjust(item.id, across: $0) }), range: -1.0...1.0)
                    HStack(spacing: 10) {
                        smallButton("Turn", systemImage: "rotate.right") { store.turn(item.id) }
                        smallButton("Reset", systemImage: "arrow.counterclockwise") {
                            store.resetAdjust(item.id)
                            store.resetColours(item.id)
                        }
                        smallButton("Delete", systemImage: "trash") { store.delete(item.id) }
                    }
                }
                .padding(12).background(ATheme.card.opacity(0.88)).cornerRadius(14)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("LISTED TAGS").font(.androidWyrm(10, .bold)).tracking(0.8).foregroundColor(ATheme.quiet)
                Toggle(isOn: Binding(get: { store.index.originalColorsOn },
                                     set: { store.setOriginalColours(on: $0) })) {
                    Text("Chain colour").font(.androidWyrm(12.5, .semibold))
                }
                if store.index.originalColorsOn {
                    colourRow("Chain", binding: Binding(
                        get: { Color(wyrmCustomHex: store.index.originalC1) },
                        set: { store.setOriginalColours(c1: $0.wyrmCustomHex) }))
                    colourRow("Chain tip", binding: Binding(
                        get: { Color(wyrmCustomHex: store.index.originalC2) },
                        set: { store.setOriginalColours(c2: $0.wyrmCustomHex) }))
                }
                adjustSlider("Size", value: Binding(
                    get: { store.index.originalScale },
                    set: { store.setOriginalAdjust(scale: $0) }), range: 0.3...2.5)
                adjustSlider("Along the chain", value: Binding(
                    get: { store.index.originalAlong },
                    set: { store.setOriginalAdjust(along: $0) }), range: -0.5...1.0)
                adjustSlider("Up and down", value: Binding(
                    get: { store.index.originalAcross },
                    set: { store.setOriginalAdjust(across: $0) }), range: -1.0...1.0)
                smallButton("Reset", systemImage: "arrow.counterclockwise") { store.resetOriginalAdjust() }
            }
            .padding(12).background(ATheme.card.opacity(0.88)).cornerRadius(14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .onReceive(ticker) { _ in engine = WyrmCustomTagStore.engineStatus() }
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

    /// What the engine made of the picture, so a picture that does not appear in
    /// a match can be told from one that never got there.
    private var engineLine: some View {
        let ok = engine.code > 0
        let text = engine.text.isEmpty ? "waiting" : engine.text
        return Text("Engine: \(text)")
            .font(.androidWyrm(10.5))
            .foregroundColor(engine.code < 0 ? .red : (ok ? ATheme.quiet : ATheme.quiet.opacity(0.7)))
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

    private func adjustSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.androidWyrm(12, .semibold))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).font(.androidWyrm(11)).foregroundColor(ATheme.quiet)
            }
            Slider(value: value, in: range)
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
