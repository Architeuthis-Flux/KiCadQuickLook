#!/usr/bin/env swift
// Exercises the modern QLThumbnailGenerator pipeline (which is what Finder
// uses) against a file and writes the result to a PNG for inspection.
// Usage: swift Scripts/test-thumbnail.swift <input-file> <output.png> [icon]
// "icon" requests icon mode, which is how Finder asks for file icons.

import AppKit
import QuickLookThumbnailing

guard CommandLine.arguments.count >= 3 else {
    print("usage: test-thumbnail.swift <input-file> <output.png> [icon]")
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let iconMode = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "icon"

let request = QLThumbnailGenerator.Request(
    fileAt: inputURL,
    size: CGSize(width: 512, height: 512),
    scale: 1.0,
    representationTypes: .thumbnail
)
request.iconMode = iconMode

QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
    if let error = error {
        print("FAILED: \(error)")
        exit(1)
    }
    guard let cgImage = thumbnail?.cgImage else {
        print("FAILED: no image")
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("FAILED: png encode")
        exit(1)
    }
    try! png.write(to: outputURL)
    print("OK: \(cgImage.width)x\(cgImage.height) -> \(outputURL.path)")
    exit(0)
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: 60))
print("FAILED: timed out")
exit(1)
