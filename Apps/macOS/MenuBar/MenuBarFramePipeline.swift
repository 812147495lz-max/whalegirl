import AppKit

enum MenuBarFramePipeline {
    struct PreparedMenuBarFrames: @unchecked Sendable {
        let activity: [NSImage]
        let hover: [String: [NSImage]]
    }

    nonisolated static func prepareHoverFrames(resourceURL: URL) -> [String: [NSImage]] {
        var loadedHoverFrames: [String: [NSImage]] = [:]
        let kinds = ["appear", "disappear", "wink"]
        for kind in kinds {
            let folderURL = resourceURL
                .appendingPathComponent("HoverAnimations", isDirectory: true)
                .appendingPathComponent(kind, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            loadedHoverFrames[kind] = files.compactMap(NSImage.init(contentsOf:))
        }
        let flattened = kinds.flatMap { loadedHoverFrames[$0] ?? [] }
        let fittedHoverFrames = fittedActivityFrames(flattened)
        var offset = 0
        for kind in kinds {
            let count = loadedHoverFrames[kind]?.count ?? 0
            loadedHoverFrames[kind] = Array(fittedHoverFrames.dropFirst(offset).prefix(count))
            offset += count
        }

        return loadedHoverFrames
    }

    nonisolated static func prepareMenuBarFrames(resourceURL: URL) -> PreparedMenuBarFrames {
        let directory = resourceURL.appendingPathComponent("MenuBarFrames", isDirectory: true)
        let sourceFrames: [NSImage] = (1...20).compactMap { index in
            NSImage(contentsOf: directory.appendingPathComponent("png_\(index).png"))
        }
        guard sourceFrames.count > 1 else {
            return PreparedMenuBarFrames(activity: sourceFrames, hover: [:])
        }
        var interpolatedFrames: [NSImage] = []
        for index in sourceFrames.indices {
            interpolatedFrames.append(sourceFrames[index])
            if index + 1 < sourceFrames.count {
                let tween = ActivityFrameMorpher.midpoint(from: sourceFrames[index], to: sourceFrames[index + 1])
                interpolatedFrames.append(tween ?? sourceFrames[index])
            }
        }
        return PreparedMenuBarFrames(activity: fittedActivityFrames(interpolatedFrames),
                                     hover: [:])
    }

    nonisolated static func fittedActivityFrames(_ images: [NSImage]) -> [NSImage] {
        let decoded = images.compactMap { image -> (NSImage, CGImage)? in
            var proposedRect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                return nil
            }
            return (image, cgImage)
        }
        guard decoded.count == images.count,
              let first = decoded.first?.1,
              decoded.allSatisfy({ $0.1.width == first.width && $0.1.height == first.height }) else {
            return images
        }

        let fullImageBounds = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        let frameBounds = decoded.compactMap { alphaBounds(of: $0.1) }
        guard frameBounds.count == decoded.count else { return images }
        let commonContentBounds = frameBounds
            .reduce(CGRect.null) { $0.union($1) }
            .integral
            .intersection(fullImageBounds)
        guard !commonContentBounds.isNull, !commonContentBounds.isEmpty else { return images }

        // Fit the union of every frame's visible pixels into the menu bar button.
        // Applying this one crop and scale to all frames keeps the body steady while
        // still reserving room for the tail's full range of motion.
        let targetSize = CGSize(width: 28, height: 24)
        let scale = min(targetSize.width / commonContentBounds.width,
                        targetSize.height / commonContentBounds.height)
        let displaySize = NSSize(width: commonContentBounds.width * scale,
                                 height: commonContentBounds.height * scale)

        var fitted: [NSImage] = []
        for (_, cgImage) in decoded {
            guard let cropped = cgImage.cropping(to: commonContentBounds) else { return images }
            fitted.append(NSImage(cgImage: cropped, size: displaySize))
        }
        return fitted
    }

    nonisolated private static func alphaBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
