// Package the approved artwork on a transparent macOS icon canvas.
import AppKit
import ImageIO

guard CommandLine.arguments.count == 3,
      let source = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil
      ),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Usage: swift pad-icon.swift <master.png> <output.png>")
}

// Normalize the visible silhouette, not the generator's variable canvas
// margin. Only measure opaque pixels: soft reflections/edge antialiasing must
// not make the monitor smaller. Drawing preserves the complete original alpha.
let sourceBitmap = NSBitmapImageRep(cgImage: image)
var left = image.width, top = image.height, right = -1, bottom = -1
for y in 0..<image.height {
    for x in 0..<image.width where sourceBitmap.colorAt(x: x, y: y)!.alphaComponent >= 0.5 {
        left = min(left, x)
        top = min(top, y)
        right = max(right, x)
        bottom = max(bottom, y)
    }
}
guard right >= left, bottom >= top else { fatalError("Icon master is empty") }
let size = 1024
let visibleBounds = CGRect(x: left, y: image.height - bottom - 1,
                           width: right - left + 1, height: bottom - top + 1)
let scale = CGFloat(size) * 0.81 / max(visibleBounds.width, visibleBounds.height)
let target = CGRect(x: CGFloat(size) / 2 - visibleBounds.midX * scale,
                    y: CGFloat(size) / 2 - visibleBounds.midY * scale,
                    width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
context.clear(bounds)
context.interpolationQuality = .high
context.draw(image, in: target)
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
