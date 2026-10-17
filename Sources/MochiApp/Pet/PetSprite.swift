import AppKit

/// Mochi's sprite sheet, cut into cells once and shared by every view that draws her. Immutable after loading.
final class PetSprite: @unchecked Sendable {
    static let shared = PetSprite(resource: AppResources.url("mochi", "webp"))
    static let cellSize = CGSize(width: 192, height: 208)

    /// The atlas the Codex v2 pet format defines: 8 columns by 11 rows of cells.
    static let atlasSize = (width: 1536, height: 2288)
    /// Every cell, row by row; empty when the sheet is missing or is not a complete v2 atlas.
    private let cells: [CGImage]

    init(resource: URL?) {
        let image = resource.flatMap(NSImage.init(contentsOf:))
        let atlas = image?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(Self.decoded)
        guard let atlas, atlas.width == Self.atlasSize.width, atlas.height == Self.atlasSize.height else {
            cells = []
            return
        }
        let cut = (0..<88).compactMap { index in
            atlas.cropping(
                to: CGRect(
                    x: CGFloat(index % 8) * Self.cellSize.width, y: CGFloat(index / 8) * Self.cellSize.height,
                    width: Self.cellSize.width, height: Self.cellSize.height))
        }
        cells = cut.count == 88 ? cut : []
    }

    /// The sheet decoded once into memory. Cells cropped from the compressed image would decode the whole sheet
    /// again each time one is drawn.
    private static func decoded(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    var isLoaded: Bool { !cells.isEmpty }

    func cell(row: Int, column: Int) -> CGImage? {
        let index = row * 8 + column
        return cells.indices.contains(index) && (0..<8).contains(column) ? cells[index] : nil
    }

    func frames(_ pose: PetPose) -> [CGImage] {
        (0..<pose.durations.count).compactMap { cell(row: pose.rawValue, column: $0) }
    }

    /// The union of every animated pose's opaque pixels, so a click lands on her whichever frame is showing.
    /// Built only for the desktop window, which is the only place that needs it.
    struct BodyMask {
        private let opaque: [Bool]
        private let width = Int(PetSprite.cellSize.width)
        private let height = Int(PetSprite.cellSize.height)

        init(_ sprite: PetSprite) {
            opaque = sprite.isLoaded ? Self.union(sprite) : []
        }

        /// Every frame drawn over the others in one context; a pixel any frame covers ends up opaque.
        private static func union(_ sprite: PetSprite) -> [Bool] {
            let width = Int(PetSprite.cellSize.width)
            let height = Int(PetSprite.cellSize.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                for pose in PetPose.allCases {
                    for cell in sprite.frames(pose) {
                        context.draw(cell, in: CGRect(x: 0, y: 0, width: width, height: height))
                    }
                }
            }
            // The context's first row is the image's top row.
            return (0..<(width * height)).map { pixels[$0 * 4 + 3] > 40 }
        }

        /// Whether a point in the cell, scaled to 0...1 with the origin at the bottom left, is on her body.
        func contains(x: Double, y: Double) -> Bool {
            guard !opaque.isEmpty, (0..<1).contains(x), (0..<1).contains(y) else { return false }
            let column = Int(x * Double(width))
            let row = Int((1 - y) * Double(height))
            return opaque[min(height - 1, row) * width + column]
        }

        var isEmpty: Bool { !opaque.contains(true) }
    }
}
