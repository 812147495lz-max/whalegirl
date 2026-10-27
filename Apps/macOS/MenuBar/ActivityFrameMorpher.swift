import AppKit

enum ActivityFrameMorpher {
    private struct Raster {
        let width: Int
        let height: Int
        var pixels: [UInt8]
    }

    private struct Vector {
        var x: Double
        var y: Double
    }

    private static let meshStep = 8
    private static let searchRadius = 14
    private static let patchRadius = 3

    static func midpoint(from first: NSImage, to second: NSImage) -> NSImage? {
        guard let a = raster(from: first), let b = raster(from: second),
              a.width == b.width, a.height == b.height else { return nil }
        guard let changedBounds = changedBounds(a, b) else { return first }

        let padding = patchRadius + 2
        let minX = max(0, Int(changedBounds.minX) - padding)
        let minY = max(0, Int(changedBounds.minY) - padding)
        let maxX = min(a.width - 1, Int(changedBounds.maxX) + padding)
        let maxY = min(a.height - 1, Int(changedBounds.maxY) + padding)
        guard maxX > minX, maxY > minY else { return nil }

        let xCoordinates = meshCoordinates(from: minX, through: maxX)
        let yCoordinates = meshCoordinates(from: minY, through: maxY)
        let columns = xCoordinates.count
        let rows = yCoordinates.count
        guard columns > 1, rows > 1 else { return nil }

        var flow = [Vector](repeating: Vector(x: 0, y: 0), count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                flow[row * columns + column] = estimateFlow(
                    atX: xCoordinates[column],
                    y: yCoordinates[row],
                    from: a,
                    to: b
                )
            }
        }
        flow = medianSmoothed(flow, columns: columns, rows: rows)

        var output = a
        for y in minY...maxY {
            for x in minX...maxX {
                let pixel = pixelIndex(x: x, y: y, width: a.width)
                // Reuse unchanged visible pixels exactly. Transparent pixels are still
                // sampled so a moving tail can enter space that was empty in both keys.
                if a.pixels[pixel + 3] > 0,
                   (0..<4).allSatisfy({ a.pixels[pixel + $0] == b.pixels[pixel + $0] }) {
                    continue
                }

                let displacement = interpolatedFlow(
                    x: Double(x), y: Double(y),
                    xCoordinates: xCoordinates,
                    yCoordinates: yCoordinates,
                    flow: flow
                )
                let fromA = sample(a, x: Double(x) - displacement.x * 0.5,
                                   y: Double(y) - displacement.y * 0.5)
                let fromB = sample(b, x: Double(x) + displacement.x * 0.5,
                                   y: Double(y) + displacement.y * 0.5)
                for channel in 0..<4 {
                    output.pixels[pixel + channel] = UInt8(max(0, min(255,
                        (fromA[channel] * 0.5 + fromB[channel] * 0.5).rounded()
                    )))
                }
            }
        }

