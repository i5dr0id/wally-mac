import AVFoundation
import AppKit
import IOKit.ps

// LiveWallpaper — loops a video in a desktop-level window, beneath the desktop
// icons and above the macOS wallpaper, controlled from a menu bar item.
//
// Why this exists: macOS plays an Aerial *desktop* wallpaper once on login/unlock
// and then holds the last frame. The lock screen and screen saver loop forever, but
// the desktop does not, and there is no setting for it. This app supplies the
// looping desktop layer; the Aerial slot still drives the screen saver and lock
// screen, and the "Screen Saver & Lock Screen" menu writes to it.
//
// Settings live in the `local.LiveWallpaper` defaults domain.

// MARK: - Settings

private enum Key {
    static let videoPath = "videoPath"
    static let paused = "paused"
    static let playAtLaunch = "startPlayingAtLaunch"
    static let pauseOnBattery = "pauseOnBattery"
    static let pauseInLowPower = "pauseInLowPowerMode"
    static let pauseWhenCovered = "pauseWhenCovered"
    static let gravity = "videoGravity"
    static let dim = "dimLevel"
    static let library = "libraryFolder"
    static let launchAtLogin = "launchAtLogin"
    static let source = "sourceFolder"
}

private let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
private let agentLabel = "local.LiveWallpaper"
private let repoURL = "https://github.com/i5dr0id/wally-mac"

/// A local working copy if one is configured, otherwise the source shipped inside
/// the bundle — so "Open Source Folder" works on a machine that only ever received
/// the packaged app. Point it at a checkout with:
///
///     defaults write local.LiveWallpaper sourceFolder ~/path/to/wally-mac
private var sourceFolder: String {
    let bundled = Bundle.main.resourcePath ?? NSTemporaryDirectory()
    guard let configured = UserDefaults.standard.string(forKey: Key.source),
          !configured.isEmpty else { return bundled }
    let path = NSString(string: configured).expandingTildeInPath
    return FileManager.default.fileExists(atPath: path + "/main.swift") ? path : bundled
}

private struct Settings {
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: [
            Key.videoPath: NSString(string: "~/Movies/Live/Foggy Red Sky.mov").expandingTildeInPath,
            Key.paused: false,
            Key.playAtLaunch: true,
            Key.pauseOnBattery: true,
            Key.pauseInLowPower: true,
            Key.pauseWhenCovered: true,
            Key.gravity: "fill",
            Key.dim: 0.0,
            Key.library: NSString(string: "~/Movies/Live").expandingTildeInPath,
            Key.launchAtLogin: true,
        ])
    }

    private func url(_ key: String) -> URL {
        URL(fileURLWithPath: NSString(string: d.string(forKey: key) ?? "").expandingTildeInPath)
    }

    var videoURL: URL {
        get { url(Key.videoPath) }
        nonmutating set { d.set(newValue.path, forKey: Key.videoPath) }
    }
    var libraryURL: URL {
        get { url(Key.library) }
        nonmutating set { d.set(newValue.path, forKey: Key.library) }
    }
    var paused: Bool {
        get { d.bool(forKey: Key.paused) }
        nonmutating set { d.set(newValue, forKey: Key.paused) }
    }
    var playAtLaunch: Bool {
        get { d.bool(forKey: Key.playAtLaunch) }
        nonmutating set { d.set(newValue, forKey: Key.playAtLaunch) }
    }
    var pauseOnBattery: Bool {
        get { d.bool(forKey: Key.pauseOnBattery) }
        nonmutating set { d.set(newValue, forKey: Key.pauseOnBattery) }
    }
    var pauseInLowPower: Bool {
        get { d.bool(forKey: Key.pauseInLowPower) }
        nonmutating set { d.set(newValue, forKey: Key.pauseInLowPower) }
    }
    var pauseWhenCovered: Bool {
        get { d.bool(forKey: Key.pauseWhenCovered) }
        nonmutating set { d.set(newValue, forKey: Key.pauseWhenCovered) }
    }
    var dim: Double {
        get { d.double(forKey: Key.dim) }
        nonmutating set { d.set(newValue, forKey: Key.dim) }
    }
    var launchAtLogin: Bool {
        get { d.bool(forKey: Key.launchAtLogin) }
        nonmutating set { d.set(newValue, forKey: Key.launchAtLogin) }
    }
    var gravity: AVLayerVideoGravity {
        get {
            switch d.string(forKey: Key.gravity) {
            case "fit": return .resizeAspect
            case "stretch": return .resize
            default: return .resizeAspectFill
            }
        }
        nonmutating set {
            d.set(newValue == .resizeAspect ? "fit" : (newValue == .resize ? "stretch" : "fill"),
                  forKey: Key.gravity)
        }
    }
}

