import Cocoa
let directory = CommandLine.arguments[1]
for (size, scale) in [(16,1), (16,2), (32,1), (32,2), (128,1), (128,2), (256,1), (256,2), (512,1), (512,2)] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let n = CGFloat(pixels)
    let rect = NSRect(x: n * 0.06, y: n * 0.06, width: n * 0.88, height: n * 0.88)
    NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.15, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: n * 0.20, yRadius: n * 0.20).fill()
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    let text = "한"
    let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize: n * 0.49, weight: .bold), .foregroundColor:NSColor(calibratedRed: 0.54, green: 0.96, blue: 0.73, alpha: 1), .paragraphStyle:paragraph]
    text.draw(in: NSRect(x: 0, y: n * 0.22, width: n, height: n * 0.62), withAttributes: attributes)
    NSColor(calibratedRed: 0.54, green: 0.96, blue: 0.73, alpha: 0.6).setFill()
    NSBezierPath(roundedRect: NSRect(x:n * 0.32, y:n * 0.19, width:n * 0.36, height:n * 0.045), xRadius:n * 0.02, yRadius:n * 0.02).fill()
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
}
