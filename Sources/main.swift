import AppKit
import UserNotifications

// MARK: - Model

struct Limit {
    let pct: Double
    let resetsAt: Date?
}

/// A per-model weekly cap ("fable"). These come and go with the plan, so the
/// row count is per account rather than fixed.
struct ScopedLimit {
    let name: String
    let limit: Limit
}

struct Usage {
    let five: Limit?
    let seven: Limit?
    let scoped: [ScopedLimit]
    let fetchedAt: Date
    /// Short account name written by fetch-usage.sh ("takuma1201", "asteno").
    let label: String
    let email: String
    /// True for the default config dir (~/.claude). Sorted first, and the one
    /// the menu bar shows when several accounts are present.
    let isDefault: Bool
}

// MARK: - Formatting helpers

enum Fmt {
    static let timeF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let dayF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()
    static let dayTimeF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()
    static let clockF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func time(_ d: Date) -> String { timeF.string(from: d) }
    static func day(_ d: Date) -> String { dayF.string(from: d) }
    static func dayTime(_ d: Date) -> String { dayTimeF.string(from: d) }

    static func remain(_ d: Date) -> String {
        let s = max(0, Int(d.timeIntervalSinceNow))
        let h = s / 3600
        let m = (s % 3600) / 60
        if h >= 24 { return "あと\(h / 24)日\(h % 24)時間" }
        if h > 0 { return "あと\(h)時間\(m)分" }
        return "あと\(m)分"
    }
}

func colorFor(pct: Double) -> NSColor {
    if pct >= 80 { return .systemRed }
    if pct >= 50 { return .systemYellow }
    return .systemGreen
}

// MARK: - Usage reader (statusline cache only)

enum UsageFetcher {
    static var cacheDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
    }

    /// One cache per account. fetch-usage.sh names them the way Claude Code
    /// namespaces its Keychain items: `claude-usage-cache.json` for the default
    /// config dir, `claude-usage-cache-<sha256(dir)[0:8]>.json` for any other.
    /// Discovering them by glob means adding a third account needs no code change.
    static func all() -> [Usage] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cacheDir.path) else { return [] }
        let found = names
            .filter { $0.hasPrefix("claude-usage-cache") && $0.hasSuffix(".json") }
            .compactMap { name -> Usage? in
                guard let data = try? Data(contentsOf: cacheDir.appendingPathComponent(name)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return parse(obj, fallbackLabel: name)
            }
        return found.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.label < b.label
        }
    }

    private static func parse(_ json: [String: Any], fallbackLabel: String) -> Usage {
        let cachedAt = (json["cached_at"] as? NSNumber)?.doubleValue
        let account = json["account"] as? [String: Any]
        // config_dir is "" for the default account; a cache written before
        // fetch-usage.sh started recording accounts has no block at all.
        let dir = account?["config_dir"] as? String
        let label = (account?["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackLabel
        return Usage(
            five: limit(json["five_hour"]),
            seven: limit(json["seven_day"]),
            scoped: scopedLimits(json["limits"]),
            fetchedAt: cachedAt.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            label: label,
            email: account?["email"] as? String ?? "",
            isDefault: (dir ?? "").isEmpty
        )
    }

    /// Scoped caps live in `limits[]` and carry `percent` rather than
    /// `utilization` — same shape the statusline reads.
    private static func scopedLimits(_ any: Any?) -> [ScopedLimit] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { entry in
            guard entry["kind"] as? String == "weekly_scoped" else { return nil }
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = (model?["display_name"] as? String)
                ?? (scope?["surface"] as? String)
                ?? "model"
            var reset: Date?
            if let s = entry["resets_at"] as? String { reset = parseISO(s) }
            let pct = (entry["percent"] as? NSNumber)?.doubleValue ?? 0
            return ScopedLimit(name: name.lowercased(),
                               limit: Limit(pct: pct, resetsAt: reset))
        }
    }

    private static func limit(_ any: Any?) -> Limit? {
        guard let d = any as? [String: Any] else { return nil }
        let pct = (d["utilization"] as? NSNumber)?.doubleValue ?? 0
        var reset: Date?
        if let s = d["resets_at"] as? String { reset = parseISO(s) }
        return Limit(pct: pct, resetsAt: reset)
    }

    private static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        // Timezone-less fallback, treated as UTC (matches the statusline script)
        let f3 = DateFormatter()
        f3.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f3.timeZone = TimeZone(identifier: "UTC")
        return f3.date(from: String(s.prefix(19)))
    }
}

