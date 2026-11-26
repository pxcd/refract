import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFiles {
    static func dimensions(of url: URL) throws -> (Int, Int) {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw StudioError("Cannot open the selected image.")
        }
        return try dimensions(of: source)
    }

    static func dimensions(of source: CGImageSource) throws -> (Int, Int) {
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = info[kCGImagePropertyPixelWidth as String] as? Int,
              let h = info[kCGImagePropertyPixelHeight as String] as? Int else {
            throw StudioError("Cannot read the image dimensions.")
        }
        try validateDimensions(width: w, height: h)
        return (5...8).contains(info[kCGImagePropertyOrientation as String] as? Int ?? 1) ? (h,w) : (w,h)
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 65_535, height <= 65_535,
              width <= (64 * 1024 * 1024) / height else {
            throw StudioError("Images must fit within 67 megapixels and 65,535 pixels per side.")
        }
    }

    static func outputDimensions(for input: URL, options: EnhancementOptions) throws -> (Int, Int) {
        let (w,h) = try dimensions(of: input)
        return try outputDimensions(width: w, height: h, options: options)
    }

    static func outputDimensions(width w: Int, height h: Int, options: EnhancementOptions) throws -> (Int, Int) {
        guard w > 0, h > 0 else { throw StudioError("Enter positive image dimensions.") }
        let factor = options.customLongEdge.map { Double($0) / Double(max(w,h)) } ?? options.scale
        let width = (Double(w) * factor).rounded(), height = (Double(h) * factor).rounded()
        guard width >= 1, height >= 1, width <= 65535, height <= 65535 else {
            throw StudioError("The requested output dimensions are outside the supported image range.")
        }
        try validateDimensions(width: Int(width), height: Int(height))
        return (Int(width),Int(height))
    }

    static func expand(_ urls: [URL]) throws -> [InputImage] {
        var seen = Set<URL>()
        var result: [InputImage] = []
        func append(_ url: URL) throws {
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized).inserted else { return }
            _ = try dimensions(of: normalized)
            result.append(try InputImage(normalized))
        }
        for url in urls {
            let resource = try url.resourceValues(forKeys: [.isDirectoryKey])
            if resource.isDirectory == true {
                let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
                for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    if let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) {
                        try append(file)
                    }
                }
            } else {
                try append(url)
            }
        }
        guard !result.isEmpty else { throw StudioError("The selection contains no readable images.") }
        return result
    }

    static func export(_ image: URL, to destination: URL, format: ExportFormat, quality: Double, metadataSource: URL? = nil) throws {
        guard let input = CGImageSourceCreateWithURL(image as CFURL, nil) else {
            throw StudioError("Cannot read " + image.lastPathComponent)
        }
        _ = try dimensions(of: input)
        let info = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any]
        let orientation = info?[kCGImagePropertyOrientation] as? Int ?? 1
        let decoded: CGImage?
        if (2...8).contains(orientation) {
            // With no size limit ImageIO applies the EXIF transform at full resolution.
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldAllowFloat: true]
            decoded = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary)
        } else {
            decoded = CGImageSourceCreateImageAtIndex(input, 0, nil)
        }
        guard let pixels = decoded else { throw StudioError("Cannot decode " + image.lastPathComponent) }
        let type: UTType = format == .png ? .png : (format == .jpeg ? .jpeg : .tiff)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw StudioError("Could not create the output file.")
        }
        var options: [String: Any] = [kCGImagePropertyOrientation as String: 1]
        if let metadataSource,
           let source = CGImageSourceCreateWithURL(metadataSource as CFURL, nil),
           let sourceInfo = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            if let meta = sourceInfo[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                let kept = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength, kCGImagePropertyExifLensModel].map { $0 as String }
                options[kCGImagePropertyExifDictionary as String] = meta.filter { kept.contains($0.key) }
            }
        }
        if format == .jpeg { options[kCGImageDestinationLossyCompressionQuality as String] = min(max(quality,0),1) }
        CGImageDestinationAddImage(output, pixels, options as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw StudioError("Could not finish writing " + destination.lastPathComponent) }
    }

    static func publish(raw: URL, output: URL, format: ExportFormat, quality: Double, source: URL?, receipt: Data) throws {
        let fm = FileManager.default
        let parent = output.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let sidecar = output.appendingPathExtension("json")
        guard !fm.fileExists(atPath: output.path), !fm.fileExists(atPath: sidecar.path) else {
            throw StudioError("An output already exists: " + output.lastPathComponent)
        }
        let temp = parent.appendingPathComponent(".refract-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        try export(raw, to: temp, format: format, quality: quality, metadataSource: source)
        try publishStaged(temp, to: output, receipt: receipt)
    }

    static func publishStaged(_ file: URL, to output: URL, receipt: Data?) throws {
        let fm = FileManager.default
        let sidecar = output.appendingPathExtension("json")
        guard !fm.fileExists(atPath: sidecar.path) else {
            throw StudioError("A settings file already uses this name. Choose a new filename.")
        }
        try receipt?.write(to: sidecar, options: .withoutOverwriting)
        do { try fm.moveItem(at: file, to: output) }
        catch {
            if receipt != nil { try? fm.removeItem(at: sidecar) }
            throw error
        }
    }
}