// MARK: - Shell

@discardableResult
private func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Screen saver / lock screen

/// Installs a video into the macOS Aerial slot, which drives the screen saver and
/// the lock screen.
///
/// On macOS 26/27 the Aerial manifest lives inside the SIP-protected extension
/// bundle, so a genuinely custom asset cannot be registered. The workaround is to
/// keep a real Apple asset ID and swap the video file underneath it. Apple's
/// original is preserved next to it as `<id>.mov.apple-original`.
private enum Aerial {
    private static let provider = "com.apple.wallpaper.choice.aerials"

    private static var videosDir: URL {
        URL(fileURLWithPath: NSString(string:
            "~/Library/Application Support/com.apple.wallpaper/aerials/videos").expandingTildeInPath)
    }
    private static var storeDir: URL {
        URL(fileURLWithPath: NSString(string:
            "~/Library/Application Support/com.apple.wallpaper/Store").expandingTildeInPath)
    }

    /// The Aerial this Mac currently has selected.
    ///
    /// Read from the wallpaper store rather than hardcoded, because the asset IDs in
    /// the bundled manifest differ between Macs and macOS versions — a fixed ID that
    /// this machine has never heard of would silently fall back to a stock Aerial.
    /// Whichever one is selected is the one we swap underneath, which also makes
    /// re-running this idempotent.
    static var assetID: String? {
        guard let data = try? Data(contentsOf: storeDir.appendingPathComponent("Index.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return findAssetID(plist)
    }

    private static func findAssetID(_ node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let choices = dict["Choices"] as? [[String: Any]] {
                for ch in choices where ch["Provider"] as? String == provider {
                    if let cfg = ch["Configuration"] as? Data,
                       let inner = try? PropertyListSerialization.propertyList(from: cfg, options: [], format: nil) as? [String: Any],
                       let id = inner["assetID"] as? String { return id }
                }
            }
            for v in dict.values { if let found = findAssetID(v) { return found } }
        }
        if let arr = node as? [Any] {
            for v in arr { if let found = findAssetID(v) { return found } }
        }
        return nil
    }

    private static func target(_ id: String) -> URL { videosDir.appendingPathComponent("\(id).mov") }
    private static func appleOriginal(_ id: String) -> URL { videosDir.appendingPathComponent("\(id).mov.apple-original") }

    /// Best-effort identification of what is currently installed, by size match.
    static func installedMatches(_ url: URL) -> Bool {
        guard let id = assetID else { return false }
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: target(id).path)[.size] as? Int,
              let b = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int else { return false }
        return a == b
    }

    static var hasAppleOriginal: Bool {
        guard let id = assetID else { return false }
        return FileManager.default.fileExists(atPath: appleOriginal(id).path)
    }

    private static func requireAsset() throws -> String {
        guard FileManager.default.fileExists(atPath: videosDir.path), let id = assetID else {
            throw NSError(domain: "LiveWallpaper", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No Aerial is set up on this Mac yet.\n\nOpen System Settings › Wallpaper, pick any Aerial and let it finish downloading, then try again."])
        }
        return id
    }

    static func install(_ url: URL) throws {
        let id = try requireAsset()
        let fm = FileManager.default
        // The installed file is locked with uchg so idleassetsd cannot re-download over it.
        run("/usr/bin/chflags", ["nouchg", target(id).path])
        if fm.fileExists(atPath: target(id).path), !hasAppleOriginal {
            try? fm.moveItem(at: target(id), to: appleOriginal(id))  // keep Apple's copy once
        }
        try? fm.removeItem(at: target(id))
        try fm.copyItem(at: url, to: target(id))
        run("/usr/bin/chflags", ["uchg", target(id).path])
        try pointStoreAtAsset(id)
        restartAgents()
    }

    static func restoreApple() throws {
        let id = try requireAsset()
        let fm = FileManager.default
        run("/usr/bin/chflags", ["nouchg", target(id).path])
        try? fm.removeItem(at: target(id))
        if fm.fileExists(atPath: appleOriginal(id).path) {
            try fm.moveItem(at: appleOriginal(id), to: target(id))
        }
        restartAgents()  // with the file gone, macOS re-downloads the original
    }

    /// Rewrites every aerial choice in the wallpaper store to our asset ID.
    private static func pointStoreAtAsset(_ assetID: String) throws {
        let cfg = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID], format: .binary, options: 0)

        for name in ["Index.plist", "Index_v2.plist"] {
            let file = storeDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil) else { continue }