// MARK: - Overlay widget view

final class UsageView: NSView {
    var usages: [Usage] = [] {
        didSet { needsDisplay = true }
    }

    /// A single account with no scoped caps keeps the original 60pt layout and
    /// no header — the common case should look exactly as it always has.
    /// Everything else stacks: per account a header plus one row per limit.
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 16
    static let blockGap: CGFloat = 4
    static let topPad: CGFloat = 6

    static let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

    /// 5h + 7d + however many per-model caps the plan currently exposes.
    static func rows(for u: Usage) -> [(String, Limit?, String)] {
        var out: [(String, Limit?, String)] = [
            ("5h", u.five, (u.five?.resetsAt).map(Fmt.time) ?? ""),
            ("7d", u.seven, (u.seven?.resetsAt).map(Fmt.day) ?? ""),
        ]
        for s in u.scoped {
            out.append((s.name, s.limit, s.limit.resetsAt.map(Fmt.day) ?? ""))
        }
        return out
    }

    static func height(for usages: [Usage]) -> CGFloat {
        guard let first = usages.first else { return 60 }
        if usages.count == 1 {
            return 12 + CGFloat(rows(for: first).count) * rowHeight
        }
        return topPad + usages.reduce(CGFloat(0)) {
            $0 + headerHeight + CGFloat(rows(for: $1).count) * rowHeight + blockGap
        }
    }

    override var isFlipped: Bool { true }

    /// Bars start after the widest row label so "fable" cannot run into them,
    /// and every account shares one column so the bars stay aligned.
    private var barX: CGFloat {
        let widest = usages.flatMap(Self.rows).reduce(CGFloat(0)) { acc, row in
            max(acc, (row.0 as NSString).size(withAttributes: [.font: Self.labelFont]).width)
        }
        return max(38, 12 + widest.rounded(.up) + 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()

        let x = barX

        guard let first = usages.first else {
            drawRow(y: 10, label: "5h", limit: nil, resetText: "", barX: x)
            drawRow(y: 34, label: "7d", limit: nil, resetText: "", barX: x)
            return
        }

        if usages.count == 1 {
            var y: CGFloat = 10
            for (label, limit, reset) in Self.rows(for: first) {
                drawRow(y: y, label: label, limit: limit, resetText: reset, barX: x)
                y += Self.rowHeight
            }
            return
        }

        var top = Self.topPad
        for (i, u) in usages.enumerated() {
            if i > 0 {
                NSColor(calibratedWhite: 1.0, alpha: 0.12).setFill()
                NSBezierPath.fill(NSRect(x: 12, y: top - 3, width: bounds.width - 24, height: 1))
            }
            drawHeader(y: top, text: u.label, isDefault: u.isDefault)
            var y = top + Self.headerHeight
            for (label, limit, reset) in Self.rows(for: u) {
                drawRow(y: y, label: label, limit: limit, resetText: reset, barX: x)
                y += Self.rowHeight
            }
            top = y + Self.blockGap
        }
    }

    private func drawHeader(y: CGFloat, text: String, isDefault: Bool) {
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let color = isDefault
            ? NSColor(calibratedWhite: 1.0, alpha: 0.75)
            : NSColor.systemTeal
        (text as NSString).draw(at: NSPoint(x: 12, y: y),
                                withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawRow(y: CGFloat, label: String, limit: Limit?, resetText: String, barX: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let dim = NSColor(calibratedWhite: 1.0, alpha: 0.55)

        (label as NSString).draw(at: NSPoint(x: 12, y: y + 1),
                                 withAttributes: [.font: Self.labelFont, .foregroundColor: dim])

        let w = bounds.width
        let resetX = w - 66
        let pctRight = w - 74
        let barW = pctRight - 44 - barX
        let barRect = NSRect(x: barX, y: y + 2, width: barW, height: 12)

        NSColor(calibratedWhite: 1.0, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 6, yRadius: 6).fill()

        let pct = limit.map { min(max($0.pct, 0), 100) } ?? 0
        if limit != nil, pct > 0 {
            let fillW = max(barW * CGFloat(pct) / 100, 12)
            colorFor(pct: limit!.pct).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: y + 2, width: fillW, height: 12),
                         xRadius: 6, yRadius: 6).fill()
        }

        let pctStr = limit != nil ? String(format: "%.0f%%", pct) : "--"
        let pctColor = limit.map { colorFor(pct: $0.pct) } ?? dim
        let pctAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: pctColor]
        let pctSize = (pctStr as NSString).size(withAttributes: pctAttrs)
        (pctStr as NSString).draw(at: NSPoint(x: pctRight - pctSize.width, y: y + 1),
                                  withAttributes: pctAttrs)

        if !resetText.isEmpty {
            ("→" + resetText as NSString).draw(at: NSPoint(x: resetX, y: y + 1),
                                               withAttributes: [.font: font, .foregroundColor: dim])
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var usageView: UsageView!
    private var usages: [Usage] = []
    private var timer: Timer?
    private var resetTimers: [String: Timer] = [:]
    private var notificationsAvailable = false

    private let widgetWidth: CGFloat = 240
    private var widgetSize: NSSize {
        NSSize(width: widgetWidth, height: UsageView.height(for: usages))
    }
    /// The account the menu bar reports. There is no room for several, so it
    /// tracks the default one; the panel and the menu carry the rest.
    private var primary: Usage? { usages.first }
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        setupNotifications()

        if defaults.object(forKey: "widgetVisible") as? Bool ?? true {
            panel.orderFrontRegardless()
        }

        refresh(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func didWake() {
        refresh(force: false)
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.attributedTitle = makeTitle(nil)
        }
    }

    @objc private func statusClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleWidget()
        }
    }

