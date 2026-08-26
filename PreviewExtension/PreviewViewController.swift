import AppKit
import os.log
import Quartz
import WebKit

private let logger = Logger(subsystem: "com.kevincappuccio.KiCadQuickLook", category: "preview")

/// View-based Quick Look preview controller hosting a KiCanvas render.
///
/// View-based (rather than data-based `QLPreviewReply`) so the preview is
/// live and interactive: pan, zoom, and selection all work in the spacebar
/// window. The Quick Look completion handler is deferred until KiCanvas
/// reports that it has painted, otherwise Quick Look snapshots a blank page.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: KiCanvasWebView?

    override func loadView() {
        // Never called with a nib; provide a container so QL can size us.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        logger.info("preparing preview for \(url.lastPathComponent, privacy: .public)")
        let content: PreviewContent
        do {
            content = try KiCadFileLoader.loadPreviewContent(for: url)
        } catch {
            logger.error("load failed: \(String(describing: error), privacy: .public)")
            handler(error)
            return
        }

        let page: PreviewHTMLBuilder.Page
        do {
            page = try PreviewHTMLBuilder.page(for: content, bundle: Bundle(for: Self.self))
        } catch {
            handler(error)
            return
        }

        let webView = KiCanvasWebView(frame: view.bounds)
        webView.autoresizingMask = [.width, .height]
        view.addSubview(webView)
        self.webView = webView

        // Complete Quick Look as soon as the page (with its own progress
        // overlay) has painted: the preview is live, so KiCanvas keeps
        // rendering inside it, and huge boards show progress instead of
        // holding the system spinner for the whole render. Failures after
        // this point are displayed by the page itself.
        var completed = false
        webView.render(
            page: page,
            onReady: {
                guard !completed else { return }
                completed = true
                logger.info("preview ready for \(url.lastPathComponent, privacy: .public)")
                handler(nil)
            },
            completion: { [weak self] result in
                switch result {
                case .success:
                    logger.info("render succeeded for \(url.lastPathComponent, privacy: .public)")
                case .failure(let error):
                    logger.error("render failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                guard !completed else { return }
                completed = true
                switch result {
                case .success:
                    handler(nil)
                case .failure(let error):
                    // Never reported ready (e.g. navigation failure): show
                    // an informative page rather than the generic QL error.
                    self?.showFailurePage(for: url, error: error, handler: handler)
                }
            }
        )
    }

    private func showFailurePage(for url: URL, error: Error, handler: @escaping (Error?) -> Void) {
        guard let webView = webView else {
            handler(error)
            return
        }
        let html = PreviewHTMLBuilder.messagePage(
            title: url.lastPathComponent,
            detail: "KiCanvas could not render this file: \(error.localizedDescription)"
        )
        webView.render(html: html) { result in
            switch result {
            case .success:
                handler(nil)
            case .failure:
                handler(error)
            }
        }
    }
}