            let backup = storeDir.appendingPathComponent("\(name).livewallpaper-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? data.write(to: backup)
            }
            let patched = patch(plist, cfg: cfg)
            let out = try PropertyListSerialization.data(
                fromPropertyList: patched, format: .binary, options: 0)
            try out.write(to: file)
        }
    }

    private static func patch(_ node: Any, cfg: Data) -> Any {
        if let dict = node as? [String: Any] {
            var out = dict
            for (k, v) in dict {
                if k == "Choices", let choices = v as? [[String: Any]] {
                    out[k] = choices.map { ch -> [String: Any] in
                        var c = ch
                        if ch["Provider"] as? String == provider { c["Configuration"] = cfg }
                        return c
                    }
                } else {
                    out[k] = patch(v, cfg: cfg)
                }
            }
            return out
        }
        if let arr = node as? [Any] { return arr.map { patch($0, cfg: cfg) } }
        return node
    }

    private static func restartAgents() {
        run("/usr/bin/pkill", ["-f", "WallpaperAerialsExtension"])
        run("/usr/bin/killall", ["WallpaperAgent"])
    }
}

// MARK: - Power

private var powerSourceChanged: (() -> Void)?

private func onACPower() -> Bool {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
    else { return true }  // unknown: assume plugged in rather than silently freezing
    return type == "AC Power"
}

// MARK: - One screen's playback

private final class WallpaperScreen {
    let window: NSWindow
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let videoLayer: AVPlayerLayer
    private var dimLayer: CALayer?

    init(screen: NSScreen, url: URL, gravity: AVLayerVideoGravity, dim: Double) {
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        // Local file: no need to buffer ahead for stall avoidance.
        player.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: player, templateItem: item)

        let size = screen.frame.size
        videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = gravity
        videoLayer.frame = CGRect(origin: .zero, size: size)
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(videoLayer)

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Directly beneath the desktop icons: above the system wallpaper,
        // below anything the user interacts with.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.setFrame(screen.frame, display: true)
        window.orderBack(nil)

        // Note: setting `preferredMaximumResolution` to the display size was tried
        // here and measured as a no-op for local files (2.61% vs 2.62% of one core
        // over alternating 45 s samples), so it was removed rather than left in as
        // an optimization that only looks like one. It is documented for streaming.

