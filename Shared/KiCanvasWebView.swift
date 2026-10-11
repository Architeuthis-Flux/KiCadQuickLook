import Foundation
import os.log
import WebKit

private let eventLogger = Logger(subsystem: "com.kevincappuccio.KiCadQuickLook", category: "events")

/// A WKWebView wired up to load a self-contained KiCanvas page and report
/// when the render has actually painted (via the `renderState` script
/// message posted from the page).
final class KiCanvasWebView: WKWebView {
    enum RenderError: LocalizedError {
        case timedOut
        case pageError(String)
        case navigationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .timedOut: return "KiCanvas timed out while rendering"
            case .pageError(let message): return "KiCanvas failed: \(message)"
            case .navigationFailed(let error): return error.localizedDescription
            }
        }
    }

    private final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private var onReady: (() -> Void)?
        private var onRendered: ((Result<Void, RenderError>) -> Void)?
        private(set) var generation = 0
        /// Cache key the current page may store geometry under.
        var meshCacheKey: String?
        /// Base64 chunks of the geometry blob, in arrival order.
        private var meshChunks: [Int: String] = [:]

        /// Arms the coordinator for a new load; any pending completion from
        /// a previous load is dropped. Returns the new load's generation,
        /// used so stale watchdogs cannot fail a later load.
        @discardableResult
        func begin(
            onReady: (() -> Void)?,
            onRendered: @escaping (Result<Void, RenderError>) -> Void
        ) -> Int {
            generation += 1
            self.onReady = onReady
            self.onRendered = onRendered
            return generation
        }

        func ready() {
            guard let handler = onReady else { return }
            onReady = nil
            handler()
        }

        func finish(_ result: Result<Void, RenderError>, generation: Int? = nil) {
            if let generation = generation, generation != self.generation { return }
            guard let handler = onRendered else { return }
            onRendered = nil
            handler(result)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "modelCache" {
                receiveMeshChunk(message.body)
                return
            }
            guard message.name == "renderState" else { return }
            let status = message.body as? String ?? "unknown"
            if status == "ready" {
                ready()
            } else if status == "loaded" {
                finish(.success(()))
            } else if status == "timeout" {
                finish(.failure(.timedOut))
            } else {
                finish(.failure(.pageError(status)))
            }
        }

        /// Reassembles the geometry blob the model page sends after
        /// tessellating, and stores it once every chunk has arrived. Only
        /// the key the page was built with is accepted.
        private func receiveMeshChunk(_ body: Any) {
            guard let expectedKey = meshCacheKey,
                  let chunk = body as? [String: Any],
                  let key = chunk["key"] as? String, key == expectedKey,
                  let index = chunk["index"] as? Int,
                  let total = chunk["total"] as? Int,
                  let data = chunk["data"] as? String,
                  index >= 0, index < total
            else { return }
            meshChunks[index] = data
            guard meshChunks.count == total else { return }
            let chunks = meshChunks
            meshChunks = [:]
            DispatchQueue.global(qos: .utility).async {
                var combined = ""
                combined.reserveCapacity(chunks.values.reduce(0) { $0 + $1.utf8.count })
                for position in 0..<total {
                    guard let piece = chunks[position] else { return }
                    combined += piece
                }
                guard let blob = Data(base64Encoded: combined) else { return }
                MeshCache.shared.store(key: key, data: blob)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(.navigationFailed(error)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(.failure(.navigationFailed(error)))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failure(.pageError("web content process terminated")))
        }
    }

    private let coordinator = Coordinator()
    private let schemeHandler = KiCanvasSchemeHandler()
    private var keepAlive: Timer?

    init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "renderState")
        configuration.userContentController.add(coordinator, name: "modelCache")
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: KiCanvasSchemeHandler.scheme)
        // WebKit suspends scheduling for web views it considers inactive
        // (offscreen windows, occluded previews). Big boards paint for tens
        // of seconds without producing frames, get suspended mid-render,
        // and never finish — timers stop and the page wedges forever.
        if #available(macOS 14.0, *) {
            configuration.preferences.inactiveSchedulingPolicy = .none
        }
        super.init(frame: frame, configuration: configuration)
        navigationDelegate = coordinator
        setValue(false, forKey: "drawsBackground")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Mouse event tracing

    // Hosts differ in which mouse events they forward to a remotely hosted
    // preview (the Quick Look panel forwards drags; Finder's preview pane
    // only once the preview claims them, see PreviewViewController). Trace
    // what arrives, at debug level, so the behaviour can be observed with
    // `log stream --level debug --predicate 'subsystem == "com.kevincappuccio.KiCadQuickLook"'`.

    private func trace(_ event: NSEvent, _ name: StaticString) {
        eventLogger.debug("\(name, privacy: .public) at \(event.locationInWindow.x, privacy: .public),\(event.locationInWindow.y, privacy: .public)")
    }

    override func mouseDown(with event: NSEvent) {
        trace(event, "mouseDown")
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        trace(event, "mouseDragged")
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        trace(event, "mouseUp")
        super.mouseUp(with: event)
    }

    /// Loads the page and reports progress on the main thread.
    ///
    /// `onReady` fires once the page (with its progress overlay) has
    /// painted — enough for a live preview to be shown. `completion` fires
    /// when KiCanvas finishes rendering (or fails). The page carries its
    /// own render timeout, but a wedged WebContent process (seen with very
    /// large boards) can block the page's event loop entirely, so a native
    /// watchdog guarantees `completion` always fires.
    func render(
        page: PreviewHTMLBuilder.Page,
        timeout: TimeInterval = 100,
        onReady: (() -> Void)? = nil,
        completion: @escaping (Result<Void, RenderError>) -> Void
    ) {
        let generation = coordinator.begin(
            onReady: onReady.map { handler in
                { DispatchQueue.main.async { handler() } }
            },
            onRendered: { [weak self] result in
                DispatchQueue.main.async {
                    self?.stopKeepAlive()
                    completion(result)
                }
            }
        )
        let coordinator = self.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            coordinator.finish(.failure(.timedOut), generation: generation)
        }
        startKeepAlive()
        coordinator.meshCacheKey = page.meshCacheKey
        for (path, resource) in page.resources {
            schemeHandler.setResource(path: path, mimeType: resource.mimeType, data: resource.data)
        }
        schemeHandler.setResource(
            path: KiCanvasSchemeHandler.entryURL.path,
            mimeType: "text/html",
            data: Data(page.html.utf8)
        )
        load(URLRequest(url: KiCanvasSchemeHandler.entryURL))
    }

    /// Convenience for plain message pages with no extra resources.
    func render(
        html: String,
        timeout: TimeInterval = 35,
        completion: @escaping (Result<Void, RenderError>) -> Void
    ) {
        render(
            page: PreviewHTMLBuilder.Page(html: html, resources: [:]),
            timeout: timeout,
            completion: completion
        )
    }

    /// Pokes the page while a render is in flight.
    ///
    /// Model pages hand the CAD work to a Web Worker and leave the page's
    /// main thread idle. In an offscreen web view (thumbnails) that idle
    /// page is throttled regardless of `inactiveSchedulingPolicy`: worker
    /// messages and timers stop being delivered and loads that take two
    /// seconds in a foreground page run into the deadline. A periodic
    /// script evaluation from the host keeps the content process serviced;
    /// without it, half the STEP renders in the offscreen harness stalled.
    private func startKeepAlive() {
        stopKeepAlive()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.evaluateJavaScript("0", completionHandler: nil)
        }
    }

    private func stopKeepAlive() {
        keepAlive?.invalidate()
        keepAlive = nil
    }

    func tearDown() {
        stopKeepAlive()
        configuration.userContentController.removeScriptMessageHandler(forName: "renderState")
        configuration.userContentController.removeScriptMessageHandler(forName: "modelCache")
        navigationDelegate = nil
    }
}
