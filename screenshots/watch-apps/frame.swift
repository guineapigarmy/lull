// Draws an Apple Watch or a round Wear OS watch around a screenshot, for pull request screenshots. The framed copies are
// in framed/. To make them again:
//   for f in watchos-*.png; do swift frame.swift apple "$f" "framed/$f"; done
//   for f in wearos-*.png; do swift frame.swift wear "$f" "framed/$f"; done
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("usage: frame.swift apple|wear in.png out.png") }
let kind = args[1]
guard kind == "apple" || kind == "wear" else { fatalError("unknown watch \"\(kind)\": use apple or wear") }
let input = URL(fileURLWithPath: args[2])
let output = URL(fileURLWithPath: args[3])

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let shot = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("can't read \(input.path)") }

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ context: CGContext, _ path: CGPath, _ gradient: CGGradient, from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func stroke(_ context: CGContext, _ path: CGPath, _ color: CGColor, width: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.strokePath()
    context.restoreGState()
}

/// A soft shadow under the whole watch, as if it lay on a table.
func shadow(_ context: CGContext, _ path: CGPath, blur: CGFloat, offset: CGFloat) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur, color: color(0x000000, 0.45))
    context.addPath(path)
    context.setFillColor(color(0x101114))
    context.fillPath()
    context.restoreGState()
}

/// A knurled crown: a short cylinder, shaded round, with fine ridges.
func crown(_ context: CGContext, _ rect: CGRect, ridges: Int) {
    let body = roundedRect(rect, min(rect.width, rect.height) * 0.22)
    fill(context, body, gradient([(0x2a2d33, 1, 0), (0x8a8f98, 1, 0.35), (0x3b3f46, 1, 0.7), (0x1b1d21, 1, 1)]),
         from: CGPoint(x: rect.minX, y: rect.midY), to: CGPoint(x: rect.minX, y: rect.maxY))
    context.saveGState()
    context.addPath(body)
    context.clip()
    for index in 0..<ridges {
        let y = rect.minY + rect.height * (CGFloat(index) + 0.5) / CGFloat(ridges)
        context.move(to: CGPoint(x: rect.minX + rect.width * 0.35, y: y))
        context.addLine(to: CGPoint(x: rect.maxX, y: y))
    }
    context.setStrokeColor(color(0x000000, 0.35))
    context.setLineWidth(1.4)
    context.strokePath()
    context.restoreGState()
    stroke(context, body, color(0x000000, 0.5), width: 1)
}

/// A sport band strap running off the top or bottom of the case. Its near end tucks under the case.
func band(_ context: CGContext, _ rect: CGRect) {
    let radius = rect.width * 0.22
    let path = CGMutablePath()
    path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    fill(context, path, gradient([(0x15171b, 1, 0), (0x2b2f37, 1, 0.5), (0x15171b, 1, 1)]),
         from: CGPoint(x: rect.minX, y: rect.midY), to: CGPoint(x: rect.maxX, y: rect.midY))
    // A seam a little in from each edge, as moulded bands have.
    let inset = rect.insetBy(dx: rect.width * 0.06, dy: 0)
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.move(to: CGPoint(x: inset.minX, y: rect.minY))
    context.addLine(to: CGPoint(x: inset.minX, y: rect.maxY))
    context.move(to: CGPoint(x: inset.maxX, y: rect.minY))
    context.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
    context.setStrokeColor(color(0x000000, 0.25))
    context.setLineWidth(1.5)
    context.strokePath()
    context.restoreGState()
}

/// A faint sheen across the glass, brightest at the top left.
func sheen(_ context: CGContext, _ path: CGPath, _ rect: CGRect) {
    fill(context, path, gradient([(0xffffff, 0.10, 0), (0xffffff, 0.03, 0.35), (0xffffff, 0, 0.6)]),
         from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY))
}

let screenW = CGFloat(shot.width), screenH = CGFloat(shot.height)
let padding: CGFloat = 70

var width: CGFloat = 0, height: CGFloat = 0
var draw: (CGContext) -> Void = { _ in }