        setDim(dim)
    }

    var isVisible: Bool { window.occlusionState.contains(.visible) }

    func setGravity(_ g: AVLayerVideoGravity) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.videoGravity = g
        CATransaction.commit()
    }

    /// The dim layer is only instantiated when it is actually used, so the common
    /// case composites one layer instead of two.
    func setDim(_ value: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard value > 0.001 else {
            dimLayer?.removeFromSuperlayer()
            dimLayer = nil
            return
        }
        if dimLayer == nil {
            let l = CALayer()
            l.backgroundColor = NSColor.black.cgColor
            l.frame = videoLayer.frame
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            window.contentView?.layer?.addSublayer(l)
            dimLayer = l
        }
        dimLayer?.opacity = Float(value)
    }

    func play() { if player.rate == 0 { player.play() } }
    func pause() { if player.rate != 0 { player.pause() } }

    func tearDown() {
        player.pause()
        player.removeAllItems()
        window.orderOut(nil)
        window.close()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private var screens: [WallpaperScreen] = []
    private var statusItem: NSStatusItem!
    private var screensAsleep = false
    private var sessionActive = true
    private var ticker: Timer?

    /// Why playback is stopped, shown in the menu so a pause is never mysterious.
    private var videoMissing: Bool {
        !FileManager.default.fileExists(atPath: settings.videoURL.path)
    }

    private var pauseReason: String? {
        if videoMissing { return "No video — choose one below" }
        if settings.paused { return "Paused" }
        if settings.pauseOnBattery && !onACPower() { return "Paused — on battery" }
        if settings.pauseInLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { return "Paused — Low Power Mode" }
        if screensAsleep || !sessionActive { return "Paused — display asleep" }
        if settings.pauseWhenCovered && !screens.isEmpty && !screens.contains(where: { $0.isVisible }) {
            return "Paused — desktop covered"
        }
        return nil
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // "Show live wallpaper at startup": clear a manual pause left over from
        // last session so a fresh login always comes up playing.
        if settings.playAtLaunch { settings.paused = false }

        buildStatusItem()
        rebuild()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(rebuild), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(refresh), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        nc.addObserver(self, selector: #selector(refresh), name: .NSProcessInfoPowerStateDidChange, object: nil)

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(slept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(woke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(slept), name: NSWorkspace.willSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(sessionOff), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        wnc.addObserver(self, selector: #selector(sessionOn), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        wnc.addObserver(self, selector: #selector(refresh), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        powerSourceChanged = { [weak self] in self?.updatePlayback() }
        if let src = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { powerSourceChanged?() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }

        // Safety net: recover within seconds if a notification is ever missed,
        // rather than leaving a frozen frame on screen.
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updatePlayback()
        }
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

    }

    private func updateStatusIcon() {
        let name = pauseReason == nil ? "photo.on.rectangle.angled" : "pause.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "LiveWallpaper")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let name = settings.videoURL.deletingPathExtension().lastPathComponent
        menu.addItem(header(name.isEmpty ? "No video" : name))
        menu.addItem(header(pauseReason ?? "Playing"))
        menu.addItem(.separator())

        add(menu, settings.paused ? "Resume" : "Pause", #selector(togglePause), key: "p")
        menu.addItem(.separator())

        menu.addItem(submenu("Desktop Wallpaper", desktopMenu()))
        menu.addItem(submenu("Screen Saver & Lock Screen", aerialMenu()))
        menu.addItem(submenu("Fill Mode", gravityMenu()))
        menu.addItem(submenu("Dim", dimMenu()))
        menu.addItem(.separator())

        add(menu, "Pause on Battery", #selector(toggleBattery), on: settings.pauseOnBattery)
        add(menu, "Pause in Low Power Mode", #selector(toggleLowPower), on: settings.pauseInLowPower)
        add(menu, "Pause When Desktop Covered", #selector(toggleCovered), on: settings.pauseWhenCovered)
        menu.addItem(.separator())

        add(menu, "Launch at Login", #selector(toggleLaunchAtLogin), on: settings.launchAtLogin)
        add(menu, "Start Playing at Launch", #selector(togglePlayAtLaunch), on: settings.playAtLaunch)
        menu.addItem(.separator())

        add(menu, "Open Source Folder", #selector(openSource))
        add(menu, "View on GitHub", #selector(openRepo))
        add(menu, "Quit LiveWallpaper", #selector(quit), key: "q")
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     key: String = "", on: Bool? = nil, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let on { item.state = on ? .on : .off }
        item.representedObject = represented
        menu.addItem(item)
        return item
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func libraryVideos() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: settings.libraryURL, includingPropertiesForKeys: nil))?
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            ?? []
    }

    private func desktopMenu() -> NSMenu {
        let m = NSMenu()
        let current = settings.videoURL.standardizedFileURL.path
        let files = libraryVideos()
        if files.isEmpty { m.addItem(header("No videos in \(settings.libraryURL.lastPathComponent)")) }
        for f in files {
            add(m, f.deletingPathExtension().lastPathComponent, #selector(pickDesktop(_:)),
                on: f.standardizedFileURL.path == current, represented: f)
        }
        m.addItem(.separator())
        add(m, "Choose File…", #selector(chooseFile))
        add(m, "Choose Library Folder…", #selector(chooseLibrary))
        add(m, "Reveal in Finder", #selector(revealLibrary))
        return m
    }

    private func aerialMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(header("Applies to screen saver + lock screen"))
        m.addItem(.separator())
        let files = libraryVideos()
        for f in files {
            add(m, f.deletingPathExtension().lastPathComponent, #selector(pickAerial(_:)),
                on: Aerial.installedMatches(f), represented: f)
        }
        m.addItem(.separator())
        add(m, "Use Current Desktop Video", #selector(aerialMatchDesktop))
        if Aerial.hasAppleOriginal {
            add(m, "Restore Apple's Aerial", #selector(aerialRestore))
        }
        return m
    }

    private func gravityMenu() -> NSMenu {
        let m = NSMenu()
        let g = settings.gravity
        add(m, "Fill Screen", #selector(setGravity(_:)), on: g == .resizeAspectFill, represented: "fill")
        add(m, "Fit (letterbox)", #selector(setGravity(_:)), on: g == .resizeAspect, represented: "fit")
        add(m, "Stretch", #selector(setGravity(_:)), on: g == .resize, represented: "stretch")
        return m
    }

    private func dimMenu() -> NSMenu {
        let m = NSMenu()
        for level in [0.0, 0.15, 0.30, 0.45, 0.60] {
            add(m, level == 0 ? "Off" : "\(Int(level * 100))%", #selector(setDim(_:)),
                on: abs(settings.dim - level) < 0.01, represented: level)
        }
        return m
    }

    // MARK: Actions

    @objc private func togglePause() { settings.paused.toggle(); updatePlayback() }
    @objc private func toggleBattery() { settings.pauseOnBattery.toggle(); updatePlayback() }
    @objc private func toggleLowPower() { settings.pauseInLowPower.toggle(); updatePlayback() }
    @objc private func toggleCovered() { settings.pauseWhenCovered.toggle(); updatePlayback() }
    @objc private func togglePlayAtLaunch() { settings.playAtLaunch.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openRepo() {
        if let url = URL(string: repoURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func openSource() {
        NSWorkspace.shared.selectFile(sourceFolder + "/main.swift",
                                      inFileViewerRootedAtPath: sourceFolder)
    }

    @objc private func setGravity(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "fit": settings.gravity = .resizeAspect
        case "stretch": settings.gravity = .resize
        default: settings.gravity = .resizeAspectFill
        }
        // Cheap enough to apply in place — no need to tear down the players.
        screens.forEach { $0.setGravity(settings.gravity) }
    }

    @objc private func setDim(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Double else { return }
        settings.dim = level
        screens.forEach { $0.setDim(level) }
    }

    @objc private func pickDesktop(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        settings.videoURL = url
        rebuild()
    }

    @objc private func pickAerial(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        applyAerial(url)
    }

    @objc private func aerialMatchDesktop() { applyAerial(settings.videoURL) }

    @objc private func aerialRestore() {
        do { try Aerial.restoreApple() } catch { report(error, "restore Apple's Aerial") }
    }

    private func applyAerial(_ url: URL) {
        do { try Aerial.install(url) } catch { report(error, "set the screen saver") }
    }

    private func report(_ error: Error, _ what: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Couldn’t \(what)."
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning
        a.runModal()
    }

    @objc private func chooseFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a video for the desktop"
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.canChooseDirectories = false
        panel.directoryURL = settings.libraryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.videoURL = url
            rebuild()
        }
    }

    @objc private func chooseLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose the folder to list videos from"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = settings.libraryURL
        if panel.runModal() == .OK, let url = panel.url { settings.libraryURL = url }
    }

    @objc private func revealLibrary() {
        NSWorkspace.shared.selectFile(settings.videoURL.path,
                                      inFileViewerRootedAtPath: settings.libraryURL.path)
    }

    private var agentURL: URL {
        URL(fileURLWithPath: NSString(string:
            "~/Library/LaunchAgents/\(agentLabel).plist").expandingTildeInPath)
    }

    /// Writes the launch agent pointing at wherever this copy of the app lives, so
    /// the app works when it is simply dragged out of the disk image rather than
    /// installed by the script.
    private func writeLaunchAgent() throws {
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            // Restart on a crash only, so Quit in the menu genuinely quits.
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardErrorPath": "/tmp/LiveWallpaper.err.log",
        ]
        try FileManager.default.createDirectory(
            at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: agentURL)
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin.toggle()
        let service = "gui/\(getuid())/\(agentLabel)"
        if settings.launchAtLogin {
            do { try writeLaunchAgent() } catch { report(error, "enable Launch at Login"); return }
            // Bootstrapping starts a second copy; the single-instance guard in
            // main() makes that one exit immediately, leaving this one running.
            run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentURL.path])
            run("/bin/launchctl", ["enable", service])
        } else {
            // disable rather than bootout, so switching it off does not kill the
            // copy that is running right now.
            run("/bin/launchctl", ["disable", service])
        }
    }

    // MARK: Playback

    @objc private func rebuild() {
        screens.forEach { $0.tearDown() }
        // On a fresh install the default video won't exist. Show nothing rather than
        // a black rectangle over the wallpaper, and let the menu explain why.
        screens = videoMissing ? [] : NSScreen.screens.map {
            WallpaperScreen(screen: $0, url: settings.videoURL,
                            gravity: settings.gravity, dim: settings.dim)
        }
        updatePlayback()
    }

    @objc private func refresh() { updatePlayback() }
    @objc private func slept() { screensAsleep = true; updatePlayback() }
    @objc private func woke() { screensAsleep = false; updatePlayback() }
    @objc private func sessionOff() { sessionActive = false; updatePlayback() }
    @objc private func sessionOn() { sessionActive = true; updatePlayback() }

    private func updatePlayback() {
        let stop = pauseReason != nil
        for s in screens { stop ? s.pause() : s.play() }
        updateStatusIcon()
    }
}

// Single instance. Two copies would stack two video layers on the desktop and
// double the power draw; this also lets "Launch at Login" bootstrap the agent
// without the freshly spawned copy fighting the one already running.
// Exit 0 so launchd's crash-only KeepAlive does not retry.
let selfPID = ProcessInfo.processInfo.processIdentifier
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id)
       .contains(where: { $0.processIdentifier != selfPID }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock tile: background scenery with a menu bar control.
app.setActivationPolicy(.accessory)
app.run()
