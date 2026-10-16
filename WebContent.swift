import UniformTypeIdentifiers
import WebKit

// Web pages as wallpaper — shared by the app's desktop layer and the WallyClock
// screen saver.
//
// Pages are served from their folder under `wally://local/…` rather than loaded
// from file://. WebKit refuses ES module scripts (what Vite and most modern
// builds emit) from file:// URLs, so a page that works in a browser would load
// blank here. Behind a custom scheme the page and its assets share one origin.

final class LocalFolderSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "wally"
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let relative = url.path.removingPercentEncoding ?? url.path
        let file = root.appendingPathComponent(relative).standardizedFileURL
        // Never serve anything outside the page's own folder.
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A web view showing `page` (a file inside `folder`, optionally with a query
/// such as `saver.html?page=mac-left`), with every file in `folder` reachable.
func makeLocalWebView(frame: CGRect, folder: URL, page: String) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(LocalFolderSchemeHandler(root: folder),
                               forURLScheme: LocalFolderSchemeHandler.scheme)
    // Wallpaper pages often autoplay a muted background video.
    config.mediaTypesRequiringUserActionForPlayback = []
    config.suppressesIncrementalRendering = true

    let view = WKWebView(frame: frame, configuration: config)
    view.autoresizingMask = [.width, .height]
    view.allowsMagnification = false
    view.allowsBackForwardNavigationGestures = false
    // Transparent until the page paints, so loading never flashes white.
    view.setValue(false, forKey: "drawsBackground")
    if let url = URL(string: "\(LocalFolderSchemeHandler.scheme)://local/\(page)") {
        view.load(URLRequest(url: url))
    }
    return view
}

/// The `<title>` of an HTML file, for naming it in menus.
func htmlTitle(_ file: URL) -> String? {
    guard let html = try? String(contentsOf: file, encoding: .utf8),
          let open = html.range(of: "<title>", options: .caseInsensitive),
          let close = html.range(of: "</title>", options: .caseInsensitive,
                                 range: open.upperBound..<html.endIndex)
    else { return nil }
    let title = html[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
}
