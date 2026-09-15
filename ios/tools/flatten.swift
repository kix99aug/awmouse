// Redraws a PNG onto an opaque context and writes it back out.
//
// App Store Connect rejects app icons that carry an alpha channel, and every
// SVG rasteriser on hand emits one whether or not anything is transparent.
// The icon's background rect covers the whole canvas, so this discards an
// unused channel and nothing else.
//
// usage: swift flatten.swift <in.png> <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let inURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let outURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL

let source = CGImageSourceCreateWithURL(inURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!

let context = CGContext(
    data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

let destination = CGImageDestinationCreateWithURL(outURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
