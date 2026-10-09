// Renders a KiCad, STEP, or 3MF file through the exact same Shared/
// pipeline the Quick Look extensions use, in an offscreen WKWebView, and
// snapshots to PNG.
//
// Build & run (from the repo root). swiftc only allows top-level code in
// a file named main.swift when compiling several files, so copy this
// script under that name first:
//   mkdir -p /tmp/kiql-harness && cp Scripts/test-render.swift /tmp/kiql-harness/main.swift
//   swiftc -o /tmp/kiql-test-render Shared/*.swift /tmp/kiql-harness/main.swift \
//     -framework WebKit -framework AppKit
//   /tmp/kiql-test-render <input-file> <output.png> [interactive]
//
// Environment: KIQL_PHASES=1 prints the page's progress phases with
// timestamps; KIQL_TIMEOUT=<seconds> overrides the native watchdog
// (default 120); KIQL_VENDOR_DIR points at a Vendor/ directory.
//
// The vendored resources (kicanvas.js, o3dv.min.js, occt-import-js.*) are
// collected from every directory under Vendor/ in the current directory
// (override with KIQL_VENDOR_DIR) into a temporary resource bundle.

import AppKit
import WebKit

guard CommandLine.arguments.count >= 3 else {
    print("usage: test-render <input-file> <output.png> [interactive]")
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
// "interactive" exercises the preview path (90 s in-page budget, full
// model size cap); default exercises the thumbnail path (15 s in-page
// budget, thumbnail size cap).
let interactive = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "interactive"
// Native watchdog, seconds (KIQL_TIMEOUT); the in-page budget still applies.
let harnessTimeout = TimeInterval(ProcessInfo.processInfo.environment["KIQL_TIMEOUT"] ?? "") ?? 120

// PreviewHTMLBuilder looks resources up in a bundle; stage symlinks to
// every vendored file in one directory and point a Bundle at it.
let vendorRoot = ProcessInfo.processInfo.environment["KIQL_VENDOR_DIR"]
    ?? FileManager.default.currentDirectoryPath + "/Vendor"
let staging = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("kiql-test-resources-\(getpid())")
do {
    let fm = FileManager.default
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    for directory in try fm.contentsOfDirectory(atPath: vendorRoot) {
        let directoryURL = URL(fileURLWithPath: vendorRoot).appendingPathComponent(directory)
        guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        for file in try fm.contentsOfDirectory(atPath: directoryURL.path)
        where ["js", "wasm"].contains((file as NSString).pathExtension) {
            try fm.createSymbolicLink(
                at: staging.appendingPathComponent(file),
                withDestinationURL: directoryURL.appendingPathComponent(file)
            )
        }
    }
} catch {
    print("FAILED staging resources from \(vendorRoot): \(error)")
    exit(1)
}
guard let vendorBundle = Bundle(path: staging.path) else {
    print("FAILED: no bundle at \(staging.path)")
    exit(1)
}

let content: PreviewContent
do {
    content = try KiCadFileLoader.loadPreviewContent(for: inputURL, thumbnail: !interactive)
} catch {
    print("FAILED loading: \(error)")
    exit(1)
}
switch content {
case .document(let type, let text):
    print("content: \(type) document, \(text.utf8.count) bytes")
case .model(let format, let data):
    print("content: \(format.displayName) model, \(data.count) bytes")
case .message(let title, let detail):
    print("content: message — \(title): \(detail)")
}

let page: PreviewHTMLBuilder.Page
do {
    page = try PreviewHTMLBuilder.page(for: content, bundle: vendorBundle, interactive: interactive)
} catch {
    print("FAILED building page: \(error)")
    exit(1)
}

let size = CGSize(width: 800, height: 600)
let app = NSApplication.shared

let window = NSWindow(
    contentRect: CGRect(origin: .zero, size: size),
    styleMask: .borderless, backing: .buffered, defer: false
)
window.isOpaque = false
window.backgroundColor = .clear
let webView = KiCanvasWebView(frame: CGRect(origin: .zero, size: size))
window.contentView = webView

/// Fraction of fully transparent and of fully opaque pixels, to check that
/// model pages snapshot as a cut-out (transparent page background).
func alphaStatistics(_ image: CGImage) -> (transparent: Double, opaque: Double) {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return (0, 0) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var transparent = 0, opaque = 0
    for index in stride(from: 3, to: pixels.count, by: 4) {
        if pixels[index] == 0 { transparent += 1 } else if pixels[index] == 255 { opaque += 1 }
    }
    let total = Double(width * height)
    return (Double(transparent) / total, Double(opaque) / total)
}

let start = Date()

// With KIQL_PHASES=1, echo the page's progress overlay text as it changes,
// with timestamps, so slow phases (CAD kernel start-up, tessellation,
// scene building) can be told apart. Off by default: the polling itself
// keeps an offscreen page serviced, which would mask the throttling that
// KiCanvasWebView's keep-alive exists to counter.
var lastStatus = ""
if ProcessInfo.processInfo.environment["KIQL_PHASES"] == "1" {
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        webView.evaluateJavaScript("document.getElementById('kiql-overlay-text')?.textContent ?? ''") { value, _ in
            guard let status = value as? String, status != lastStatus else { return }
            lastStatus = status
            print("  [\(String(format: "%5.1f", Date().timeIntervalSince(start)))s] \(status)")
        }
    }
}

webView.render(
    page: page,
    timeout: harnessTimeout,
    onReady: {
        print("ready in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    },
    completion: { result in
        switch result {
        case .failure(let error):
            print("FAILED render after \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(error)")
            exit(1)
        case .success:
            print("loaded in \(String(format: "%.1f", Date().timeIntervalSince(start)))s; snapshotting…")
            webView.evaluateJavaScript("JSON.stringify(window.__kiqlCrop || null)") { crop, _ in
                print("crop: \(crop ?? "none")")
                webView.takeSnapshot(with: nil) { image, error in
                    guard let image = image,
                          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    else {
                        print("FAILED snapshot: \(String(describing: error))")
                        exit(1)
                    }
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try! rep.representation(using: .png, properties: [:])!.write(to: outputURL)
                    let alpha = alphaStatistics(cg)
                    print("alpha: \(Int(alpha.transparent * 100))% transparent, \(Int(alpha.opaque * 100))% opaque pixels")
                    print("OK -> \(outputURL.path)")
                    exit(0)
                }
            }
        }
    }
)

RunLoop.main.run(until: Date(timeIntervalSinceNow: harnessTimeout + 5))
print("FAILED: harness timed out")
exit(1)
