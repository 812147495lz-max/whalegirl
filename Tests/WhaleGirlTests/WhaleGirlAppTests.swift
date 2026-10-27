import AppKit
import QuartzCore
import WhaleCore
import XCTest
@testable import WhaleGirl

@MainActor
final class WhaleGirlAppTests: XCTestCase {
    func syntheticActivityFrame(tailOriginX: Int) -> NSImage {
        let size = CGSize(width: 100, height: 60)
        let context = CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8,
                                bytesPerRow: 100 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 40, y: 10, width: 20, height: 20))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: tailOriginX, y: 15, width: 8, height: 8))
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    func rgbaPixels(of image: NSImage) -> [UInt8]? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                                          bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        return rendered ? pixels : nil
    }

    func pixel(atX x: Int, y: Int, in pixels: [UInt8]) -> [UInt8] {
        let index = (y * 100 + x) * 4
        return Array(pixels[index..<(index + 4)])
    }

    func wanderingFixture() throws -> (SpriteRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        let community = resources.appendingPathComponent("CommunityActions")
        try FileManager.default.createDirectory(at: community, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "io.whalegirl.tests." + UUID().uuidString,
                                   "CFBundlePackageType": "BNDL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        func writeJSON(_ value: Any, to url: URL) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        try writeJSON(["schemaVersion": 1, "atlases": [], "clips": []],
                      to: resources.appendingPathComponent("sprite-manifest.json"))
        func frame(_ x: Int) -> [String: Any] {
            ["rect": ["x": x, "y": 0, "width": 4, "height": 4], "duration": 0.03,
             "anchor": ["x": 0.5, "y": 1],
             "visualBounds": ["x": 0, "y": 0, "width": 1, "height": 1],
             "hitbox": ["x": 0, "y": 0, "width": 1, "height": 1]]
        }
        let idle: [String: Any] = ["id": "full.community.idle", "atlasID": "community.fixture",
                                   "looping": true, "frames": [frame(0)]]
        let running: [String: Any] = ["id": "full.community.running", "atlasID": "community.fixture",
                                      "looping": false, "frames": (0..<52).map { frame(($0 % 2) * 4) }]
        let manual: [String: Any] = ["id": "full.community.manual", "atlasID": "community.fixture",
                                     "looping": false, "frames": [frame(4)]]
        try writeJSON(["schemaVersion": 1,
                       "atlases": [["id": "community.fixture", "resource": "CommunityActions/fixture.png",
                                    "pixelWidth": 8, "pixelHeight": 4]],
                       "clips": [idle, running, manual]], to: community.appendingPathComponent("sprite-manifest.json"))
        try writeJSON(["aliases": ["idle": "full.community.idle"],
                       "actions": [["clipID": "full.community.idle", "title": "待机", "category": "测试"],
                                   ["clipID": "full.community.running", "title": "原地左转奔跑", "category": "测试"]]],
                      to: community.appendingPathComponent("catalog.json"))
        var pixels = [UInt8](repeating: 0, count: 8 * 4 * 4)
        for y in 0..<4 {
            for x in [0, 1, 4, 5] {
                let index = (y * 8 + x) * 4
                pixels[index] = 255
                pixels[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 8, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: community.appendingPathComponent("fixture.png"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        return (try SpriteRepository(bundle: bundle), root)
    }

    @nonobjc func waitForWanderingCondition(timeout: Double = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for autonomous activity")
    }

    func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }

    func attachSnapshot(of view: NSView, named name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), file: file, line: line)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
