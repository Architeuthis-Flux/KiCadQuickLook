import Foundation

/// Builds the HTML for a KiCanvas render.
///
/// The page and its resources are served through `KiCanvasSchemeHandler`
/// (a private `kiql://` scheme): the KiCanvas bundle and the KiCad document
/// are separate fetchable resources rather than being inlined, which keeps
/// memory flat for multi-megabyte boards and gives the page a real origin.
/// Nothing is fetched from the network.
enum PreviewHTMLBuilder {
    enum BuilderError: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "\(name) is missing from the extension bundle"
            }
        }
    }

    /// A renderable page: HTML plus the resources it fetches.
    struct Page {
        let html: String
        /// Resources to serve over kiql://, keyed by URL path.
        let resources: [String: KiCanvasSchemeHandler.Resource]
        /// How long the host should wait for the page's render before
        /// giving up; pages whose work scales with the input (STEP
        /// tessellation) ask for more.
        var timeout: TimeInterval = 100
    }

    static func page(for content: PreviewContent, bundle: Bundle = .main, interactive: Bool = true) throws -> Page {
        switch content {
        case .document(let type, let text):
            return try documentPage(type: type, content: text, bundle: bundle, interactive: interactive)
        case .model(let format, let data):
            return try ModelPreviewHTMLBuilder.page(format: format, data: data, bundle: bundle, interactive: interactive)
        case .message(let title, let detail):
            return Page(html: messagePage(title: title, detail: detail), resources: [:])
        }
    }

    /// Loads a vendored resource (kicanvas.js, o3dv.min.js, …) from the
    /// extension bundle.
    static func resourceData(_ name: String, extension ext: String, bundle: Bundle) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url)
        else {
            throw BuilderError.missingResource("\(name).\(ext)")
        }
        return data
    }

    private static func kicanvasData(bundle: Bundle) throws -> Data {
        try resourceData("kicanvas", extension: "js", bundle: bundle)
    }

    private static func documentPage(
        type: KiCadDocumentType,
        content: String,
        bundle: Bundle,
        interactive: Bool
    ) throws -> Page {
        // The extension carries the file type, which KiCanvas uses to pick
        // its parser when loading `src` sources.
        let documentPath = type == .board ? "/document.kicad_pcb" : "/document.kicad_sch"
        let resources: [String: KiCanvasSchemeHandler.Resource] = [
            "/kicanvas.js": .init(mimeType: "text/javascript", data: try kicanvasData(bundle: bundle)),
            documentPath: .init(mimeType: "text/plain", data: Data(content.utf8)),
        ]
        let controls = interactive ? "basic" : "none"
        // Interactive previews show their own progress overlay, so they can
        // afford a generous budget for huge boards; thumbnails must stay
        // within the system's thumbnail deadline.
        let timeoutMs = interactive ? 90000 : 15000
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            html, body {
                margin: 0;
                padding: 0;
                width: 100%;
                height: 100%;
                overflow: hidden;
                background: #131218;
            }
            kicanvas-embed {
                display: block;
                width: 100%;
                height: 100%;
                aspect-ratio: auto;
            }
        </style>
        </head>
        <body>
        <kicanvas-embed src="\(documentPath)" controls="\(controls)" controlslist="nodownload nooverlay">
        </kicanvas-embed>
        <div id="kiql-overlay">
            <div class="spinner"></div>
            <div id="kiql-overlay-text">Rendering…</div>
        </div>
        <style>
            #kiql-overlay {
                position: fixed;
                inset: 0;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                gap: 14px;
                background: #131218;
                color: #a0a0b0;
                font-family: -apple-system, sans-serif;
                font-size: 13px;
                z-index: 10;
            }
            #kiql-overlay.hidden { display: none; }
            #kiql-overlay .spinner {
                width: 28px;
                height: 28px;
                border: 3px solid #333;
                border-top-color: #81a2be;
                border-radius: 50%;
                animation: kiql-spin 0.9s linear infinite;
            }
            @keyframes kiql-spin { to { transform: rotate(360deg); } }
        </style>
        <script>
        // localStorage can throw SecurityError in restricted contexts
        // (null-origin pages, some sandboxed WKWebViews). KiCanvas touches
        // it at module top level (its preferences store), which would kill
        // the entire module; shim it in memory to be safe.
        (() => {
            const store = new Map();
            const shim = {
                getItem: (k) => store.has(String(k)) ? store.get(String(k)) : null,
                setItem: (k, v) => store.set(String(k), String(v)),
                removeItem: (k) => store.delete(String(k)),
                clear: () => store.clear(),
                key: (i) => Array.from(store.keys())[i] ?? null,
                get length() { return store.size; },
            };
            try { Object.defineProperty(window, "localStorage", { value: shim, configurable: true }); } catch (e) {}
            try { Object.defineProperty(window, "sessionStorage", { value: shim, configurable: true }); } catch (e) {}
            // Seed KiCanvas's "align controls with KiCad" preference (read
            // from storage at module load): plain scroll zooms, Ctrl+scroll
            // pans horizontally, Shift+scroll pans vertically — matching
            // KiCad itself instead of the web-style pan-by-default.
            try {
                window.localStorage.setItem("kc:prefs:alignControlsWithKiCad", JSON.stringify({ val: true }));
            } catch (e) {}
        })();
        // KiCanvas paint failures surface as unhandled rejections (its async
        // load chain has no catch). Record the first one so the status
        // script below can fail fast instead of waiting for the timeout.
        // Registered here, before the KiCanvas module, so nothing is missed.
        window.__kiqlRejection = null;
        window.addEventListener("unhandledrejection", (event) => {
            if (window.__kiqlRejection) return;
            let message = "unknown error";
            try {
                const reason = event.reason;
                message = String(reason && (reason.message || reason)) || message;
            } catch (e) {}
            window.__kiqlRejection = { time: Date.now(), message };
        });
        // KiCanvas resolves its viewerReady/updateComplete promises inside
        // requestAnimationFrame callbacks. In a WKWebView that is not
        // visible/composited (offscreen thumbnail rendering), rAF never
        // fires and loading hangs forever. Guarantee each callback runs by
        // racing rAF against a short timeout. KiCanvas never calls
        // cancelAnimationFrame, so the fallback cannot cancel real work.
        (() => {
            const nativeRAF = window.requestAnimationFrame.bind(window);
            window.requestAnimationFrame = (callback) => {
                let fired = false;
                const runOnce = (time) => {
                    if (fired) return;
                    fired = true;
                    callback(time);
                };
                const id = nativeRAF(runOnce);
                setTimeout(() => runOnce(performance.now()), 100);
                return id;
            };
        })();
        </script>
        <script type="module" src="/kicanvas.js"></script>
        <script type="module">
        // Report render progress to Swift: "ready" as soon as the page (and
        // its progress overlay) has painted, then "loaded" / "error" /
        // "timeout" when KiCanvas finishes. The preview completes Quick Look
        // at "ready" so huge boards show progress instead of a stuck
        // system spinner; thumbnails wait for the final state.
        const post = (status) => {
            try { window.webkit?.messageHandlers?.renderState?.postMessage(status); } catch (e) {}
        };
        const overlay = document.getElementById("kiql-overlay");
        const overlayText = document.getElementById("kiql-overlay-text");
        const showOverlayError = (message) => {
            overlay.querySelector(".spinner")?.remove();
            overlayText.textContent = message;
        };
        const embed = document.querySelector("kicanvas-embed");
        const started = Date.now();
        requestAnimationFrame(() => requestAnimationFrame(() => post("ready")));

        // Boards default to zoom-to-page, which leaves small boards as a
        // speck on a large worksheet. Zoom to the union of all drawn layer
        // content instead (Edge.Cuts alone can be empty on outline-less
        // boards, so a plain zoom_to_board() is not enough).
        const findViewer = () => {
            const app = embed.shadowRoot?.querySelector("kc-board-app, kc-schematic-app");
            const viewerElement = app?.shadowRoot?.querySelector("kc-board-viewer, kc-schematic-viewer");
            return viewerElement?.viewer;
        };

        // KiCad-style wheel handling, intercepted before KiCanvas's own
        // handler (whose cursor-anchored zoom is broken upstream: it
        // computes the anchor correction after the zoom is applied, so it
        // always zooms on the view center). Plain scroll zooms centered on
        // the cursor; Ctrl+scroll pans horizontally; Shift+scroll pans
        // vertically — matching KiCad itself.
        window.addEventListener("wheel", (event) => {
            try {
                const viewer = findViewer();
                const camera = viewer?.viewport?.camera;
                const canvas = viewer?.renderer?.canvas;
                if (!camera || !canvas || !viewer?.loaded?.isOpen) return;
                event.preventDefault();
                event.stopImmediatePropagation();

                let dx = event.deltaX, dy = event.deltaY;
                if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) { dx *= 8; dy *= 8; }
                else if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) { dx *= 24; dy *= 24; }
                dx = Math.sign(dx) * Math.min(24, Math.abs(dx));
                dy = Math.sign(dy) * Math.min(24, Math.abs(dy));

                const Vec = camera.viewport_size.constructor;
                if (event.ctrlKey || event.shiftKey) {
                    let px = dx, py = dy;
                    if (px === 0 && event.ctrlKey) { px = py; py = 0; }
                    camera.translate(new Vec(px / camera.zoom, py / camera.zoom));
                } else {
                    const rect = canvas.getBoundingClientRect();
                    const mouse = new Vec(event.clientX - rect.left, event.clientY - rect.top);
                    const before = camera.screen_to_world(mouse);
                    camera.zoom = Math.min(190, Math.max(0.5, camera.zoom * Math.exp(dy * -0.005)));
                    const after = camera.screen_to_world(mouse);
                    camera.translate(before.sub(after));
                }
                viewer.draw();
                // Keeps KiCanvas UI (position readout) in sync.
                canvas.dispatchEvent(new MouseEvent("panzoom", {
                    clientX: event.clientX,
                    clientY: event.clientY,
                }));
            } catch (e) {}
        }, { capture: true, passive: false });

        const zoomToContent = (viewer) => {
            try {
                if (!viewer?.layers) return;

                // Prefer the board outline (Edge.Cuts): it frames the
                // physical board, ignoring off-board graphics and text.
                let target = null;
                let usedEdgeCuts = false;
                try {
                    const edge = viewer.layers.by_name("Edge.Cuts")?.bbox;
                    if (edge && edge.w > 0 && edge.h > 0) {
                        target = edge;
                        usedEdgeCuts = true;
                    }
                } catch (e) {}

                if (!target) {
                    // Fall back to the union of all drawn layer content
                    // (skipping colon-prefixed virtual layers such as
                    // ":DrawingSheet", which spans the entire page).
                    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
                    let sample = null;
                    for (const layer of viewer.layers.in_display_order()) {
                        if (layer.name.startsWith(":")) continue;
                        const b = layer.bbox;
                        if (!b || !(b.w > 0) || !(b.h > 0)) continue;
                        sample = b;
                        x0 = Math.min(x0, b.x);
                        y0 = Math.min(y0, b.y);
                        x1 = Math.max(x1, b.x + b.w);
                        y1 = Math.max(y1, b.y + b.h);
                    }
                    if (!sample) return;
                    target = new sample.constructor(x0, y0, x1 - x0, y1 - y0);
                }

                const margin = usedEdgeCuts ? 0.02 : 0.05;
                const grown = target.grow(Math.max(target.w, target.h) * margin);
                viewer.viewport.camera.bbox = grown;
                viewer.draw();

                // The camera expands the requested box to the canvas aspect
                // ratio; record what fraction the content occupies so
                // thumbnails can crop the snapshot to the board shape.
                const cam = viewer.viewport.camera.bbox;
                if (cam?.w > 0 && cam?.h > 0) {
                    window.__kiqlCrop = {
                        fw: Math.min(1, grown.w / cam.w),
                        fh: Math.min(1, grown.h / cam.h),
                        edgeCuts: usedEdgeCuts,
                    };
                }
            } catch (e) {}
        };

        // KiCanvas finishes loading inside `await viewport.ready`, a barrier
        // opened by a ResizeObserver callback. WebKit delivers those only
        // during rendering updates, which are suspended for occluded or
        // slow-to-load pages — boards that take more than a few seconds to
        // paint deadlock there. Replicate what the observer would do:
        // un-hide the app, force layout, and open the barrier by hand.
        let viewerFirstSeen = 0;
        const unstickViewport = (viewer) => {
            try {
                const vp = viewer.viewport;
                if (!vp || vp.ready?.isOpen) return;
                const app = embed.shadowRoot?.querySelector("kc-board-app, kc-schematic-app");
                if (app?.hidden) app.hidden = false;
                const canvas = viewer.renderer?.canvas;
                const w = canvas?.clientWidth || document.documentElement.clientWidth || 800;
                const h = canvas?.clientHeight || document.documentElement.clientHeight || 600;
                if (!(w > 0 && h > 0)) return;
                vp.width = w;
                vp.height = h;
                const Vec = vp.camera.viewport_size.constructor;
                vp.camera.viewport_size = new Vec(w, h);
                vp.ready.open();
            } catch (e) {}
        };

        const poll = () => {
            // The viewer's `loaded` barrier opens only after the document is
            // parsed, painted, and the default zoom-to-page has been applied
            // — so it is safe to re-zoom and snapshot after that.
            const viewer = findViewer();
            if (viewer?.loaded?.isOpen) {
                zoomToContent(viewer);
                overlay.classList.add("hidden");
                requestAnimationFrame(() => requestAnimationFrame(() => post("loaded")));
                return;
            }
            if (viewer) {
                if (!viewerFirstSeen) viewerFirstSeen = Date.now();
                if (Date.now() - viewerFirstSeen > 500) unstickViewport(viewer);
            }
            if (window.__kiqlRejection && Date.now() - window.__kiqlRejection.time > 2000) {
                // A paint/load rejection with no recovery within 2s means
                // the viewer is wedged; fail fast rather than timing out.
                showOverlayError("KiCanvas could not render this file: " + window.__kiqlRejection.message);
                post("error: " + window.__kiqlRejection.message);
            } else if (Date.now() - started > \(timeoutMs)) {
                showOverlayError("Rendering timed out — this file may be too complex for the previewer.");
                post("timeout");
            } else {
                setTimeout(poll, 50);
            }
        };
        poll();
        window.addEventListener("error", (e) => post("error: " + e.message));
        </script>
        </body>
        </html>
        """
        return Page(html: html, resources: resources)
    }

    static func messagePage(title: String, detail: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            html, body {
                margin: 0;
                height: 100%;
                display: flex;
                align-items: center;
                justify-content: center;
                background: #131218;
                color: #f8f8f0;
                font-family: -apple-system, sans-serif;
                text-align: center;
            }
            main { padding: 2em; }
            h1 { font-size: 1.2em; }
            p { color: #a0a0b0; font-size: 0.9em; }
        </style>
        </head>
        <body>
        <main>
            <h1>\(escapeForHTML(title))</h1>
            <p>\(escapeForHTML(detail))</p>
        </main>
        <script>
        try { window.webkit?.messageHandlers?.renderState?.postMessage("loaded"); } catch (e) {}
        </script>
        </body>
        </html>
        """
    }

    static func escapeForHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
