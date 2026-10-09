import Foundation

/// Builds the HTML for a 3D model render (STEP, 3MF).
///
/// Rendering uses the Online 3D Viewer engine (three.js plus its 3MF
/// importer). STEP files are tessellated by Open CASCADE compiled to
/// WebAssembly (occt-import-js). Like the KiCanvas page, everything is
/// served over the private `kiql://` scheme; nothing is fetched from the
/// network, and the page reports progress through the same `renderState`
/// message protocol ("ready", "loaded", "error: …", "timeout").
enum ModelPreviewHTMLBuilder {
    static func page(
        format: ModelFormat,
        data: Data,
        bundle: Bundle,
        interactive: Bool
    ) throws -> PreviewHTMLBuilder.Page {
        // The viewer picks its importer from the URL's extension.
        let documentPath = "/model.\(format.fileExtension)"
        var resources: [String: KiCanvasSchemeHandler.Resource] = [
            "/o3dv.min.js": .init(
                mimeType: "text/javascript",
                data: try PreviewHTMLBuilder.resourceData("o3dv.min", extension: "js", bundle: bundle)
            ),
            documentPath: .init(mimeType: "application/octet-stream", data: data),
        ]
        if format == .step {
            resources["/occt-import-js.js"] = .init(
                mimeType: "text/javascript",
                data: try PreviewHTMLBuilder.resourceData("occt-import-js", extension: "js", bundle: bundle)
            )
            resources["/occt-import-js.wasm"] = .init(
                mimeType: "application/wasm",
                data: try PreviewHTMLBuilder.resourceData("occt-import-js", extension: "wasm", bundle: bundle)
            )
            resources["/occt-worker.js"] = .init(mimeType: "text/javascript", data: Data(occtWorkerScript.utf8))
        }

        // Interactive previews show their own progress overlay, so they can
        // afford a generous budget; thumbnails must stay within the
        // system's thumbnail deadline.
        let timeoutMs = interactive ? 90000 : 15000
        // Tessellation quality: deflection as a ratio of the bounding box.
        // Thumbnails are small, so a coarser mesh (faster to compute) is
        // indistinguishable.
        let linearDeflection = interactive ? 0.001 : 0.004
        let angularDeflection = interactive ? 0.5 : 0.8

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            /* The page is transparent: in the Quick Look panel the model
               floats over the panel background like the system's own 3D
               previews, and thumbnails come out as a cut-out of the
               model's shape. Text follows the host's light/dark
               appearance. */
            html, body {
                margin: 0;
                padding: 0;
                width: 100%;
                height: 100%;
                overflow: hidden;
                background: transparent;
                color-scheme: light dark;
            }
            #kiql-viewer {
                position: absolute;
                inset: 0;
            }
            #kiql-viewer canvas {
                display: block;
                outline: none;
                background: transparent;
            }
            #kiql-overlay {
                position: fixed;
                inset: 0;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                gap: 14px;
                background: transparent;
                color: #5c5c66;
                font-family: -apple-system, sans-serif;
                font-size: 13px;
                z-index: 10;
                pointer-events: none;
            }
            #kiql-overlay.hidden { display: none; }
            #kiql-overlay .spinner {
                width: 28px;
                height: 28px;
                border: 3px solid rgba(0, 0, 0, 0.12);
                border-top-color: #4a7fb5;
                border-radius: 50%;
                animation: kiql-spin 0.9s linear infinite;
            }
            @media (prefers-color-scheme: dark) {
                #kiql-overlay { color: #a0a0b0; }
                #kiql-overlay .spinner {
                    border-color: rgba(255, 255, 255, 0.15);
                    border-top-color: #81a2be;
                }
            }
            @keyframes kiql-spin { to { transform: rotate(360deg); } }
        </style>
        </head>
        <body>
        <div id="kiql-viewer"></div>
        <div id="kiql-overlay">
            <div class="spinner"></div>
            <div id="kiql-overlay-text">Loading…</div>
        </div>
        <script>
        // Record the first unhandled rejection so the watchdog below can
        // fail fast instead of waiting for the timeout. Registered before
        // the viewer scripts so nothing is missed.
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
        // In a WKWebView that is not visible/composited (offscreen thumbnail
        // rendering) requestAnimationFrame may never fire; guarantee each
        // callback runs by racing it against a short timeout.
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
        <script src="/o3dv.min.js"></script>
        <script>
        (() => {
        const post = (status) => {
            try { window.webkit?.messageHandlers?.renderState?.postMessage(status); } catch (e) {}
        };
        const overlay = document.getElementById("kiql-overlay");
        const overlayText = document.getElementById("kiql-overlay-text");
        const setStatus = (text) => { overlayText.textContent = text; };
        const showOverlayError = (message) => {
            overlay.querySelector(".spinner")?.remove();
            overlay.classList.remove("hidden");
            overlayText.textContent = message;
        };
        const started = Date.now();
        let finished = false;
        const finish = (status) => {
            if (finished) return;
            finished = true;
            post(status);
        };
        // The CAD kernel runs in a worker so a slow tessellation can be
        // abandoned (terminated) when the budget runs out.
        let occtWorker = null;
        const stopWorker = () => {
            try { occtWorker?.terminate(); } catch (e) {}
            occtWorker = null;
        };

        const watchdog = setInterval(() => {
            if (finished) { clearInterval(watchdog); return; }
            if (window.__kiqlRejection && Date.now() - window.__kiqlRejection.time > 2000) {
                stopWorker();
                showOverlayError("Could not render this model: " + window.__kiqlRejection.message);
                finish("error: " + window.__kiqlRejection.message);
            } else if (Date.now() - started > \(timeoutMs)) {
                stopWorker();
                showOverlayError("Rendering timed out — this model may be too complex for the previewer.");
                finish("timeout");
            }
        }, 250);

        if (typeof OV === "undefined") {
            showOverlayError("The 3D viewer failed to load.");
            finish("error: viewer script missing");
            return;
        }

        // Online 3D Viewer's STEP importer fetches occt-import-js from a CDN
        // inside a Web Worker. Replace it with a worker served from this
        // page's own scheme, and hand the result to the importer's own
        // converter.
        if (OV.ImporterOcct) {
            // CAD files (KiCad board exports included) are Z-up; the
            // loader rotates Z-up models into the viewer's Y-up scene.
            OV.ImporterOcct.prototype.GetUpDirection = function () { return OV.Direction.Z; };
            OV.ImporterOcct.prototype.ImportContent = function (fileContent, onFinish) {
                const fail = (message) => {
                    stopWorker();
                    this.SetError(message);
                    onFinish();
                };
                let format = null;
                if (this.extension === "stp" || this.extension === "step") format = "step";
                else if (this.extension === "igs" || this.extension === "iges") format = "iges";
                else if (this.extension === "brp" || this.extension === "brep") format = "brep";
                if (format === null) {
                    fail("unsupported CAD format");
                    return;
                }
                if (format !== "brep") this.model.SetUnit(OV.Unit.Millimeter);
                setStatus("Tessellating…");
                try {
                    occtWorker = new Worker("/occt-worker.js");
                } catch (e) {
                    fail("could not start the CAD kernel: " + String(e && e.message || e));
                    return;
                }
                occtWorker.onmessage = (event) => {
                    const data = event.data || {};
                    if (data.status) {
                        setStatus(data.status);
                        return;
                    }
                    if (!data.ok || !data.result || !data.result.success) {
                        fail(data.message || "Open CASCADE could not read this file");
                        return;
                    }
                    stopWorker();
                    try {
                        this.ImportResultJson(data.result, onFinish);
                    } catch (e) {
                        fail(String(e && e.message || e));
                    }
                };
                occtWorker.onerror = (event) => {
                    fail("CAD kernel error: " + String(event && event.message || "unknown"));
                };
                occtWorker.postMessage({
                    format,
                    buffer: new Uint8Array(fileContent),
                    params: {
                        linearUnit: "millimeter",
                        linearDeflectionType: "bounding_box_ratio",
                        linearDeflection: \(linearDeflection),
                        angularDeflection: \(angularDeflection),
                    },
                });
            };
        }

        const container = document.getElementById("kiql-viewer");
        const canvas = document.createElement("canvas");
        container.appendChild(canvas);
        // The viewer creates its WebGL renderer without an alpha channel.
        // A canvas hands back its existing context regardless of the
        // attributes a later getContext() asks for, so creating an
        // alpha-capable context first is what makes the clear color's
        // transparency reach the page.
        try {
            canvas.getContext("webgl2", { alpha: true, antialias: true, premultipliedAlpha: true });
        } catch (e) {}
        const viewer = new OV.Viewer();
        viewer.Init(canvas);
        const resize = () => {
            const w = container.clientWidth || document.documentElement.clientWidth || 800;
            const h = container.clientHeight || document.documentElement.clientHeight || 600;
            viewer.Resize(w, h);
        };
        resize();
        window.addEventListener("resize", resize);
        viewer.SetBackgroundColor(new OV.RGBAColor(0, 0, 0, 0));

        // Projects the model's bounding box through the current camera and
        // returns its extent in normalized device coordinates.
        const projectedBounds = (box) => {
            viewer.Render();
            const camera = viewer.camera;
            let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
            for (const x of [box.min.x, box.max.x]) {
                for (const y of [box.min.y, box.max.y]) {
                    for (const z of [box.min.z, box.max.z]) {
                        const p = box.min.clone().set(x, y, z).project(camera);
                        minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
                        minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
                    }
                }
            }
            return { minX, minY, maxX, maxY };
        };

        // The sphere fit leaves flat models (boards) small in the frame.
        // Dolly the camera until the projected bounding box fills most of
        // the view, then record where the model sits for thumbnail
        // cropping.
        const frameModel = () => {
            try {
                const box = viewer.GetBoundingBox(() => true);
                if (!box || box.isEmpty()) return;
                for (let i = 0; i < 4; i++) {
                    const b = projectedBounds(box);
                    const extent = Math.max(Math.abs(b.minX), Math.abs(b.maxX), Math.abs(b.minY), Math.abs(b.maxY));
                    if (!(extent > 0) || !isFinite(extent)) return;
                    const scale = extent / 0.88;
                    if (Math.abs(scale - 1) < 0.02) break;
                    const camera = viewer.GetCamera();
                    const eye = camera.eye, center = camera.center;
                    const newEye = new OV.Coord3D(
                        center.x + (eye.x - center.x) * scale,
                        center.y + (eye.y - center.y) * scale,
                        center.z + (eye.z - center.z) * scale
                    );
                    viewer.SetCamera(new OV.Camera(newEye, center.Clone(), camera.up.Clone(), camera.fov));
                }
                const b = projectedBounds(box);
                const margin = 0.03 * Math.max(b.maxX - b.minX, b.maxY - b.minY);
                const clamp = (v) => Math.min(1, Math.max(0, v));
                const left = clamp((b.minX - margin + 1) / 2);
                const right = clamp((b.maxX + margin + 1) / 2);
                const top = clamp((1 - (b.maxY + margin)) / 2);
                const bottom = clamp((1 - (b.minY - margin)) / 2);
                if (right - left > 0.05 && bottom - top > 0.05) {
                    window.__kiqlCrop = { fx: left, fy: top, fw: right - left, fh: bottom - top, tight: true };
                }
            } catch (e) {}
        };

        const settings = new OV.ImportSettings();
        const loader = new OV.ThreeModelLoader();
        const inputFiles = OV.InputFilesFromUrls(["\(documentPath)"]);
        const load = () => loader.LoadModel(inputFiles, settings, {
            onLoadStart: () => setStatus("Loading…"),
            onFileListProgress: () => {},
            onFileLoadProgress: () => {},
            onImportStart: () => setStatus("Importing…"),
            onVisualizationStart: () => setStatus("Building scene…"),
            onModelFinished: (importResult, threeObject) => {
                try {
                    viewer.SetMainObject(threeObject);
                    const sphere = viewer.GetBoundingSphere(() => true);
                    viewer.AdjustClippingPlanesToSphere(sphere);
                    viewer.SetUpVector(OV.Direction.Y, false);
                    viewer.FitSphereToWindow(sphere, false);
                    frameModel();
                    viewer.AdjustClippingPlanesToSphere(sphere);
                    viewer.Render();
                } catch (e) {
                    showOverlayError("Could not display this model: " + String(e && e.message || e));
                    finish("error: " + String(e && e.message || e));
                    return;
                }
                overlay.classList.add("hidden");
                requestAnimationFrame(() => requestAnimationFrame(() => finish("loaded")));
            },
            onTextureLoaded: () => viewer.Render(),
            onLoadError: (importError) => {
                let message = "Could not import this model.";
                if (importError && importError.message) message += " (" + importError.message + ")";
                showOverlayError(message);
                finish("error: " + message);
            },
        });
        window.addEventListener("error", (e) => finish("error: " + e.message));

        // "ready" as soon as the page (with its progress overlay) has
        // painted; the preview completes Quick Look at that point. Only
        // then start importing: both the 3MF parse and the STEP
        // tessellation block this thread, and starting them first would
        // hold the system spinner for the whole import.
        requestAnimationFrame(() => requestAnimationFrame(() => {
            post("ready");
            setTimeout(load, 0);
        }));
        })();
        </script>
        </body>
        </html>
        """
        return PreviewHTMLBuilder.Page(html: html, resources: resources)
    }

    /// Worker that loads occt-import-js (script and .wasm, both served
    /// over kiql://) and tessellates one file per message.
    private static let occtWorkerScript = """
    importScripts("/occt-import-js.js");
    let kernel = null;
    onmessage = async (event) => {
        try {
            const message = event.data;
            if (kernel === null) {
                postMessage({ status: "Loading CAD kernel…" });
                kernel = await occtimportjs({ locateFile: (path) => "/" + path });
                postMessage({ status: "Tessellating…" });
            }
            const result = kernel.ReadFile(message.format, message.buffer, message.params);
            postMessage({ ok: true, result });
        } catch (e) {
            postMessage({ ok: false, message: String(e && e.message || e) });
        }
    };
    """
}