    private func makeTitle(_ usage: Usage?) -> NSAttributedString {
        let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: NSColor.labelColor, .baselineOffset: -1,
        ]
        let t = NSMutableAttributedString()

        func valueAttrs(_ pct: Double) -> [NSAttributedString.Key: Any] {
            let c: NSColor = pct >= 80 ? .systemRed : (pct >= 50 ? .systemOrange : .labelColor)
            return [.font: valueFont, .foregroundColor: c, .baselineOffset: -1]
        }

        guard let u = usage, u.five != nil || u.seven != nil else {
            t.append(NSAttributedString(string: "CC --", attributes: labelAttrs))
            return t
        }
        if let f = u.five {
            t.append(NSAttributedString(string: "5h ", attributes: labelAttrs))
            t.append(NSAttributedString(string: String(format: "%.0f%%", f.pct),
                                        attributes: valueAttrs(f.pct)))
        }
        if let s = u.seven {
            if t.length > 0 { t.append(NSAttributedString(string: "  ", attributes: labelAttrs)) }
            t.append(NSAttributedString(string: "7d ", attributes: labelAttrs))
            t.append(NSAttributedString(string: String(format: "%.0f%%", s.pct),
                                        attributes: valueAttrs(s.pct)))
        }
        return t
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func info(_ title: String) {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }

        if usages.isEmpty {
            info("使用状況を取得できません")
        } else {
            for (i, u) in usages.enumerated() {
                if i > 0 { menu.addItem(.separator()) }
                if usages.count > 1 {
                    info(u.email.isEmpty ? u.label : "\(u.label) — \(u.email)")
                }
                if let f = u.five {
                    info(String(format: "5時間リミット: %.0f%%", f.pct))
                    if let r = f.resetsAt {
                        info("　リセット \(Fmt.time(r))（\(Fmt.remain(r))）")
                    }
                }
                if let s = u.seven {
                    info(String(format: "7日間リミット: %.0f%%", s.pct))
                    if let r = s.resetsAt {
                        info("　リセット \(Fmt.dayTime(r))（\(Fmt.remain(r))）")
                    }
                }
                for sc in u.scoped {
                    info(String(format: "%@ 週次リミット: %.0f%%", sc.name, sc.limit.pct))
                    if let r = sc.limit.resetsAt {
                        info("　リセット \(Fmt.dayTime(r))（\(Fmt.remain(r))）")
                    }
                }
            }
            if let newest = usages.map({ $0.fetchedAt }).max() {
                menu.addItem(.separator())
                info("データ取得: \(Fmt.clockF.string(from: newest))")
            }
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: panel.isVisible ? "ウィジェットを隠す" : "ウィジェットを表示",
            action: #selector(toggleWidget), keyEquivalent: "w"
        )
        toggle.target = self
        menu.addItem(toggle)

