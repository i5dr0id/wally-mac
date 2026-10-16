import CoreText
import OSLog
import QuartzCore
import ScreenSaver

// WallyClock — a screen saver showing the Concentric "mac-left" clock: two rings
// on the left edge over the wallpaper, the seconds ring sweeping continuously and
// the minute ring rolling to each new minute.
//
// The macOS Aerial slot that LiveWallpaper writes to can only play a video, so a
// clock there would show the wrong time as it loops. This saver draws the clock
// itself, so the time is always live. Pick it in System Settings › Wallpaper ›
// Screen Saver….
//
// Drawn natively with Core Animation rather than in a web view: inside the saver
// host (legacyScreenSaver) WebKit's content process cannot hold the RunningBoard
// assertion it needs, so a WKWebView loads the page and then stops rendering,
// leaving the screen black.

/// `log stream --predicate 'subsystem == "local.LiveWallpaper.WallyClock"'`
private let log = Logger(subsystem: "local.LiveWallpaper.WallyClock", category: "saver")

// Geometry in design units, matching Concentric's MacLock page (src/pages/MacLock.*).
private enum Design {
    static let minuteLabelRadius: CGFloat = 210
    static let minuteTickRadius: CGFloat = 234
    static let secondsLabelRadius: CGFloat = 282
    static let secondsTickRadius: CGFloat = 308
    static let outerRadius: CGFloat = secondsTickRadius + 22
    static let widthReach: CGFloat = 0.33
    static let majorTick: CGFloat = 22
    static let minorTick: CGFloat = 9
    static let tickWidth: CGFloat = 2.2
    static let labelSize: CGFloat = 24
    static let hourSize: CGFloat = 112
    static let activeScale: CGFloat = 1.75
    static let weight: CGFloat = 560
    /// Dial center as a share of the screen, from the left and from the top.
    static let center = CGPoint(x: 0.015, y: 0.47)

    static let mint = NSColor(red: 0x6f / 255.0, green: 0xd5 / 255.0, blue: 0xbb / 255.0, alpha: 1)
    static let mutedAlpha: CGFloat = 0.6
    static let tick = NSColor(red: 36 / 255.0, green: 16 / 255.0, blue: 30 / 255.0, alpha: 1)
    static let minorTickAlpha: CGFloat = 0.5
    static let majorTickAlpha: CGFloat = 0.9
    static let teal = NSColor(red: 0x2f / 255.0, green: 0x7a / 255.0, blue: 0x6b / 255.0, alpha: 1)

    /// Fade by direction, as (degrees clockwise from 12 o'clock, opacity): bright
    /// along the 3 o'clock reading line, gone behind the screen's left edge.
    static let fade: [(CGFloat, CGFloat)] = [
        (0, 0.2), (60, 1), (120, 1), (180, 0.2), (205, 0), (335, 0), (360, 0.2),
    ]

    static let minuteRoll: CFTimeInterval = 0.9
    static let labelFade: CFTimeInterval = 0.4
    static let secondsFadeInDelay: CFTimeInterval = 0.3
    static let secondsFadeIn: CFTimeInterval = 1.2
}

private func fadeOpacity(clockwiseFromTop degrees: CGFloat) -> CGFloat {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d < 0 { d += 360 }
    for (a, b) in zip(Design.fade, Design.fade.dropFirst()) where d <= b.0 {
        return a.1 + (b.1 - a.1) * (d - a.0) / (b.0 - a.0)
    }
    return Design.fade.last!.1
}

/// CSS `cubic-bezier(0.65, 0, 0.25, 1)`, the web version's minute-roll easing.
private func ease(_ t: CGFloat) -> CGFloat {
    func bez(_ u: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
        3 * (1 - u) * (1 - u) * u * p1 + 3 * (1 - u) * u * u * p2 + u * u * u
    }
    var lo: CGFloat = 0, hi: CGFloat = 1
    for _ in 0..<24 {  // solve x(u) = t by bisection
        let mid = (lo + hi) / 2
        if bez(mid, 0.65, 0.25) < t { lo = mid } else { hi = mid }
    }
    return bez((lo + hi) / 2, 0, 1)
}

/// The macOS lock screen clock font and the wallpaper, bundled by build.sh.
private enum Assets {
    static let bundle = Bundle(for: WallyClockView.self)

    static let fontDescriptor: CTFontDescriptor? = {
        guard let url = bundle.url(forResource: "SFStencilNumeric", withExtension: "ttf") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
    }()

