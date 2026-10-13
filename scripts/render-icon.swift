// Draws Harbor's app icon.
//
//   swift scripts/render-icon.swift [output directory]
//
// Writes the three 1024-pixel images of Host/Assets.xcassets/AppIcon.appiconset:
// the standard icon, the one for dark mode and the grey one iOS tints. The
// icon is drawn here, not kept as artwork, so it can be changed in a review.
//
// The picture is a harbour seen from above: a breakwater curving round a
// sheltered app, and a light coming in through the entrance.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024

struct Colour {
    var red, green, blue: CGFloat

    init(_ hex: UInt32) {
        red = CGFloat((hex >> 16) & 0xff) / 255
        green = CGFloat((hex >> 8) & 0xff) / 255
        blue = CGFloat(hex & 0xff) / 255
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

struct Palette {
    var name: String
    /// Background, from the top left corner to the bottom right.
    var backgroundStart, backgroundEnd: Colour
    var breakwater: Colour
    var app: Colour
    var light: Colour
}

let palettes = [
    Palette(
        name: "light",
        backgroundStart: Colour(0x1BB3AC), backgroundEnd: Colour(0x0B2F5C),
        breakwater: Colour(0xFFFFFF), app: Colour(0xFFFFFF), light: Colour(0xFFC043)),
    Palette(
        name: "dark",
        backgroundStart: Colour(0x10242F), backgroundEnd: Colour(0x04080C),
        breakwater: Colour(0x58D5CD), app: Colour(0x58D5CD), light: Colour(0xFFC043)),
    // iOS replaces the colour of this one and keeps its brightness.
    Palette(
        name: "tinted",
        backgroundStart: Colour(0x000000), backgroundEnd: Colour(0x000000),
        breakwater: Colour(0xFFFFFF), app: Colour(0xB0B0B0), light: Colour(0xFFFFFF)),
]

// Geometry, in a 1024 grid with the origin at the top left.
let centre = CGPoint(x: 512, y: 512)
let breakwaterRadius: CGFloat = 292
let breakwaterWidth: CGFloat = 90
/// The breakwater runs clockwise between these angles, measured clockwise
/// from east. What is left open, to the north east, is the entrance.
let breakwaterStart: CGFloat = -4
let breakwaterEnd: CGFloat = 274
let appSide: CGFloat = 228
let appCornerRadius: CGFloat = 62
let lightRadius: CGFloat = 44
let lightAngle: CGFloat = -45
let lightDistance: CGFloat = 308

func point(angle degrees: CGFloat, distance: CGFloat) -> CGPoint {
    let radians = degrees * .pi / 180
    return CGPoint(x: centre.x + distance * cos(radians), y: centre.y + distance * sin(radians))
}

func draw(_ palette: Palette) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        // No alpha channel: an app icon has to be opaque.
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Top-left origin, to match the numbers above.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [palette.backgroundStart.cgColor, palette.backgroundEnd.cgColor] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: .zero, end: CGPoint(x: side, y: side),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // The breakwater, as a line through points on the circle so the
    // direction it runs in does not depend on which way up the canvas is.
    let breakwater = CGMutablePath()
    let steps = 240
    for step in 0...steps {
        let angle = breakwaterStart + (breakwaterEnd - breakwaterStart) * CGFloat(step) / CGFloat(steps)
        let next = point(angle: angle, distance: breakwaterRadius)
        if step == 0 { breakwater.move(to: next) } else { breakwater.addLine(to: next) }
    }
    context.addPath(breakwater)
    context.setStrokeColor(palette.breakwater.cgColor)
    context.setLineWidth(breakwaterWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    // The app, sheltered in the middle.
    let app = CGRect(
        x: centre.x - appSide / 2, y: centre.y - appSide / 2, width: appSide, height: appSide)
    context.addPath(CGPath(
        roundedRect: app, cornerWidth: appCornerRadius, cornerHeight: appCornerRadius, transform: nil))
    context.setFillColor(palette.app.cgColor)
    context.fillPath()

    // The light at the entrance.
    let light = point(angle: lightAngle, distance: lightDistance)
    context.addEllipse(in: CGRect(
        x: light.x - lightRadius, y: light.y - lightRadius, width: lightRadius * 2, height: lightRadius * 2))
    context.setFillColor(palette.light.cgColor)
    context.fillPath()

    return context.makeImage()!
}

let output = URL(
    fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1] : "Host/Assets.xcassets/AppIcon.appiconset",
    isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for palette in palettes {
    let file = output.appendingPathComponent("AppIcon-\(palette.name).png")
    guard let destination = CGImageDestinationCreateWithURL(
        file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        fatalError("cannot write \(file.path)")
    }
    CGImageDestinationAddImage(destination, draw(palette), nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("cannot write \(file.path)")
    }
    print("Wrote \(file.path)")
}
