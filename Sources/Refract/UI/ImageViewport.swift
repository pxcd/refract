import AppKit
import ImageIO
import SwiftUI

private struct ImagePair: Equatable {
    let original: URL
    let enhanced: URL?
}

private struct Raster {
    let image: NSImage
    let pixels: CGSize

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        pixels = CGSize(width: cg.width, height: cg.height)
        image = NSImage(cgImage: cg, size: pixels)
    }
}

private struct LoadedImagePair {
    let original: Raster
    let enhanced: Raster?
}

private actor PreviewLoader {
    static let shared = PreviewLoader()

    func read(_ pair: ImagePair) throws -> LoadedImagePair {
        try Task.checkCancellation()
        let original = try Raster(url: pair.original)
        try Task.checkCancellation()
        return try LoadedImagePair(original: original, enhanced: pair.enhanced.map(Raster.init(url:)))
    }
}

struct ImageViewport: View {
    let original: URL
    var enhanced: URL?
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: LoadedImagePair?
    @State private var loadError: String?
    @State private var split: Double = 0.5
    @State private var zoom: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.3))
                if let loaded {
                    CanvasBridge(images: loaded, scale: displayScale, split: $split, zoom: $zoom)
                        .help(enhanced == nil ? "Pinch to zoom. Drag to pan." : "Drag the divider or press the arrow keys to compare. Pinch to zoom and drag the image to pan.")
                        .accessibilityLabel(enhanced == nil ? "Image preview" : "Before and after comparison")
                        .accessibilityValue(enhanced == nil ? "" : "Before covers \(Int(split * 100)) percent")
                        .accessibilityAdjustableAction { direction in
                            split = min(1, max(0, split + (direction == .increment ? 0.05 : -0.05)))
                        }
                    if enhanced != nil {
                        VStack {
                            HStack {
                                comparisonLabel("Before")
                                Spacer()
                                comparisonLabel("After")
                            }
                            Spacer()
                        }
                        .padding(12).allowsHitTesting(false)
                    }
                } else if let loadError {
                    ContentUnavailableView("Preview unavailable", systemImage: "photo.badge.exclamationmark",
                                           description: Text(loadError))
                } else {
                    ProgressView()
                }
            }
            Divider()
            HStack {
                if let canvas = loaded?.enhanced ?? loaded?.original {
                    Text("\(Int(canvas.pixels.width)) × \(Int(canvas.pixels.height))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fit") { zoom = nil }
                    .accessibilityLabel("Fit image to window")
                Button("100%") { zoom = 1 }
                    .help("One output pixel per display pixel")
                if let zoom, abs(zoom - 1) > 0.005 {
                    Text("\(Int(zoom * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.caption).buttonStyle(.borderless).padding(.horizontal, 12).frame(height: 32)
        }
        .task(id: ImagePair(original: original, enhanced: enhanced)) {
            let pair = ImagePair(original: original, enhanced: enhanced)
            loaded = nil
            loadError = nil
            split = 0.5
            zoom = nil
            do {
                let value = try await PreviewLoader.shared.read(pair)
                try Task.checkCancellation()
                loaded = value
            } catch {
                if !Task.isCancelled { loadError = error.localizedDescription }
            }
        }
    }

    private func comparisonLabel(_ value: String) -> some View {
        Text(value).font(.caption.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.64), in: Capsule())
    }
}

private struct CanvasBridge: NSViewRepresentable {
    let images: LoadedImagePair
    let scale: CGFloat
    @Binding var split: Double
    @Binding var zoom: Double?

    func makeNSView(context: Context) -> ComparisonCanvas { ComparisonCanvas() }

    func updateNSView(_ view: ComparisonCanvas, context: Context) {
        view.onSplit = { split = $0 }
        view.onZoom = { zoom = $0 }
        view.configure(images: images, displayScale: scale, split: split, zoom: zoom)
    }
}

