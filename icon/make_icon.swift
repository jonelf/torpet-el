// Draws the app icon: a photo of the cottage with a glowing lightning bolt on top.
// Run via icon/make_icon.sh, which turns the 1024 px PNG into AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
func path(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
    // Points are given with y pointing down (like a drawing); flip to CoreGraphics.
    let p = CGMutablePath()
    p.move(to: CGPoint(x: pts[0].0, y: size - pts[0].1))
    for pt in pts.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: size - pt.1)) }
    p.closeSubpath()
    return p
}
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: size - y - h, width: w, height: h)
}

// macOS icon grid: 824 px rounded square centred on a 1024 canvas.
let body = rect(100, 100, 824, 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x0b1430)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()

// Photo of the cottage in winter (icon/torpet.jpg), filling the tile.
let photoPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "torpet.jpg"
let photoSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: photoPath) as CFURL, nil)!
let photo = CGImageSourceCreateImageAtIndex(photoSrc, 0, nil)!
ctx.interpolationQuality = .high
ctx.draw(photo, in: body)

// Dusk tint: darker and bluer at the top so the bolt stands out against the grey sky.
ctx.drawLinearGradient(gradient([rgb(0x0a0f2c, 0.6), rgb(0x1d2f6b, 0.25), rgb(0x1d2f6b, 0)], [0, 0.45, 0.8]),
                       start: CGPoint(x: 0, y: size - 100), end: CGPoint(x: 0, y: 100), options: [])

// Lightning bolt with a glow, slanting down across the right side.
let bolt = path([(775, 175), (625, 500), (720, 500), (650, 830), (885, 430), (780, 430), (865, 175)])

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0xffd23f, 0.95))
ctx.addPath(bolt); ctx.setFillColor(rgb(0xffd23f)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bolt); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xfffbe0), rgb(0xffe14d), rgb(0xffa21f)], [0, 0.45, 1]),
                       start: CGPoint(x: 750, y: size - 175), end: CGPoint(x: 750, y: size - 830), options: [])
ctx.restoreGState()

ctx.addPath(bolt); ctx.setStrokeColor(rgb(0xb35a00)); ctx.setLineWidth(10); ctx.setLineJoin(.round)
ctx.strokePath()

// Soft highlight on the top of the tile.
ctx.drawLinearGradient(gradient([rgb(0xffffff, 0.14), rgb(0xffffff, 0)], [0, 1]),
                       start: CGPoint(x: 0, y: size - 100), end: CGPoint(x: 0, y: size - 450), options: [])
ctx.restoreGState()

// Thin rim.
ctx.addPath(squircle); ctx.setStrokeColor(rgb(0xffffff, 0.12)); ctx.setLineWidth(3); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
