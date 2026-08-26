// Renders a KiCad file through the exact same Shared/ pipeline the Quick
// Look extensions use, in an offscreen WKWebView, and snapshots to PNG.
//
// Build & run (from the repo root):
//   swiftc -o /tmp/kiql-test-render Shared/*.swift Scripts/test-render.swift \
//     -framework WebKit -framework AppKit
//   /tmp/kiql-test-render <input-file> <output.png>
//
// The kicanvas.js resource is located via the KICANVAS_JS environment
// variable or defaults to Vendor/kicanvas/kicanvas.js in the current dir.

import AppKit
import WebKit

guard CommandLine.arguments.count >= 3 else {
    print("usage: test-render <input-file> <output.png> [interactive]")
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
// "interactive" exercises the preview path (90 s in-page budget);
// default exercises the thumbnail path (15 s in-page budget).
let interactive = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "interactive"

// PreviewHTMLBuilder looks kicanvas.js up in a bundle; point a Bundle at the
// vendor directory.
let vendorPath = ProcessInfo.processInfo.environment["KICANVAS_DIR"]
    ?? FileManager.default.currentDirectoryPath + "/Vendor/kicanvas"
guard let vendorBundle = Bundle(path: vendorPath) else {
    print("FAILED: no bundle at \(vendorPath)")
    exit(1)
}

let content: PreviewContent
do {
    content = try KiCadFileLoader.loadPreviewContent(for: inputURL)
} catch {
    print("FAILED loading: \(error)")
    exit(1)
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
let webView = KiCanvasWebView(frame: CGRect(origin: .zero, size: size))
window.contentView = webView

let start = Date()
webView.render(page: page, timeout: 120) { result in
    switch result {
    case .failure(let error):
        print("FAILED render after \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(error)")
        exit(1)
    case .success:
        print("loaded in \(String(format: "%.1f", Date().timeIntervalSince(start)))s; snapshotting…")
        webView.takeSnapshot(with: nil) { image, error in
            guard let image = image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                print("FAILED snapshot: \(String(describing: error))")
                exit(1)
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            try! rep.representation(using: .png, properties: [:])!.write(to: outputURL)
            print("OK -> \(outputURL.path)")
            exit(0)
        }
    }
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: 125))
print("FAILED: harness timed out")
exit(1)
