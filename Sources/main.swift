import AppKit
import ServiceManagement

// MARK: - Model

struct Limit {
    let pct: Double
    let resetsAt: Date?
}

struct Usage {
    let five: Limit?
    let seven: Limit?
    let fetchedAt: Date
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

// MARK: - Usage fetcher (shares the statusline's cache file)

enum UsageFetcher {
    static let ttl: TimeInterval = 360

    static var cacheURL: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        }
        return base.appendingPathComponent("claude-usage-cache.json")
    }

    static func get(force: Bool) -> Usage? {
        if !force, let (json, age) = loadCache(), age < ttl {
            return parse(json)
        }
        if let fresh = fetchFromAPI() {
            return parse(fresh)
        }
        if let (json, _) = loadCache() {
            return parse(json) // stale fallback
        }
        return nil
    }

    private static func loadCache() -> (json: [String: Any], age: TimeInterval)? {
        guard let data = try? Data(contentsOf: cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let cachedAt = (obj["cached_at"] as? NSNumber)?.doubleValue ?? 0
        return (obj, Date().timeIntervalSince1970 - cachedAt)
    }

    private static func readAccessToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = obj["claudeAiOauth"] as? [String: Any], let t = oauth["accessToken"] as? String {
            return t
        }
        return (obj["accessToken"] as? String) ?? (obj["access_token"] as? String)
    }

    private static func fetchFromAPI() -> [String: Any]? {
        guard let token = readAccessToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 8

        var result: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            result = obj
        }.resume()
        sem.wait()

        if var obj = result {
            obj["cached_at"] = Date().timeIntervalSince1970
            if let data = try? JSONSerialization.data(withJSONObject: obj) {
                let dir = cacheURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            }
        }
        return result
    }

    private static func parse(_ json: [String: Any]) -> Usage {
        let cachedAt = (json["cached_at"] as? NSNumber)?.doubleValue
        return Usage(
            five: limit(json["five_hour"]),
            seven: limit(json["seven_day"]),
            fetchedAt: cachedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
        )
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
    var usage: Usage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()

        drawRow(y: 10, label: "5h", limit: usage?.five,
                resetText: (usage?.five?.resetsAt).map(Fmt.time) ?? "")
        drawRow(y: 34, label: "7d", limit: usage?.seven,
                resetText: (usage?.seven?.resetsAt).map(Fmt.day) ?? "")
    }

    private func drawRow(y: CGFloat, label: String, limit: Limit?, resetText: String) {
        let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let dim = NSColor(calibratedWhite: 1.0, alpha: 0.55)

        (label as NSString).draw(at: NSPoint(x: 12, y: y + 1),
                                 withAttributes: [.font: labelFont, .foregroundColor: dim])

        let w = bounds.width
        let resetX = w - 66
        let pctRight = w - 74
        let barX: CGFloat = 38
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
    private var usage: Usage?
    private var timer: Timer?

    private let widgetSize = NSSize(width: 320, height: 60)
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()

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
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let dimAttrs: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let t = NSMutableAttributedString()

        func pctAttrs(_ pct: Double) -> [NSAttributedString.Key: Any] {
            let c: NSColor = pct >= 80 ? .systemRed : (pct >= 50 ? .systemOrange : .labelColor)
            return [.font: font, .foregroundColor: c]
        }

        guard let u = usage, u.five != nil || u.seven != nil else {
            t.append(NSAttributedString(string: "CC --", attributes: dimAttrs))
            return t
        }
        if let f = u.five {
            t.append(NSAttributedString(string: "5h ", attributes: dimAttrs))
            t.append(NSAttributedString(string: String(format: "%.0f%%", f.pct),
                                        attributes: pctAttrs(f.pct)))
        }
        if let s = u.seven {
            if t.length > 0 { t.append(NSAttributedString(string: "  ", attributes: dimAttrs)) }
            t.append(NSAttributedString(string: "7d ", attributes: dimAttrs))
            t.append(NSAttributedString(string: String(format: "%.0f%%", s.pct),
                                        attributes: pctAttrs(s.pct)))
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

        if let u = usage {
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
            menu.addItem(.separator())
            info("データ取得: \(Fmt.clockF.string(from: u.fetchedAt))")
        } else {
            info("使用状況を取得できません")
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: panel.isVisible ? "ウィジェットを隠す" : "ウィジェットを表示",
            action: #selector(toggleWidget), keyEquivalent: "w"
        )
        toggle.target = self
        menu.addItem(toggle)

        let reload = NSMenuItem(title: "今すぐ更新", action: #selector(forceRefresh), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "ログイン時に自動起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
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

    // MARK: Refresh

    @objc private func forceRefresh() {
        refresh(force: true)
    }

    private func refresh(force: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = UsageFetcher.get(force: force)
            DispatchQueue.main.async {
                guard let self else { return }
                self.usage = usage
                self.statusItem.button?.attributedTitle = self.makeTitle(usage)
                self.statusItem.button?.toolTip = self.tooltip(usage)
                self.usageView.usage = usage
            }
        }
    }

    private func tooltip(_ u: Usage?) -> String {
        guard let u else { return "Claude Code の使用状況を取得できません" }
        var lines: [String] = []
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
        return lines.joined(separator: "\n")
    }

    // MARK: Login item

    @objc private func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            NSLog("login item toggle failed: \(error)")
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
