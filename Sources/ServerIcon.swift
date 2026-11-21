import SwiftUI
import UniformTypeIdentifiers
import ImageIO
typealias ViewState<Value> = SwiftUI.State<Value>

struct CropSource: Identifiable {
    let id = UUID()
    let pixels: CGImage

    init(file: URL) throws {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw LanternError("Choose a readable image, such as a PNG, JPEG, or HEIC photo.") }
        pixels = image
    }

    func crop(zoom: Double, x: Double, y: Double) -> CGImage? {
        let width = Double(pixels.width), height = Double(pixels.height)
        let edge = max(1, floor(min(width, height) / zoom))
        let rect = CGRect(x: round((width-edge)*x), y: round((height-edge)*y), width: edge, height: edge)
        return pixels.cropping(to: rect)
    }

    static func png(_ crop: CGImage) throws -> Data {
        guard let canvas = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                     bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LanternError("The server icon could not be created.") }
        canvas.interpolationQuality = .high
        canvas.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let bytes = NSMutableData()
        guard let pixels = canvas.makeImage(), let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)
        else { throw LanternError("The icon could not be encoded.") }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination) else { throw LanternError("The icon could not be saved.") }
        return bytes as Data
    }
}

struct ServerIconPicker: View {
    let profile: URL
    let enabled: Bool
    @ViewState<CropSource?> private var source: CropSource?
    @ViewState<NSImage?> private var icon: NSImage?
    @ViewState<String?> private var failure: String?
    private var file: URL { profile.appendingPathComponent("server-icon.png") }

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let file = panel.url else { return }
            do { source = try CropSource(file: file) }
            catch { failure = error.localizedDescription }
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().interpolation(.none) }
                    else { Image(systemName: "photo.badge.plus").font(.title2) }
                }.frame(width: 33, height: 33)
                Text("Edit icon").font(.caption2)
            }.frame(width: 60, height: 60).background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).foregroundStyle(.tint).disabled(!enabled)
        .accessibilityLabel("Choose and crop a server icon from your Mac")
        .task(id: file) { icon = NSImage(contentsOf: file) }
        .sheet(item: $source) { item in
            IconCropEditor(source: item) { crop in
                let png = try CropSource.png(crop)
                try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
                try png.write(to: file, options: .atomic)
                icon = NSImage(data: png)
                source = nil
            }
        }
        .alert("Image could not be opened", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

struct IconCropEditor: View {
    let source: CropSource
    let save: (CGImage) throws -> Void
    @Environment(\.dismiss) var dismiss
    @ViewState<Double> private var zoom = 1.0
    @ViewState<Double> private var x = 0.5
    @ViewState<Double> private var y = 0.5
    @ViewState<String?> private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Crop server icon").font(.title2.bold())
            Text("Choose the square friends see in Minecraft.").foregroundStyle(.secondary)
            if let crop = source.crop(zoom: zoom, x: x, y: y) {
                Image(decorative: crop, scale: 1).resizable().frame(width: 200, height: 200)
                    .frame(maxWidth: .infinity)
                Grid(alignment: .leading) {
                    GridRow { Text("Zoom"); Slider(value: $zoom, in: 1...4).accessibilityLabel("Crop zoom") }
                    GridRow { Text("Horizontal"); Slider(value: $x).accessibilityLabel("Horizontal position") }
                    GridRow { Text("Vertical"); Slider(value: $y).accessibilityLabel("Vertical position") }
                }
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Text("64 × 64 PNG").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save icon") {
                        do { try save(crop) } catch { self.error = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 400)
    }
}
