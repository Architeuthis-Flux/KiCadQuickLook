import AppKit
import os.log
import QuickLookThumbnailing
import WebKit

private let logger = Logger(subsystem: "com.kevincappuccio.KiCadQuickLook", category: "thumbnail")

/// Renders Finder icon thumbnails by snapshotting an offscreen KiCanvas
/// WKWebView. Thumbnail extensions have tight time and memory budgets, so a
/// hard deadline guards against KiCanvas hanging; on any failure we fall
/// back to a simple drawn placeholder rather than no icon at all.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    private static let renderDeadline: TimeInterval = 18

    /// The fraction of the snapshot occupied by the framed content (as
    /// reported by the page), used to crop board thumbnails to the board
    /// outline instead of a letterboxed square.
    private struct ContentCrop {
        let fractionWidth: Double
        let fractionHeight: Double
        let followsEdgeCuts: Bool
    }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileURL = request.fileURL
        let maximumSize = request.maximumSize
        let scale = request.scale

        DispatchQueue.main.async {
            self.renderSnapshot(fileURL: fileURL, size: maximumSize, scale: scale) { image, crop in
                guard let image = image,
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else {
                    handler(QLThumbnailReply(contextSize: maximumSize, drawing: { context -> Bool in
                        Self.drawPlaceholder(in: context, size: maximumSize, for: fileURL)
                        return true
                    }), nil)
                    return
                }

                // Boards with an Edge.Cuts outline get cropped to the board
                // shape; everything else keeps the full square snapshot.
                let (finalImage, contextSize): (CGImage, CGSize)
                if let crop = crop, crop.followsEdgeCuts,
                   let cropped = Self.cropToContent(cgImage, crop: crop) {
                    finalImage = cropped
                    contextSize = Self.fittedSize(
                        aspect: Double(cropped.width) / Double(cropped.height),
                        within: maximumSize
                    )
                } else {
                    finalImage = cgImage
                    contextSize = maximumSize
                }

                handler(QLThumbnailReply(contextSize: contextSize, drawing: { context -> Bool in
                    context.draw(
                        finalImage,
                        in: CGRect(origin: .zero, size: contextSize),
                        byTiling: false
                    )
                    return true
                }), nil)
            }
        }
    }

    /// Crops the centered content region out of the square snapshot. The
    /// camera centers the framed bbox and expands it to the canvas aspect,
    /// so the content is the centered sub-rect given by the fractions.
    private static func cropToContent(_ image: CGImage, crop: ContentCrop) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        let cropWidth = (width * crop.fractionWidth).rounded()
        let cropHeight = (height * crop.fractionHeight).rounded()
        guard cropWidth >= 8, cropHeight >= 8 else { return nil }
        let rect = CGRect(
            x: ((width - cropWidth) / 2).rounded(.down),
            y: ((height - cropHeight) / 2).rounded(.down),
            width: cropWidth,
            height: cropHeight
        )
        return image.cropping(to: rect)
    }

    private static func fittedSize(aspect: Double, within maximum: CGSize) -> CGSize {
        guard aspect.isFinite, aspect > 0 else { return maximum }
        if aspect >= maximum.width / maximum.height {
            return CGSize(width: maximum.width, height: maximum.width / aspect)
        }
        return CGSize(width: maximum.height * aspect, height: maximum.height)
    }

    // MARK: - WKWebView snapshot

    private func renderSnapshot(
        fileURL: URL,
        size: CGSize,
        scale: CGFloat,
        completion: @escaping (NSImage?, ContentCrop?) -> Void
    ) {
        // Unlike the preview extension, the thumbnail extension's sandbox
        // denies reads of sibling files even with the temporary-exception
        // entitlement, so .kicad_pro files (whose content lives in the
        // sibling .kicad_pcb/.kicad_sch) always get the drawn placeholder.
        guard fileURL.pathExtension.lowercased() != "kicad_pro" else {
            completion(nil, nil)
            return
        }
        let content: PreviewContent
        do {
            content = try KiCadFileLoader.loadPreviewContent(for: fileURL)
        } catch {
            logger.error("thumbnail load failed for \(fileURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            completion(nil, nil)
            return
        }
        guard case .document = content,
              let page = try? PreviewHTMLBuilder.page(
                  for: content,
                  bundle: Bundle(for: Self.self),
                  interactive: false
              )
        else {
            logger.info("thumbnail fallback (non-document content) for \(fileURL.lastPathComponent, privacy: .public)")
            completion(nil, nil)
            return
        }
        logger.info("thumbnail rendering \(fileURL.lastPathComponent, privacy: .public)")

        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let webView = KiCanvasWebView(frame: CGRect(origin: .zero, size: pixelSize))

        // Offscreen WKWebViews only paint when parented to a window.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: pixelSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView

        var completed = false
        let finish: (NSImage?, ContentCrop?) -> Void = { image, crop in
            guard !completed else { return }
            completed = true
            webView.tearDown()
            window.contentView = nil
            completion(image, crop)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.renderDeadline) {
            finish(nil, nil)
        }

        // In-page timeout is 15 s for non-interactive pages; give the native
        // watchdog a little headroom past that.
        webView.render(page: page, timeout: 17) { result in
            guard case .success = result else {
                if case .failure(let error) = result {
                    logger.error("thumbnail render failed for \(fileURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                finish(nil, nil)
                return
            }
            // The page records how much of the canvas the framed content
            // occupies (and whether it framed the Edge.Cuts outline).
            webView.evaluateJavaScript("JSON.stringify(window.__kiqlCrop || null)") { cropJSON, cropError in
                logger.info("thumbnail crop info: \(String(describing: cropJSON), privacy: .public) err: \(String(describing: cropError), privacy: .public)")
                var crop: ContentCrop?
                if let json = cropJSON as? String,
                   let data = json.data(using: .utf8),
                   let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let fw = dict["fw"] as? Double,
                   let fh = dict["fh"] as? Double {
                    crop = ContentCrop(
                        fractionWidth: fw,
                        fractionHeight: fh,
                        followsEdgeCuts: dict["edgeCuts"] as? Bool ?? false
                    )
                }
                let snapshotConfiguration = WKSnapshotConfiguration()
                snapshotConfiguration.rect = CGRect(origin: .zero, size: pixelSize)
                webView.takeSnapshot(with: snapshotConfiguration) { image, _ in
                    finish(image, crop)
                }
            }
        }
    }

    // MARK: - Fallback placeholder

    private static func drawPlaceholder(in context: CGContext, size: CGSize, for url: URL) {
        let colors: (background: CGColor, accent: CGColor)
        switch url.pathExtension.lowercased() {
        case "kicad_pcb":
            colors = (
                CGColor(red: 0.05, green: 0.25, blue: 0.12, alpha: 1),
                CGColor(red: 0.75, green: 0.65, blue: 0.25, alpha: 1)
            )
        case "kicad_sch":
            colors = (
                CGColor(red: 0.96, green: 0.95, blue: 0.89, alpha: 1),
                CGColor(red: 0.55, green: 0.15, blue: 0.15, alpha: 1)
            )
        default:
            colors = (
                CGColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1),
                CGColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 1)
            )
        }

        context.setFillColor(colors.background)
        context.fill(CGRect(origin: .zero, size: size))

        // Simple circuit-trace motif.
        let inset = size.width * 0.2
        context.setStrokeColor(colors.accent)
        context.setLineWidth(max(1, size.width * 0.04))
        context.setLineCap(.round)
        context.move(to: CGPoint(x: inset, y: size.height * 0.3))
        context.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.3))
        context.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.55))
        context.addLine(to: CGPoint(x: size.width - inset, y: size.height * 0.55))
        context.strokePath()

        let padRadius = max(2, size.width * 0.06)
        for point in [
            CGPoint(x: inset, y: size.height * 0.3),
            CGPoint(x: size.width - inset, y: size.height * 0.55),
            CGPoint(x: size.width * 0.35, y: size.height * 0.72),
        ] {
            context.setFillColor(colors.accent)
            context.fillEllipse(in: CGRect(
                x: point.x - padRadius,
                y: point.y - padRadius,
                width: padRadius * 2,
                height: padRadius * 2
            ))
        }
    }
}
