import AppKit
import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_macos_icon.swift <iconset-directory> <icns-output>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icnsOutput = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes = [16, 32, 128, 256, 512]

func render(pixelSize: Int, logicalSize: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: pixelSize, height: pixelSize,
                                  bitsPerComponent: 8, bytesPerRow: pixelSize * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "NimculusIcon", code: 1)
    }
    let scale = CGFloat(pixelSize) / CGFloat(logicalSize)
    context.scaleBy(x: scale, y: scale)
    let bounds = CGRect(x: 0, y: 0, width: logicalSize, height: logicalSize)
    context.setFillColor(NSColor(calibratedRed: 0.122, green: 0.137, blue: 0.161, alpha: 1).cgColor)
    context.addPath(CGPath(roundedRect: bounds.insetBy(dx: CGFloat(logicalSize) * 0.18,
                                                       dy: CGFloat(logicalSize) * 0.18),
                           cornerWidth: CGFloat(logicalSize) * 0.14,
                           cornerHeight: CGFloat(logicalSize) * 0.14, transform: nil))
    context.fillPath()

    context.setFillColor(NSColor(calibratedRed: 0.302, green: 0.667, blue: 0.988, alpha: 1).cgColor)
    let left = CGFloat(logicalSize) * 0.27
    let right = CGFloat(logicalSize) * 0.73
    let top = CGFloat(logicalSize) * 0.72
    let bottom = CGFloat(logicalSize) * 0.28
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left, y: bottom))
    path.addLine(to: CGPoint(x: left, y: top))
    path.addLine(to: CGPoint(x: left + CGFloat(logicalSize) * 0.13, y: top))
    path.addLine(to: CGPoint(x: CGFloat(logicalSize) * 0.5, y: CGFloat(logicalSize) * 0.50))
    path.addLine(to: CGPoint(x: right - CGFloat(logicalSize) * 0.13, y: top))
    path.addLine(to: CGPoint(x: right, y: top))
    path.addLine(to: CGPoint(x: right, y: bottom))
    path.closeSubpath()
    context.addPath(path)
    context.fillPath()

    guard let image = context.makeImage() else {
        throw NSError(domain: "NimculusIcon", code: 2)
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "NimculusIcon", code: 3)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "NimculusIcon", code: 4)
    }
    try (data as Data).write(to: url)
}

for size in sizes {
    try render(pixelSize: size, logicalSize: size,
               to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixelSize: size * 2, logicalSize: size,
               to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let imageURLs = sizes.flatMap { size in
    [
        output.appendingPathComponent("icon_\(size)x\(size).png"),
        output.appendingPathComponent("icon_\(size)x\(size)@2x.png")
    ]
}
let images = try imageURLs.map { url -> CGImage in
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "NimculusIcon", code: 5)
    }
    return image
}
guard let destination = CGImageDestinationCreateWithURL(
    icnsOutput as CFURL, "com.apple.icns" as CFString, images.count, nil) else {
    throw NSError(domain: "NimculusIcon", code: 6)
}
for image in images {
    CGImageDestinationAddImage(destination, image, nil)
}
guard CGImageDestinationFinalize(destination) else {
    throw NSError(domain: "NimculusIcon", code: 7)
}