        guard let image = cgImage(from: output) else { return nil }
        return NSImage(cgImage: image, size: first.size)
    }

    private static func raster(from image: NSImage) -> Raster? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        guard rendered else { return nil }
        return Raster(width: cgImage.width, height: cgImage.height, pixels: pixels)
    }

    private static func cgImage(from raster: Raster) -> CGImage? {
        raster.pixels.withUnsafeBytes { buffer in
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
                width: raster.width,
                height: raster.height,
                bitsPerComponent: 8,
                bytesPerRow: raster.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    private static func changedBounds(_ a: Raster, _ b: Raster) -> CGRect? {
        var minX = a.width
        var minY = a.height
        var maxX = -1
        var maxY = -1
        for y in 0..<a.height {
            for x in 0..<a.width {
                let pixel = pixelIndex(x: x, y: y, width: a.width)
                guard (0..<4).contains(where: { a.pixels[pixel + $0] != b.pixels[pixel + $0] }),
                      a.pixels[pixel + 3] > 0 || b.pixels[pixel + 3] > 0 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func meshCoordinates(from start: Int, through end: Int) -> [Int] {
        var coordinates = Array(stride(from: start, through: end, by: meshStep))
        if coordinates.last != end { coordinates.append(end) }
        return coordinates
    }

    private static func estimateFlow(atX centerX: Int, y centerY: Int, from a: Raster, to b: Raster) -> Vector {
        var bestCost = Double.greatestFiniteMagnitude
        var bestX = 0
        var bestY = 0
        for dy in -searchRadius...searchRadius {
            for dx in -searchRadius...searchRadius {
                var cost = 0.0
                var weight = 0.0
                for offsetY in -patchRadius...patchRadius {
                    for offsetX in -patchRadius...patchRadius {
                        let ax = centerX + offsetX
                        let ay = centerY + offsetY
                        let bx = ax + dx
                        let by = ay + dy
                        guard ax >= 0, ay >= 0, bx >= 0, by >= 0,
                              ax < a.width, bx < b.width, ay < a.height, by < b.height else { continue }
                        let aPixel = pixelIndex(x: ax, y: ay, width: a.width)
                        let bPixel = pixelIndex(x: bx, y: by, width: b.width)
                        let aAlpha = Double(a.pixels[aPixel + 3]) / 255
                        let bAlpha = Double(b.pixels[bPixel + 3]) / 255
                        if aAlpha == 0 && bAlpha == 0 { continue }
                        let visibleWeight = max(aAlpha, bAlpha)
                        weight += visibleWeight
                        for channel in 0..<3 {
                            cost += abs(Double(a.pixels[aPixel + channel]) - Double(b.pixels[bPixel + channel])) * visibleWeight
                        }
                        cost += abs(aAlpha - bAlpha) * 255
                    }
                }
                if weight > 0 { cost /= weight }
                cost += Double(dx * dx + dy * dy) * 0.002
                if cost < bestCost {
                    bestCost = cost
                    bestX = dx
                    bestY = dy
                }
            }
        }
        return Vector(x: Double(bestX), y: Double(bestY))
    }

    private static func medianSmoothed(_ flow: [Vector], columns: Int, rows: Int) -> [Vector] {
        var smoothed = flow
        for row in 0..<rows {
            for column in 0..<columns {
                var horizontal: [Double] = []
                var vertical: [Double] = []
                for neighborRow in max(0, row - 1)...min(rows - 1, row + 1) {
                    for neighborColumn in max(0, column - 1)...min(columns - 1, column + 1) {
                        let displacement = flow[neighborRow * columns + neighborColumn]
                        horizontal.append(displacement.x)
                        vertical.append(displacement.y)
                    }
                }
                horizontal.sort()
                vertical.sort()
                smoothed[row * columns + column] = Vector(
                    x: horizontal[horizontal.count / 2],
                    y: vertical[vertical.count / 2]
                )
            }
        }
        return smoothed
    }

    private static func interpolatedFlow(
        x: Double,
        y: Double,
        xCoordinates: [Int],
        yCoordinates: [Int],
        flow: [Vector]
    ) -> Vector {
        let columns = xCoordinates.count
        let column = max(0, min(columns - 2, xCoordinates.lastIndex(where: { Double($0) <= x }) ?? 0))
        let row = max(0, min(yCoordinates.count - 2, yCoordinates.lastIndex(where: { Double($0) <= y }) ?? 0))
        let left = Double(xCoordinates[column])
        let right = Double(xCoordinates[column + 1])
        let top = Double(yCoordinates[row])
        let bottom = Double(yCoordinates[row + 1])
        let u = max(0, min(1, (x - left) / (right - left)))
        let v = max(0, min(1, (y - top) / (bottom - top)))
        let topLeft = flow[row * columns + column]
        let topRight = flow[row * columns + column + 1]
        let bottomLeft = flow[(row + 1) * columns + column]
        let bottomRight = flow[(row + 1) * columns + column + 1]

        // Two affine triangles per mesh cell keep the displacement local and stable.
        if v <= u {
            return Vector(
                x: topLeft.x * (1 - u) + topRight.x * (u - v) + bottomRight.x * v,
                y: topLeft.y * (1 - u) + topRight.y * (u - v) + bottomRight.y * v
            )
        }
        return Vector(
            x: topLeft.x * (1 - v) + bottomLeft.x * (v - u) + bottomRight.x * u,
            y: topLeft.y * (1 - v) + bottomLeft.y * (v - u) + bottomRight.y * u
        )
    }

    private static func sample(_ raster: Raster, x: Double, y: Double) -> [Double] {
        let sampleX = max(0, min(Double(raster.width - 1), x))
        let sampleY = max(0, min(Double(raster.height - 1), y))
        let x0 = Int(sampleX)
        let y0 = Int(sampleY)
        let x1 = min(raster.width - 1, x0 + 1)
        let y1 = min(raster.height - 1, y0 + 1)
        let fractionX = sampleX - Double(x0)
        let fractionY = sampleY - Double(y0)
        return (0..<4).map { channel in
            let topLeft = Double(raster.pixels[pixelIndex(x: x0, y: y0, width: raster.width) + channel])
            let topRight = Double(raster.pixels[pixelIndex(x: x1, y: y0, width: raster.width) + channel])
            let bottomLeft = Double(raster.pixels[pixelIndex(x: x0, y: y1, width: raster.width) + channel])
            let bottomRight = Double(raster.pixels[pixelIndex(x: x1, y: y1, width: raster.width) + channel])
            let top = topLeft * (1 - fractionX) + topRight * fractionX
            let bottom = bottomLeft * (1 - fractionX) + bottomRight * fractionX
            return top * (1 - fractionY) + bottom * fractionY
        }
    }

    private static func pixelIndex(x: Int, y: Int, width: Int) -> Int { (y * width + x) * 4 }
}