private final class ComparisonCanvas: NSView {
    private var images: LoadedImagePair?
    private var displayScale: CGFloat = 2
    private var split = 0.5
    private var zoom: Double?
    private var pan = CGSize.zero
    private var lastDrag: NSPoint?
    private var draggingDivider = false
    var onSplit: ((Double) -> Void)?
    var onZoom: ((Double) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func configure(images: LoadedImagePair, displayScale: CGFloat, split: Double, zoom: Double?) {
        if self.images?.original.image !== images.original.image || self.zoom != nil && zoom == nil {
            pan = .zero
        }
        self.images = images
        self.displayScale = displayScale
        self.split = split
        self.zoom = zoom
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private var pixels: CGSize { (images?.enhanced ?? images?.original)?.pixels ?? .zero }

    private var fitScale: Double {
        guard pixels.width > 0, pixels.height > 0 else { return 1 }
        return min(bounds.width / pixels.width, bounds.height / pixels.height) * displayScale
    }

    private var imageFrame: CGRect {
        let scale = (zoom ?? fitScale) / displayScale
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        return CGRect(x: bounds.midX - size.width / 2 + pan.width,
                      y: bounds.midY - size.height / 2 + pan.height,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let images else { return }
        let destination = backingAlignedRect(imageFrame, options: [.alignAllEdgesNearest])
        let context = NSGraphicsContext.current
        context?.imageInterpolation = .high
        func drawRaster(_ raster: Raster) {
            raster.image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let enhanced = images.enhanced {
            let divider = split * bounds.width
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: divider, height: bounds.height)).addClip()
            drawRaster(images.original)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: divider, y: 0, width: bounds.width - divider, height: bounds.height)).addClip()
            drawRaster(enhanced)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: divider - 1.5, y: 0, width: 3, height: bounds.height)).fill()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: divider - 0.5, y: 0, width: 1, height: bounds.height)).fill()
            let handle = NSRect(x: divider - 15, y: bounds.midY - 15, width: 30, height: 30)
            NSColor.black.withAlphaComponent(0.76).setFill()
            NSBezierPath(ovalIn: handle).fill()
            let chevrons = NSBezierPath()
            for sign: CGFloat in [-1, 1] {
                chevrons.move(to: .init(x: divider + sign * 4, y: bounds.midY - 4))
                chevrons.line(to: .init(x: divider + sign * 8, y: bounds.midY))
                chevrons.line(to: .init(x: divider + sign * 4, y: bounds.midY + 4))
            }
            NSColor.white.setStroke()
            chevrons.lineWidth = 1.6
            chevrons.stroke()
        } else {
            drawRaster(images.original)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
        if images?.enhanced != nil {
            addCursorRect(.init(x: split * bounds.width - 15, y: 0, width: 30, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard images?.enhanced != nil else { super.keyDown(with: event); return }
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        switch event.keyCode {
        case 123: setDivider(split - step)
        case 124: setDivider(split + step)
        case 115: setDivider(0)
        case 119: setDivider(1)
        default: super.keyDown(with: event)
        }
    }

    private func setDivider(_ fraction: Double) {
        split = min(1, max(0, fraction))
        onSplit?(split)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        draggingDivider = images?.enhanced != nil && abs(p.x - split * bounds.width) <= 16
        lastDrag = p
        if !draggingDivider { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if draggingDivider {
            setDivider(p.x / max(1, bounds.width))
        } else {
            moveBy(dx: p.x - lastDrag.x, dy: p.y - lastDrag.y)
        }
        self.lastDrag = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if lastDrag != nil && !draggingDivider { NSCursor.pop() }
        lastDrag = nil
    }

    private func moveBy(dx: CGFloat, dy: CGFloat) {
        let frame = imageFrame
        let limitX = max(0, (frame.width - bounds.width) / 2)
        let limitY = max(0, (frame.height - bounds.height) / 2)
        pan.width = min(limitX, max(-limitX, pan.width + dx))
        pan.height = min(limitY, max(-limitY, pan.height + dy))
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        moveBy(dx: event.scrollingDeltaX * factor, dy: event.scrollingDeltaY * factor)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let old = max(0.001, zoom ?? fitScale)
        let next = min(max(8, fitScale), max(min(fitScale, 0.1), old * (1 + event.magnification)))
        let p = convert(event.locationInWindow, from: nil)
        let ratio = next / old
        pan.width = (p.x - bounds.midX) * (1 - ratio) + pan.width * ratio
        pan.height = (p.y - bounds.midY) * (1 - ratio) + pan.height * ratio
        zoom = next
        moveBy(dx: 0, dy: 0)
        onZoom?(next)
        needsDisplay = true
    }
}
