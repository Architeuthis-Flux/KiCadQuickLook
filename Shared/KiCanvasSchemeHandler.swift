import Foundation
import WebKit

/// Serves the preview page, the KiCanvas bundle, and the KiCad document
/// bytes over a private `kiql://` scheme.
///
/// Serving the document as a fetchable resource (instead of HTML-escaping it
/// into the page) keeps memory flat for multi-megabyte boards: the bytes are
/// handed to WebKit once, and KiCanvas consumes them via its normal fetch
/// path. It also gives the page a real origin, so browser storage APIs
/// behave normally.
final class KiCanvasSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "kiql"
    static let entryURL = URL(string: "\(scheme)://preview/index.html")!

    struct Resource {
        let mimeType: String
        let data: Data
    }

    /// Keyed by URL path, e.g. "/kicanvas.js".
    private var resources: [String: Resource] = [:]

    func setResource(path: String, mimeType: String, data: Data) {
        resources[path] = Resource(mimeType: mimeType, data: data)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let resource = resources[url.path]
        else {
            urlSchemeTask.didFailWithError(CocoaError(.fileNoSuchFile))
            return
        }
        // Must be an HTTPURLResponse with a real status code: `fetch()` in
        // the page reports plain URLResponses as status 0 / not ok.
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.contentType(for: resource.mimeType),
                "Content-Length": String(resource.data.count),
            ]
        ) else {
            urlSchemeTask.didFailWithError(CocoaError(.fileNoSuchFile))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(resource.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    /// Only text-like types carry a charset: WebAssembly streaming
    /// compilation requires the response type to be exactly
    /// `application/wasm`, and binary model files have no encoding.
    static func contentType(for mimeType: String) -> String {
        let textual = mimeType.hasPrefix("text/")
            || mimeType.hasSuffix("javascript")
            || mimeType.hasSuffix("json")
            || mimeType.hasSuffix("xml")
        return textual ? "\(mimeType); charset=utf-8" : mimeType
    }
}
