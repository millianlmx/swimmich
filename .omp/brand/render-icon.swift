// Renders Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png from
// the mark's own geometry (Sources/DesignSystem/Components/ImmichMark.swift,
// ImmichMarkGeometry). The numbers below mirror those constants: if the mark is
// retuned there, mirror it here and re-run
//
//     swiftc -O .omp/brand/render-icon.swift -o /tmp/render-icon && /tmp/render-icon
//
// It writes the appiconset's file and nothing else - there is no output
// argument on purpose: an earlier run of this generator rendered to /tmp, the
// commit then shipped the previous artwork, and the icon looked stale on device
// for an hour. A generator that cannot target the wrong file cannot repeat that.
//
// The app icon is the one surface the mark cannot draw itself into: an asset
// catalog entry is a raster, and Icon Composer is a manual step.
//
// Three constraints that come from the App Store, not from taste, and that an
// earlier hand-made render got wrong: 8-bit RGB with NO alpha channel (the 1024
// is refused with one), full-bleed artwork with no tile of its own (iOS applies
// its own squircle mask, a drawn tile would nest), and a glyph on Apple's grid
// rather than edge to edge.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let side = 1024
/// The mark's diameter as a fraction of the side: 68% is the value this project
/// settled on after a 60/68/76 triptych review (60 too small, 76 too tight).
let glyphFraction: CGFloat = 0.68
/// Full-bleed near-black, top to bottom. Not a flat fill: the vertical ramp is
/// what keeps the icon from reading as a tile inside iOS 26's own platter.
let backgroundTop: (CGFloat, CGFloat, CGFloat) = (0x17 / 255, 0x18 / 255, 0x1C / 255)
let backgroundBottom: (CGFloat, CGFloat, CGFloat) = (0x05 / 255, 0x05 / 255, 0x06 / 255)

let barrelOuter: CGFloat = 1.00
let barrelInner: CGFloat = 0.84
let gap: CGFloat = 0.05
let openingBase: CGFloat = 0.48
let openingRise: CGFloat = 0.16
let openingSharpness: CGFloat = 1.6
let openingSamples = 240
let slitWidth: CGFloat = 0.06
let slitMargin: CGFloat = 0.04
let blades = 5
let petalPhase = -CGFloat.pi / 2
let valleyPhase = petalPhase + CGFloat.pi / 5

// Mirrors Color.immichLogoLight -> Color.immichLogoDeep
// (Sources/DesignSystem/Tokens/ImmichLogoColors.swift): immichPrimary in dark
// (#ACCBFA) then in light (#4250AF).
let stops: [(CGFloat, CGFloat, CGFloat)] = [(172, 203, 250), (66, 80, 175)]

// noneSkipLast, not premultipliedLast: the PNG must carry no alpha channel.
let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let backdrop = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: backgroundBottom.0, green: backgroundBottom.1,
                                           blue: backgroundBottom.2, alpha: 1),
                                   CGColor(red: backgroundTop.0, green: backgroundTop.1,
                                           blue: backgroundTop.2, alpha: 1)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(backdrop,
                       start: CGPoint(x: 0, y: 0),
                       end: CGPoint(x: 0, y: CGFloat(side)),
                       options: [])
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
// Draw in the same orientation SwiftUI does (y down), so the arcs' angles and
// the sampled points below agree with ImmichMarkShape.
ctx.translateBy(x: 0, y: CGFloat(side))
ctx.scaleBy(x: 1, y: -1)

let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
let radius = CGFloat(side) * glyphFraction / 2

func circle(_ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r),
           transform: nil)
}

let path = CGMutablePath()
path.addPath(circle(radius * barrelOuter))
path.addPath(circle(radius * barrelInner))
let plate = radius * (barrelInner - gap)
path.addPath(circle(plate))

// The opening, as the same sampled polar curve + Catmull-Rom the Shape uses.
var opening: [CGPoint] = []
for index in 0..<openingSamples {
    let theta = CGFloat(index) / CGFloat(openingSamples) * 2 * .pi
    let wave = pow(0.5 + 0.5 * cos(CGFloat(blades) * (theta - petalPhase)), openingSharpness)
    let r = radius * (openingBase + openingRise * wave)
    opening.append(CGPoint(x: centre.x + r * cos(theta), y: centre.y + r * sin(theta)))
}
path.move(to: opening[0])
for index in opening.indices {
    let p0 = opening[(index - 1 + opening.count) % opening.count]
    let p1 = opening[index]
    let p2 = opening[(index + 1) % opening.count]
    let p3 = opening[(index + 2) % opening.count]
    path.addCurve(to: p2,
                  control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                  control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
}
path.closeSubpath()

// The blades: radial wedges, closing on the rim.
let inner = radius * (openingBase + openingRise + slitMargin)
func point(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
    CGPoint(x: centre.x + r * cos(a), y: centre.y + r * sin(a))
}
func slit(from: CGFloat, to: CGFloat, at angle: CGFloat) {
    let halfWidth = radius * slitWidth / 2
    path.move(to: point(from, angle - halfWidth / from))
    path.addArc(center: centre, radius: from,
                startAngle: angle - halfWidth / from, endAngle: angle + halfWidth / from, clockwise: false)
    path.addLine(to: point(to, angle + halfWidth / to))
    path.addLine(to: point(to, angle - halfWidth / to))
    path.closeSubpath()
}
for blade in 0..<blades {
    let angle = valleyPhase + CGFloat(blade) * 2 * .pi / CGFloat(blades)
    slit(from: inner, to: plate, at: angle)
    slit(from: radius * barrelInner, to: radius * barrelOuter, at: angle)
}

ctx.saveGState()
ctx.addPath(path)
ctx.clip(using: .evenOdd)
let colors = stops.map { CGColor(red: $0.0 / 255, green: $0.1 / 255, blue: $0.2 / 255, alpha: 1) }
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: centre.x - radius, y: centre.y),
                       end: CGPoint(x: centre.x + radius, y: centre.y),
                       options: [])
ctx.restoreGState()

/// <repo>/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png, from
/// this file's own location (<repo>/.omp/brand/render-icon.swift).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let out = repoRoot
    .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    .path
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(out)") }
let written = CGImageSourceCreateWithURL(URL(fileURLWithPath: out) as CFURL, nil)
    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
let diameter = Int(CGFloat(side) * glyphFraction)
print("wrote \(out)")
print("  \(side)x\(side), glyph \(diameter)px (\(Int(glyphFraction * 100))%), "
      + "margins \((side - diameter) / 2)px, alpha \(written?.alphaInfo == .noneSkipLast ? "none" : "PRESENT")")
