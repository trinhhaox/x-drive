import Cocoa
import CoreGraphics

func createXDriveIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let margin = size * 0.08
    let iconRect = rect.insetBy(dx: margin, dy: margin)
    let cornerRadius = iconRect.width * 0.2237 // Apple Squircle curvature ratio

    // 1. Background Squircle with Subtle Drop Shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.03),
        blur: size * 0.08,
        color: NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.15, alpha: 0.45).cgColor
    )

    let squirclePath = CGPath(
        roundedRect: iconRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.addPath(squirclePath)
    ctx.clip()

    // 2. Deep Blue to Indigo Cosmic Gradient
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(calibratedRed: 0.06, green: 0.14, blue: 0.32, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.65, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.88, alpha: 1.0).cgColor
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.55, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
            end: CGPoint(x: iconRect.midX, y: iconRect.minY),
            options: []
        )
    }

    // 3. Inner Radial Ambient Glow
    let glowColors = [
        NSColor(calibratedRed: 0.3, green: 0.7, blue: 1.0, alpha: 0.35).cgColor,
        NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.9, alpha: 0.0).cgColor
    ] as CFArray
    if let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glowGradient,
            startCenter: CGPoint(x: iconRect.midX, y: iconRect.midY + size * 0.05),
            startRadius: 0,
            endCenter: CGPoint(x: iconRect.midX, y: iconRect.midY + size * 0.05),
            endRadius: iconRect.width * 0.55,
            options: []
        )
    }

    // 4. Subtle Border Rim Highlight
    ctx.setLineWidth(size * 0.008)
    ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.22).cgColor)
    ctx.addPath(squirclePath)
    ctx.strokePath()
    ctx.restoreGState()

    // 5. Draw Glowing Cosmic Orbit Ellipses (Clean Helumi / Orbit DNA)
    ctx.saveGState()
    ctx.setAllowsAntialiasing(true)

    // Primary Angled Orbit Ring
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.rotate(by: -CGFloat.pi / 5.5)

    let orbitWidth = size * 0.62
    let orbitHeight = size * 0.24
    let orbitRect = CGRect(x: -orbitWidth / 2, y: -orbitHeight / 2, width: orbitWidth, height: orbitHeight)

    ctx.setLineWidth(size * 0.024)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.4, green: 0.8, blue: 1.0, alpha: 0.85).cgColor)
    ctx.strokeEllipse(in: orbitRect)

    // Satellite Dot on the Orbit
    let satRadius = size * 0.038
    let satCenter = CGPoint(x: orbitRect.maxX - satRadius * 0.8, y: orbitRect.midY)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: satCenter.x - satRadius, y: satCenter.y - satRadius, width: satRadius * 2, height: satRadius * 2))

    ctx.restoreGState()

    // 6. Center Futuristic "X" Drive Core Glyph (Sharp, Clean, Apple HIG)
    ctx.saveGState()
    let xCenter = CGPoint(x: rect.midX, y: rect.midY)
    let xSpan = size * 0.26
    let xThick = size * 0.062

    ctx.translateBy(x: xCenter.x, y: xCenter.y)

    // Diagonal Leg 1 (\)
    ctx.saveGState()
    ctx.rotate(by: CGFloat.pi / 4)
    let leg1 = CGRect(x: -xThick / 2, y: -xSpan, width: xThick, height: xSpan * 2)
    let leg1Path = CGPath(roundedRect: leg1, cornerWidth: xThick / 2, cornerHeight: xThick / 2, transform: nil)
    ctx.addPath(leg1Path)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Diagonal Leg 2 (/) with Zero-Knowledge Emerald Accent
    ctx.saveGState()
    ctx.rotate(by: -CGFloat.pi / 4)
    let leg2Top = CGRect(x: -xThick / 2, y: xThick * 0.4, width: xThick, height: xSpan - xThick * 0.4)
    let leg2Bottom = CGRect(x: -xThick / 2, y: -xSpan, width: xThick, height: xSpan - xThick * 0.4)
    let leg2TopPath = CGPath(roundedRect: leg2Top, cornerWidth: xThick / 2, cornerHeight: xThick / 2, transform: nil)
    let leg2BottomPath = CGPath(roundedRect: leg2Bottom, cornerWidth: xThick / 2, cornerHeight: xThick / 2, transform: nil)

    ctx.addPath(leg2TopPath)
    ctx.addPath(leg2BottomPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.75, alpha: 0.95).cgColor) // Emerald E2EE
    ctx.fillPath()
    ctx.restoreGState()

    // Central Floating Core Node (Secure Jewel)
    let coreRadius = size * 0.05
    ctx.setFillColor(NSColor(calibratedRed: 0.05, green: 0.2, blue: 0.5, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: -coreRadius, y: -coreRadius, width: coreRadius * 2, height: coreRadius * 2))

    let jewelRadius = size * 0.03
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: -jewelRadius, y: -jewelRadius, width: jewelRadius * 2, height: jewelRadius * 2))

    ctx.restoreGState()

    img.unlockFocus()
    return img
}

let icon = createXDriveIcon(size: 1024)
let tiffData = icon.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiffData)!
let pngData = rep.representation(using: .png, properties: [:])!

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try pngData.write(to: outputURL)
print("Successfully generated master icon at \(outputURL.path)")

