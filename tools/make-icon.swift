// Generates the app icon. Run from the repo root:
//
//     swift tools/make-icon.swift
//
// It writes straight into the asset catalogue, so the icon is reproducible —
// change a number here rather than editing a PNG nobody can diff.
//
// The design is the parent Week grid: seven columns for the week, three rows for
// three children, filled where a day is done. Cells are deliberately large and
// few: at 40pt the whole icon is about 120px, so each cell has only a handful of
// pixels to work with and anything finer turns to mush.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let columns = 7
let rows = 3

/// Which cells are filled. Fuller on the left, thinning to the right, so it
/// reads as a week partly done rather than as noise.
let pattern: [[Bool]] = [
    [true,  true,  true,  true,  false, false, false],
    [true,  true,  true,  false, false, false, false],
    [true,  true,  true,  true,  true,  false, false],
]

let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("could not create the bitmap context") }

// Background: a blue that matches the app's accent, deepening towards the
// bottom-right so the tile has some weight to it.
let top = CGColor(colorSpace: space, components: [0.36, 0.60, 0.98, 1.0])!
let bottom = CGColor(colorSpace: space, components: [0.09, 0.28, 0.78, 1.0])!
guard let gradient = CGGradient(colorsSpace: space,
                                colors: [top, bottom] as CFArray,
                                locations: [0.0, 1.0])
else { fatalError("could not create the gradient") }
context.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: side),
                           end: CGPoint(x: side, y: 0),
                           options: [])

// Layout. Seven columns of three is a wide, short block that would sit in a
// square tile as a stripe, so the weekday header from the real Week view earns
// its place twice over: it is what the screen actually looks like, and it gives
// the composition some height. Cells are a little taller than wide for the same
// reason.
let margin: CGFloat = 120
let gap: CGFloat = 26
let headerGap: CGFloat = 44
let available = CGFloat(side) - margin * 2
let cellWidth = (available - gap * CGFloat(columns - 1)) / CGFloat(columns)
let cellHeight = cellWidth * 1.25
let headerHeight = cellWidth * 0.28

let gridHeight = cellHeight * CGFloat(rows) + gap * CGFloat(rows - 1)
let totalHeight = headerHeight + headerGap + gridHeight
let topY = (CGFloat(side) + totalHeight) / 2   // CoreGraphics counts y upwards
let corner = cellWidth * 0.26

let done = CGColor(colorSpace: space, components: [1.0, 1.0, 1.0, 1.0])!
let todo = CGColor(colorSpace: space, components: [1.0, 1.0, 1.0, 0.24])!
let header = CGColor(colorSpace: space, components: [1.0, 1.0, 1.0, 0.55])!

func fill(_ rect: CGRect, radius: CGFloat, color: CGColor) {
    context.setFillColor(color)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
    context.fillPath()
}

// Weekday header: seven stubs standing in for the initials, which would be
// illegible at icon sizes anyway.
for column in 0..<columns {
    let x = margin + CGFloat(column) * (cellWidth + gap)
    fill(CGRect(x: x, y: topY - headerHeight, width: cellWidth, height: headerHeight),
         radius: headerHeight / 2, color: header)
}

let gridTop = topY - headerHeight - headerGap
for row in 0..<rows {
    for column in 0..<columns {
        // Row 0 of the pattern should read as the top row.
        let y = gridTop - cellHeight - CGFloat(row) * (cellHeight + gap)
        let x = margin + CGFloat(column) * (cellWidth + gap)
        let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
        fill(rect, radius: corner, color: pattern[row][column] ? done : todo)
    }
}

guard let image = context.makeImage() else { fatalError("could not render") }

let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("App/Chores/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
guard let output = CGImageDestinationCreateWithURL(
    destination as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not open \(destination.path) for writing") }
CGImageDestinationAddImage(output, image, nil)
guard CGImageDestinationFinalize(output) else { fatalError("could not write the PNG") }

print("wrote \(destination.path)")