        let reload = NSMenuItem(title: "キャッシュを再読込", action: #selector(forceRefresh), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "ログイン時に自動起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LaunchAgent.isEnabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    // MARK: Overlay panel

    private func setupPanel() {
        var origin: NSPoint
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            origin = NSPoint(x: vf.midX - widgetSize.width / 2,
                             y: vf.maxY - widgetSize.height - 6)
        } else {
            origin = NSPoint(x: 200, y: 600)
        }
        if let x = defaults.object(forKey: "widgetX") as? Double,
           let y = defaults.object(forKey: "widgetY") as? Double {
            let saved = NSPoint(x: x, y: y)
            let onScreen = NSScreen.screens.contains {
                $0.frame.insetBy(dx: -20, dy: -20)
                    .contains(NSRect(origin: saved, size: widgetSize))
            }
            if onScreen { origin = saved }
        }

        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: widgetSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        usageView = UsageView(frame: NSRect(origin: .zero, size: widgetSize))
        panel.contentView = usageView

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification, object: panel
        )
    }

    @objc private func panelMoved() {
        defaults.set(Double(panel.frame.origin.x), forKey: "widgetX")
        defaults.set(Double(panel.frame.origin.y), forKey: "widgetY")
    }

    @objc private func toggleWidget() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        defaults.set(panel.isVisible, forKey: "widgetVisible")
    }

    // MARK: Notifications

    private func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.notificationsAvailable = granted
        }
    }

    private func notify(title: String, body: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Keys are per account so two accounts' windows cannot dedupe each other
    /// away. The default account keeps its original keys, so the "already
    /// notified" state written by earlier builds still applies.
    private func scheduleResetNotifications(for usage: Usage) {
        let suffix = usage.isDefault ? "" : "-\(usage.label)"
        let who = usages.count > 1 ? "\(usage.label) の" : ""
        scheduleResetNotification(name: "\(who)5時間", key: "notifiedReset5\(suffix)",
                                  resetsAt: usage.five?.resetsAt)
        scheduleResetNotification(name: "\(who)7日間", key: "notifiedReset7\(suffix)",
                                  resetsAt: usage.seven?.resetsAt)
        for sc in usage.scoped {
            scheduleResetNotification(name: "\(who)\(sc.name) 週次",
                                      key: "notifiedResetScoped:\(sc.name)\(suffix)",
                                      resetsAt: sc.limit.resetsAt)
        }
    }

    private func scheduleResetNotification(name: String, key: String, resetsAt: Date?) {
        resetTimers[key]?.invalidate()
        resetTimers[key] = nil

        guard let resetsAt else { return }
        let epoch = resetsAt.timeIntervalSince1970
        guard defaults.double(forKey: key) != epoch else { return }

        let fire = { [weak self] in
            guard let self, self.defaults.double(forKey: key) != epoch else { return }
            self.defaults.set(epoch, forKey: key)
            self.notify(title: "Claude Code", body: "\(name)リミットがリセットされました")
        }

        let interval = resetsAt.timeIntervalSinceNow
        if interval <= 0 {
            fire()
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.resetTimers[key] = nil
            fire()
        }
        resetTimers[key] = timer
    }

    // MARK: Refresh

    @objc private func forceRefresh() {
        refresh(force: true)
    }

    private func refresh(force: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fetched = UsageFetcher.all()
            DispatchQueue.main.async {
                guard let self else { return }
                self.usages = fetched
                self.statusItem.button?.attributedTitle = self.makeTitle(self.primary)
                self.statusItem.button?.toolTip = self.tooltip()
                self.usageView.usages = fetched
                // Accounts and per-model caps both come and go, so let the
                // resize guard decide rather than watching the account count.
                self.resizePanel()
                for u in fetched { self.scheduleResetNotifications(for: u) }
            }
        }
    }

    /// An account appearing or disappearing changes the panel height. Keep the
    /// top edge where the user put it so the widget grows downward instead of
    /// jumping — panel coordinates are bottom-left, hence the origin shift.
    private func resizePanel() {
        let size = widgetSize
        var frame = panel.frame
        guard frame.size != size else { return }
        frame.origin.y += frame.size.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        usageView.frame = NSRect(origin: .zero, size: size)
        panelMoved()
    }

    private func tooltip() -> String {
        guard !usages.isEmpty else { return "Claude Code の使用状況を取得できません" }
        var lines: [String] = []
        for u in usages {
            if usages.count > 1 {
                lines.append(u.email.isEmpty ? u.label : "\(u.label)（\(u.email)）")
            }
            if let f = u.five {
                var l = String(format: "5時間リミット: %.0f%%", f.pct)
                if let r = f.resetsAt { l += "（リセット \(Fmt.time(r))）" }
                lines.append(l)
            }
            if let s = u.seven {
                var l = String(format: "7日間リミット: %.0f%%", s.pct)
                if let r = s.resetsAt { l += "（リセット \(Fmt.dayTime(r))）" }
                lines.append(l)
            }
            for sc in u.scoped {
                var l = String(format: "%@ 週次リミット: %.0f%%", sc.name, sc.limit.pct)
                if let r = sc.limit.resetsAt { l += "（リセット \(Fmt.dayTime(r))）" }
                lines.append(l)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Login item

    @objc private func toggleLoginItem() {
        do {
            if LaunchAgent.isEnabled {
                try LaunchAgent.disable()
            } else {
                try LaunchAgent.enable()
                // Hand over to the instance launchd starts, so KeepAlive
                // covers this session too and only one icon remains.
                if try LaunchAgent.bootstrap() { NSApp.terminate(nil) }
            }
        } catch {
            NSLog("login item toggle failed: \(error)")
        }
    }
}

// MARK: - Login item (launchd)

/// Auto-start is a LaunchAgent in ~/Library/LaunchAgents, not SMAppService.
/// The bundle is ad-hoc signed and replaced in place by build.sh, and the
/// SMAppService registration did not survive that: after the 2026-10-12 reboot
/// the app never came back. launchd also relaunches the app when it crashes or
/// is killed (KeepAlive on unsuccessful exit); a normal 終了 stays quit.
enum LaunchAgent {
    static let label = "com.shino3.claude-usage-widget"
    static let stderrPath = "/tmp/claude-usage-widget.err"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var domain: String { "gui/\(getuid())" }
    static var service: String { "\(domain)/\(label)" }

    /// Enabled means the plist exists; that is all launchd looks at on login.
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// launchd currently has the agent loaded (running or not).
    static var isLoaded: Bool { launchctl(["print", service]).status == 0 }

    /// PID of the instance launchd manages, nil when it is not running.
    static var managedPID: pid_t? {
        for line in launchctl(["print", service]).output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = "), let pid = pid_t(t.dropFirst("pid = ".count)) { return pid }
        }
        return nil
    }

    /// Writes the plist pointing at this executable. Does not load it.
    static func enable() throws {
        guard let exe = Bundle.main.executablePath else { throw Failure("executable path unknown") }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardErrorPath": stderrPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        // A leftover `launchctl disable` would make launchd skip the plist at login.
        _ = launchctl(["enable", service])
    }

    /// Loads the agent now, which starts the app (RunAtLoad).
    /// Returns false when it was already loaded.
    @discardableResult
    static func bootstrap() throws -> Bool {
        if isLoaded { return false }
        let r = launchctl(["bootstrap", domain, plistURL.path])
        guard r.status == 0 else {
            throw Failure("launchctl bootstrap failed (\(r.status)): \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return true
    }

    /// Removes the plist only. A loaded agent stays loaded until logout;
    /// booting it out would kill the instance the user is looking at.
    static func disable() throws {
        guard isEnabled else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// `ClaudeUsageWidget --enable-login-item` and friends: manage the LaunchAgent
/// from a terminal (build.sh and the README use these) and exit without UI.
enum LoginItemCLI {
    static let usage = "usage: ClaudeUsageWidget [--enable-login-item | --disable-login-item | --login-item-status]"

    static func run(_ flag: String) -> Int32 {
        do {
            switch flag {
            case "--enable-login-item":
                try LaunchAgent.enable()
                // An instance started by hand would otherwise sit next to the launchd one.
                let managed = LaunchAgent.managedPID
                let bid = Bundle.main.bundleIdentifier ?? ""
                for a in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                where a.processIdentifier != getpid() && a.processIdentifier != managed {
                    kill(a.processIdentifier, SIGTERM)
                }
                let started = try LaunchAgent.bootstrap()
                print("login item enabled: \(LaunchAgent.plistURL.path)"
                      + (started ? " (started)" : " (already loaded)"))
            case "--disable-login-item":
                try LaunchAgent.disable()
                print("login item disabled"
                      + (LaunchAgent.isLoaded ? " (the running agent stays loaded until logout)" : ""))
            case "--login-item-status":
                print("enabled: \(LaunchAgent.isEnabled)  loaded: \(LaunchAgent.isLoaded)"
                      + "  pid: \(LaunchAgent.managedPID.map(String.init) ?? "-")")
            default:
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                return 64
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(flag): \(error)\n".utf8))
            return 1
        }
    }
}

// MARK: - Entry point

// Only `--flags` count; Launch Services may pass other arguments of its own.
if let flag = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
    exit(LoginItemCLI.run(flag))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