    static func font(size: CGFloat) -> NSFont {
        guard let base = fontDescriptor else {
            return .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        }
        let wght = 0x7767_6874  // 'wght'
        let desc = CTFontDescriptorCreateCopyWithAttributes(base, [
            kCTFontVariationAttribute: [wght: Design.weight],
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, size, nil) as NSFont
    }

    static let wallpaper: CGImage? = {
        guard let url = bundle.url(forResource: "wallpaper", withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
}

/// One ring of 60 ticks and its numbers, in a layer centered on the dial. The
/// ring layer turns; each label counter-turns to stay upright.
private final class RingLayer {
    let layer = CALayer()
    private var ticks: [(layer: CALayer, alpha: CGFloat)] = []
    private var labels: [CATextLayer] = []
    private var labelOpacity = [CGFloat](repeating: 0, count: 60)
    private var labelEmphasis = [CGFloat](repeating: 0, count: 60)
    private let showsActive: Bool

    /// - showsActive: show multiples of 5 plus the current value, enlarged, with
    ///   its near neighbors hidden (the minute ring); otherwise multiples of 5.
    init(labelRadius: CGFloat, tickRadius: CGFloat, scale s: CGFloat, contentsScale: CGFloat, showsActive: Bool) {
        self.showsActive = showsActive
        let font = Assets.font(size: Design.labelSize * s)
        for v in 0..<60 {
            let major = v % 5 == 0
            let angle = CGFloat(v) * 6 * .pi / 180
            let tick = CALayer()
            tick.backgroundColor = Design.tick.cgColor
            tick.bounds = CGRect(x: 0, y: 0, width: (major ? Design.majorTick : Design.minorTick) * s,
                                 height: Design.tickWidth * s)
            tick.cornerRadius = Design.tickWidth * s / 2
            tick.anchorPoint = CGPoint(x: 0, y: 0.5)
            tick.position = CGPoint(x: cos(angle) * tickRadius * s, y: sin(angle) * tickRadius * s)
            tick.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            layer.addSublayer(tick)
            ticks.append((tick, major ? Design.majorTickAlpha : Design.minorTickAlpha))

            let label = CATextLayer()
            let text = NSAttributedString(string: String(format: "%02d", v), attributes: [
                .font: font,
                .foregroundColor: Design.mint,
            ])
            label.string = text
            label.alignmentMode = .center
            label.contentsScale = contentsScale * Design.activeScale  // sharp when enlarged
            let size = text.size()
            label.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: ceil(size.height))
            label.position = CGPoint(x: cos(angle) * labelRadius * s, y: sin(angle) * labelRadius * s)
            label.opacity = 0
            layer.addSublayer(label)
            labels.append(label)
        }
    }

    /// - value: ring position in units, fractional while sweeping or rolling.
    /// - active: the value on the reading line, for the minute ring.
    /// - dt: seconds since the last update, for the label fades.
    func update(value: CGFloat, active: Int?, ringOpacity: CGFloat, dt: CGFloat) {
        let turn = -value * 6 * .pi / 180  // clockwise as the value grows
        layer.setAffineTransform(CGAffineTransform(rotationAngle: turn))
        let step = min(1, dt / CGFloat(Design.labelFade))

        for v in 0..<60 {
            // Screen direction of this value, in degrees clockwise from 12 o'clock.
            let fromTop = 90 + (value - CGFloat(v)) * 6
            let fade = fadeOpacity(clockwiseFromTop: fromTop) * ringOpacity
            ticks[v].layer.opacity = Float(ticks[v].alpha * fade)

            var target: CGFloat = v % 5 == 0 ? 1 : 0
            var emphasis: CGFloat = 0
            if showsActive, let active {
                let distance = min(abs(v - active), 60 - abs(v - active))
                if v == active {
                    target = 1
                    emphasis = 1
                } else if distance < 3 {
                    target = 0
                }
            }
            labelOpacity[v] += (target - labelOpacity[v]) * step
            labelEmphasis[v] += (emphasis - labelEmphasis[v]) * step

            let e = labelEmphasis[v]
            let alpha = Design.mutedAlpha + (1 - Design.mutedAlpha) * e
            labels[v].opacity = Float(labelOpacity[v] * fade * alpha)
            let k = 1 + (Design.activeScale - 1) * e
            labels[v].setAffineTransform(CGAffineTransform(rotationAngle: -turn).scaledBy(x: k, y: k))
        }
    }
}

@objc(WallyClockView)
final class WallyClockView: ScreenSaverView {
    private var scene: CALayer?
    private var minutes: RingLayer?
    private var seconds: RingLayer?
    private var hour: CATextLayer?
    private var dialScale: CGFloat = 1

    private var started: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var shownMinute: Int?
    private var shownHour: Int?
    // The minute ring's position only ever grows, so it rolls forward on wrap.
    private var rollFrom: CGFloat = 0
    private var rollTo: CGFloat = 0
    private var rollStart: CFTimeInterval?
    private var stopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        animationTimeInterval = 1.0 / 60
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func startAnimation() {
        super.startAnimation()
        log.notice("startAnimation preview=\(self.isPreview, privacy: .public) size=\(self.bounds.width, privacy: .public)x\(self.bounds.height, privacy: .public) font=\(Assets.fontDescriptor != nil, privacy: .public) wallpaper=\(Assets.wallpaper != nil, privacy: .public)")
        buildScene()

        // Since macOS 14 the saver host often never calls stopAnimation and keeps
        // the view alive after the screen saver ends; stop drawing on the system's
        // own "will stop" notice instead.
        if !isPreview, stopObserver == nil {
            stopObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
            ) { [weak self] _ in self?.tearDownScene() }
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        tearDownScene()
    }

    private func buildScene() {
        tearDownScene()
        guard let root = layer else { return }
        let w = bounds.width, h = bounds.height
        let s = max(h / 2, w * Design.widthReach) / Design.outerRadius
        let contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        let scene = CALayer()
        scene.frame = bounds
        scene.backgroundColor = Design.teal.cgColor
        scene.contents = Assets.wallpaper
        scene.contentsGravity = .resizeAspectFill
        scene.masksToBounds = true

        let center = CGPoint(x: w * Design.center.x, y: h * (1 - Design.center.y))
        let minutes = RingLayer(labelRadius: Design.minuteLabelRadius, tickRadius: Design.minuteTickRadius,
                                scale: s, contentsScale: contentsScale, showsActive: true)
        let seconds = RingLayer(labelRadius: Design.secondsLabelRadius, tickRadius: Design.secondsTickRadius,
                                scale: s, contentsScale: contentsScale, showsActive: false)
        for ring in [minutes, seconds] {
            ring.layer.position = center
            scene.addSublayer(ring.layer)
        }

        let hour = CATextLayer()
        hour.contentsScale = contentsScale
        hour.anchorPoint = CGPoint(x: 0, y: 0.5)
        hour.position = CGPoint(x: center.x + 3 * s, y: center.y)
        scene.addSublayer(hour)

        root.addSublayer(scene)
        self.scene = scene
        self.minutes = minutes
        self.seconds = seconds
        self.hour = hour
        dialScale = s
        shownMinute = nil
        shownHour = nil
        rollStart = nil
        started = CACurrentMediaTime()
        lastFrame = started
        animateOneFrame()
    }

    private func tearDownScene() {
        scene?.removeFromSuperlayer()
        scene = nil
        minutes = nil
        seconds = nil
        hour = nil
    }

    override func animateOneFrame() {
        guard let minutes, let seconds else { return }
        let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
        let minute = parts.minute ?? 0
        let second = CGFloat(parts.second ?? 0) + CGFloat(parts.nanosecond ?? 0) / 1e9

        let t = CACurrentMediaTime()
        let dt = CGFloat(t - lastFrame)
        lastFrame = t

        if let shown = shownMinute {
            if minute != shown {
                rollFrom = minuteValue(at: t)
                rollTo += CGFloat((minute - shown + 60) % 60)
                rollStart = t
            }
        } else {
            rollFrom = CGFloat(minute)
            rollTo = rollFrom
        }
        shownMinute = minute
        if parts.hour != shownHour {
            shownHour = parts.hour
            setHour(String(format: "%02d", parts.hour ?? 0))
        }

        let fadeIn = CGFloat(min(1, max(0, (t - started - Design.secondsFadeInDelay) / Design.secondsFadeIn)))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        minutes.update(value: minuteValue(at: t), active: minute, ringOpacity: 1, dt: dt)
        seconds.update(value: second, active: nil, ringOpacity: fadeIn, dt: dt)
        CATransaction.commit()
    }

    private func minuteValue(at t: CFTimeInterval) -> CGFloat {
        guard let rollStart else { return rollTo }
        let p = CGFloat(min(1, (t - rollStart) / Design.minuteRoll))
        if p >= 1 {
            self.rollStart = nil
            return rollTo
        }
        return rollFrom + (rollTo - rollFrom) * ease(p)
    }

    private func setHour(_ text: String) {
        guard let hour else { return }
        let string = NSAttributedString(string: text, attributes: [
            .font: Assets.font(size: Design.hourSize * dialScale),
            .foregroundColor: Design.mint,
        ])
        let size = string.size()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hour.string = string
        hour.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 4, height: ceil(size.height))
        CATransaction.commit()
    }

    deinit {
        if let stopObserver { DistributedNotificationCenter.default().removeObserver(stopObserver) }
    }
}