if kind == "apple" {
    // Apple Watch Series proportions: a squircle display inside black glass, an aluminum case, and the crown and side
    // button on the right.
    let border: CGFloat = screenW * 0.065, rim: CGFloat = screenW * 0.028
    let caseW = screenW + 2 * (border + rim), caseH = screenH + 2 * (border + rim)
    let bandW = caseW * 0.74, bandL = caseH * 0.42
    width = caseW + 2 * padding + 30
    height = caseH + 2 * bandL + 2 * padding * 0.3
    draw = { context in
        let caseRect = CGRect(x: padding, y: (height - caseH) / 2, width: caseW, height: caseH)
        let caseRadius = caseW * 0.27
        band(context, CGRect(x: caseRect.midX - bandW / 2, y: caseRect.maxY - caseH * 0.1, width: bandW, height: bandL + caseH * 0.1))
        band(context, CGRect(x: caseRect.midX - bandW / 2, y: caseRect.minY - bandL, width: bandW, height: bandL + caseH * 0.1))
        let casePath = roundedRect(caseRect, caseRadius)
        shadow(context, casePath, blur: 40, offset: 14)
        // The crown and side button sit under the case's edge.
        crown(context, CGRect(x: caseRect.maxX - 12, y: caseRect.maxY - caseH * 0.36, width: 34, height: caseH * 0.15), ridges: 16)
        let button = CGRect(x: caseRect.maxX - 8, y: caseRect.midY - caseH * 0.2, width: 16, height: caseH * 0.2)
        fill(context, roundedRect(button, 7), gradient([(0x2a2d33, 1, 0), (0x6e737c, 1, 0.5), (0x22252a, 1, 1)]),
             from: CGPoint(x: button.minX, y: button.midY), to: CGPoint(x: button.maxX, y: button.midY))
        // Midnight aluminum, lit from the top left.
        fill(context, casePath, gradient([(0x4a4f59, 1, 0), (0x2a2e35, 1, 0.45), (0x15171b, 1, 1)]),
             from: CGPoint(x: caseRect.minX, y: caseRect.maxY), to: CGPoint(x: caseRect.maxX, y: caseRect.minY))
        stroke(context, roundedRect(caseRect.insetBy(dx: 1.5, dy: 1.5), caseRadius - 1.5), color(0xffffff, 0.18), width: 2)
        // The black glass over the whole face.
        let glassRect = caseRect.insetBy(dx: rim, dy: rim)
        let glassPath = roundedRect(glassRect, caseRadius - rim)
        context.addPath(glassPath)
        context.setFillColor(color(0x000000))
        context.fillPath()
        stroke(context, glassPath, color(0xffffff, 0.08), width: 1.5)
        // The display, rounded as the watch's is.
        let screenRect = glassRect.insetBy(dx: border, dy: border)
        let screenPath = roundedRect(screenRect, caseRadius - rim - border * 0.9)
        context.saveGState()
        context.addPath(screenPath)
        context.clip()
        context.draw(shot, in: screenRect)
        context.restoreGState()
        sheen(context, glassPath, glassRect)
    }
} else {
    // A round Wear OS watch: a domed display in black glass, a dark metal bezel, and the crown at three o'clock.
    let border: CGFloat = screenW * 0.04, bezel: CGFloat = screenW * 0.035
    let diameter = screenW + 2 * (border + bezel)
    let bandW = diameter * 0.58, bandL = diameter * 0.42
    width = diameter + 2 * padding + 30
    height = diameter + 2 * bandL + 2 * padding * 0.3
    draw = { context in
        let caseRect = CGRect(x: padding, y: (height - diameter) / 2, width: diameter, height: diameter)
        band(context, CGRect(x: caseRect.midX - bandW / 2, y: caseRect.maxY - diameter * 0.15, width: bandW, height: bandL + diameter * 0.15))
        band(context, CGRect(x: caseRect.midX - bandW / 2, y: caseRect.minY - bandL, width: bandW, height: bandL + diameter * 0.15))
        let casePath = CGPath(ellipseIn: caseRect, transform: nil)
        shadow(context, casePath, blur: 40, offset: 14)
        crown(context, CGRect(x: caseRect.maxX - 14, y: caseRect.midY - diameter * 0.07, width: 38, height: diameter * 0.14), ridges: 14)
        // Brushed dark metal, lit from the top left.
        fill(context, casePath, gradient([(0x5a5f68, 1, 0), (0x2c2f35, 1, 0.5), (0x141518, 1, 1)]),
             from: CGPoint(x: caseRect.minX, y: caseRect.maxY), to: CGPoint(x: caseRect.maxX, y: caseRect.minY))
        stroke(context, CGPath(ellipseIn: caseRect.insetBy(dx: 1.5, dy: 1.5), transform: nil), color(0xffffff, 0.2), width: 2)
        let glassRect = caseRect.insetBy(dx: bezel, dy: bezel)
        let glassPath = CGPath(ellipseIn: glassRect, transform: nil)
        context.addPath(glassPath)
        context.setFillColor(color(0x000000))
        context.fillPath()
        let screenRect = glassRect.insetBy(dx: border, dy: border)
        context.saveGState()
        context.addPath(CGPath(ellipseIn: screenRect, transform: nil))
        context.clip()
        context.draw(shot, in: screenRect)
        context.restoreGState()
        // A domed glass catches more light than a flat one.
        fill(context, glassPath, gradient([(0xffffff, 0.14, 0), (0xffffff, 0.04, 0.3), (0xffffff, 0, 0.55)]),
             from: CGPoint(x: glassRect.minX, y: glassRect.maxY), to: CGPoint(x: glassRect.maxX, y: glassRect.minY))
        stroke(context, glassPath, color(0xffffff, 0.1), width: 1.5)
    }
}

let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setShouldAntialias(true)
context.interpolationQuality = .high
draw(context)

let image = context.makeImage()!
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("can't write \(output.path): does its folder exist?")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(output.path)") }
