import ScreenSaver
import WebKit

// WallyClock — a screen saver that shows a live web page (by default the
// Concentric "mac-left" clock) bundled in its Resources/web folder.
//
// The macOS Aerial slot that LiveWallpaper writes to can only play a video, so
// a clock there would show the wrong time as it loops. This saver runs the page
// itself, so the time is always live. Pick it in System Settings › Screen Saver.

@objc(WallyClockView)
final class WallyClockView: ScreenSaverView {
    /// Layout for Concentric's standalone build, which reads `?page=`. Set at
    /// build time from build.sh's CLOCK_PAGE (written to Info.plist).
    private static var page: String {
        Bundle(for: WallyClockView.self).object(forInfoDictionaryKey: "WallyClockPage") as? String ?? "mac-left"
    }

    private var webView: WKWebView?
    private var stopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // WebKit drives its own frames; ScreenSaverView's timer only needs to idle.
        animationTimeInterval = 1
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func startAnimation() {
        super.startAnimation()
        guard webView == nil,
              let web = Bundle(for: Self.self).url(forResource: "web", withExtension: nil),
              let entry = (try? FileManager.default.contentsOfDirectory(atPath: web.path))?
                  .first(where: { $0 == "index.html" || $0 == "saver.html" })
        else { return }

        let view = makeLocalWebView(frame: bounds, folder: web, page: "\(entry)?page=\(Self.page)")
        addSubview(view)
        webView = view

        // Since macOS 14 the saver host (legacyScreenSaver) often never calls
        // stopAnimation and keeps the view alive after the screen saver ends. Tear
        // the page down on the system's own "will stop" notice so it does not keep
        // rendering in the background.
        if !isPreview, stopObserver == nil {
            stopObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
            ) { [weak self] _ in self?.tearDownPage() }
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        tearDownPage()
    }

    override func animateOneFrame() {}

    private func tearDownPage() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    deinit {
        if let stopObserver { DistributedNotificationCenter.default().removeObserver(stopObserver) }
    }
}
