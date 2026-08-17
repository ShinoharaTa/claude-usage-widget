import AppKit
import ServiceManagement
import UserNotifications

// MARK: - Model

/// How far out a reset is, and therefore how it should be written.
enum ResetStyle {
    case clock     // hours away — the wall clock says enough
    case calendar  // days away — needs the date
}

/// One rate-limit row. `label` is the compact name shown in the menu bar and
/// overlay ("5h", "7d", or a per-model cap like "fable"); `severity` is the
/// API's own grading, which we prefer over local percentage thresholds.
struct Limit {
    let label: String
    let title: String
    let pct: Double
    let resetsAt: Date?
    let severity: String?
    let style: ResetStyle
    /// Stable UserDefaults key for reset-notification dedup across restarts.
    let notifyKey: String
}

struct Usage {
    let limits: [Limit]
    let fetchedAt: Date

    /// Matches the statusline script's threshold: past this the fetcher is
    /// probably wedged, and the numbers are confidently wrong.
    static let staleAfter: TimeInterval = 900

    var age: TimeInterval { max(0, Date().timeIntervalSince(fetchedAt)) }
    var isStale: Bool { age > Usage.staleAfter }
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

    /// Compact reset text for the overlay: the clock for the 5h window, the
    /// date for anything a week out.
    static func short(_ limit: Limit) -> String {
        guard let r = limit.resetsAt else { return "" }
        return limit.style == .clock ? time(r) : day(r)
    }

    /// Full reset text for the detail menu and tooltip.
    static func full(_ limit: Limit) -> String {
        guard let r = limit.resetsAt else { return "" }
        return limit.style == .clock ? time(r) : dayTime(r)
    }
}

/// The API grades every limit, so prefer its verdict — that keeps the widget,
/// the menu bar and the statusline script telling the same story. Fallback
/// thresholds mirror `color_for_pct` in statusline-command.sh.
func colorFor(_ limit: Limit) -> NSColor {
    switch limit.severity {
    case "critical": return .systemRed
    case "warning": return .systemYellow
    case "normal": return .systemGreen
    default:
        if limit.pct >= 90 { return .systemRed }
        if limit.pct >= 70 { return .systemYellow }
        return .systemGreen
    }
}

/// Menu-bar text stays in the default color until a limit actually wants
/// attention — a permanently green menu bar reads as decoration.
func menuBarColorFor(_ limit: Limit) -> NSColor {
    switch limit.severity {
    case "critical": return .systemRed
    case "warning": return .systemOrange
    case "normal": return .labelColor
    default:
        if limit.pct >= 90 { return .systemRed }
        if limit.pct >= 70 { return .systemOrange }
        return .labelColor
    }
}

// MARK: - Usage reader (statusline cache only)

enum UsageFetcher {
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
        loadCache().map(parse)
    }

    private static func loadCache() -> [String: Any]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func parse(_ json: [String: Any]) -> Usage {
        let cachedAt = (json["cached_at"] as? NSNumber)?.doubleValue
        let rows = json["limits"] as? [[String: Any]] ?? []

        // `five_hour` / `seven_day` carry the percentages, but only the newer
        // `limits` array carries the API's severity grading for them.
        func severity(_ kind: String) -> String? {
            rows.first { $0["kind"] as? String == kind }?["severity"] as? String
        }

        var limits: [Limit] = []
        if let five = limit(json["five_hour"], label: "5h", title: "5時間リミット",
                            severity: severity("session"), style: .clock,
                            notifyKey: "notifiedReset5") {
            limits.append(five)
        }
        if let seven = limit(json["seven_day"], label: "7d", title: "7日間リミット",
                             severity: severity("weekly_all"), style: .calendar,
                             notifyKey: "notifiedReset7") {
            limits.append(seven)
        }
        limits.append(contentsOf: scoped(rows))

        return Usage(
            limits: limits,
            fetchedAt: cachedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
        )
    }

    /// Per-model weekly caps come and go with the plan and have no fixed key,
    /// so they are read out of the `limits` array. Mirrors the statusline
    /// script, which picks the same rows the same way.
    private static func scoped(_ rows: [[String: Any]]) -> [Limit] {
        rows.compactMap { row in
            guard row["kind"] as? String == "weekly_scoped" else { return nil }
            let scope = row["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = (model?["display_name"] as? String)
                ?? (scope?["surface"] as? String)
                ?? "model"
            let label = name.lowercased()
            return Limit(
                label: label,
                title: "\(label) 週次リミット",
                pct: (row["percent"] as? NSNumber)?.doubleValue ?? 0,
                resetsAt: (row["resets_at"] as? String).flatMap(parseISO),
                severity: row["severity"] as? String,
                style: .calendar,
                notifyKey: "notifiedResetScoped:\(label)"
            )
        }
    }

    private static func limit(
        _ any: Any?, label: String, title: String,
        severity: String?, style: ResetStyle, notifyKey: String
    ) -> Limit? {
        guard let d = any as? [String: Any] else { return nil }
        return Limit(
            label: label,
            title: title,
            pct: (d["utilization"] as? NSNumber)?.doubleValue ?? 0,
            resetsAt: (d["resets_at"] as? String).flatMap(parseISO),
            severity: severity,
            style: style,
            notifyKey: notifyKey
        )
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

    static let width: CGFloat = 240
    static let rowHeight: CGFloat = 24
    static let topPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 2
    static let staleRowHeight: CGFloat = 15

    /// Placeholder labels drawn when the cache is unreadable, so the widget
    /// keeps its familiar shape instead of collapsing to nothing.
    static let placeholderLabels = ["5h", "7d"]

    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let staleFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let dim = NSColor(calibratedWhite: 1.0, alpha: 0.55)

    static func height(rowCount: Int, stale: Bool) -> CGFloat {
        // No rows means the cache was unreadable and the placeholders get
        // drawn instead, so reserve room for those rather than for none.
        let rows = rowCount > 0 ? rowCount : placeholderLabels.count
        return topPadding + rowHeight * CGFloat(rows)
            + (stale ? staleRowHeight : 0) + bottomPadding
    }

    static func size(for usage: Usage?) -> NSSize {
        NSSize(width: width,
               height: height(rowCount: usage?.limits.count ?? 0,
                              stale: usage?.isStale ?? false))
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()

        let limits = usage?.limits ?? []
        let labels = limits.isEmpty ? Self.placeholderLabels : limits.map(\.label)
        let barX = barStart(labels: labels)

        var y = Self.topPadding
        if limits.isEmpty {
            for label in Self.placeholderLabels {
                drawRow(y: y, label: label, limit: nil, barX: barX)
                y += Self.rowHeight
            }
        } else {
            for limit in limits {
                drawRow(y: y, label: limit.label, limit: limit, barX: barX)
                y += Self.rowHeight
            }
        }

        if let u = usage, u.isStale {
            drawStaleRow(y: y + 1, age: u.age)
        }
    }

    /// Per-model labels ("fable") are wider than "5h"/"7d", so the bar starts
    /// after the widest label rather than at a fixed offset. Capped so a long
    /// model name cannot squeeze the bar out of existence.
    private func barStart(labels: [String]) -> CGFloat {
        let widest = labels
            .map { ($0 as NSString).size(withAttributes: [.font: Self.labelFont]).width }
            .max() ?? 0
        return 12 + min(widest.rounded(.up), 62) + 10
    }

    private func drawRow(y: CGFloat, label: String, limit: Limit?, barX: CGFloat) {
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        (label as NSString).draw(
            in: NSRect(x: 12, y: y + 1, width: barX - 22, height: 14),
            withAttributes: [.font: Self.labelFont, .foregroundColor: Self.dim,
                             .paragraphStyle: truncating]
        )

        let w = bounds.width
        let resetX = w - 66
        let pctRight = w - 74
        let barW = pctRight - 44 - barX
        let barRect = NSRect(x: barX, y: y + 2, width: barW, height: 12)

        NSColor(calibratedWhite: 1.0, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 6, yRadius: 6).fill()

        let pct = limit.map { min(max($0.pct, 0), 100) } ?? 0
        if let limit, pct > 0 {
            let fillW = max(barW * CGFloat(pct) / 100, 12)
            colorFor(limit).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: y + 2, width: fillW, height: 12),
                         xRadius: 6, yRadius: 6).fill()
        }

        let pctStr = limit != nil ? String(format: "%.0f%%", pct) : "--"
        let pctColor = limit.map(colorFor) ?? Self.dim
        let pctAttrs: [NSAttributedString.Key: Any] = [.font: Self.valueFont, .foregroundColor: pctColor]
        let pctSize = (pctStr as NSString).size(withAttributes: pctAttrs)
        (pctStr as NSString).draw(at: NSPoint(x: pctRight - pctSize.width, y: y + 1),
                                  withAttributes: pctAttrs)

        let resetText = limit.map(Fmt.short) ?? ""
        if !resetText.isEmpty {
            ("→" + resetText as NSString).draw(at: NSPoint(x: resetX, y: y + 1),
                                               withAttributes: [.font: Self.valueFont,
                                                                .foregroundColor: Self.dim])
        }
    }

    /// A frozen fetcher would otherwise show confident, wrong numbers forever.
    private func drawStaleRow(y: CGFloat, age: TimeInterval) {
        let text = "\(Int(age / 60))分前のデータ"
        (text as NSString).draw(at: NSPoint(x: 12, y: y),
                                withAttributes: [.font: Self.staleFont,
                                                 .foregroundColor: NSColor.systemOrange])
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var usageView: UsageView!
    private var usage: Usage?
    private var timer: Timer?
    private var resetTimers: [String: Timer] = [:]
    private var notificationsAvailable = false

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

        guard let u = usage, !u.limits.isEmpty else {
            t.append(NSAttributedString(string: "CC --", attributes: labelAttrs))
            return t
        }

        for limit in u.limits {
            if t.length > 0 { t.append(NSAttributedString(string: "  ", attributes: labelAttrs)) }
            t.append(NSAttributedString(string: limit.label + " ", attributes: labelAttrs))
            t.append(NSAttributedString(
                string: String(format: "%.0f%%", limit.pct),
                attributes: [.font: valueFont,
                             .foregroundColor: menuBarColorFor(limit),
                             .baselineOffset: -1]
            ))
        }
        if u.isStale {
            t.append(NSAttributedString(string: " ⚠", attributes: [
                .font: labelFont, .foregroundColor: NSColor.systemOrange, .baselineOffset: -1,
            ]))
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

        if let u = usage, !u.limits.isEmpty {
            for limit in u.limits {
                info(String(format: "%@: %.0f%%", limit.title, limit.pct))
                if let r = limit.resetsAt {
                    info("　リセット \(Fmt.full(limit))（\(Fmt.remain(r))）")
                }
            }
            menu.addItem(.separator())
            var fetched = "データ取得: \(Fmt.clockF.string(from: u.fetchedAt))"
            if u.isStale {
                fetched += "（\(Int(u.age / 60))分前・取得が止まっている可能性）"
            }
            info(fetched)
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

        let reload = NSMenuItem(title: "キャッシュを再読込", action: #selector(forceRefresh), keyEquivalent: "r")
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

    /// The panel grows and shrinks with the number of limits, so the remembered
    /// position is its *top* edge — storing the bottom-left origin would make
    /// the widget creep down the screen every time the row count changed.
    private func savedPlacement() -> (x: CGFloat, top: CGFloat)? {
        guard let x = defaults.object(forKey: "widgetX") as? Double else { return nil }
        if let top = defaults.object(forKey: "widgetTopY") as? Double {
            return (CGFloat(x), CGFloat(top))
        }
        // Builds before the resizable overlay stored the origin of a fixed
        // 60pt panel; recover the top edge from it once.
        if let y = defaults.object(forKey: "widgetY") as? Double {
            return (CGFloat(x), CGFloat(y) + 60)
        }
        return nil
    }

    private func setupPanel() {
        let size = UsageView.size(for: nil)
        var x: CGFloat
        var top: CGFloat
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            x = vf.midX - size.width / 2
            top = vf.maxY - 6
        } else {
            x = 200
            top = 600 + size.height
        }
        if let saved = savedPlacement() {
            let rect = NSRect(x: saved.x, y: saved.top - size.height,
                              width: size.width, height: size.height)
            let onScreen = NSScreen.screens.contains {
                $0.frame.insetBy(dx: -20, dy: -20).contains(rect)
            }
            if onScreen {
                x = saved.x
                top = saved.top
            }
        }

        panel = NSPanel(
            contentRect: NSRect(x: x, y: top - size.height, width: size.width, height: size.height),
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

        usageView = UsageView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = usageView

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification, object: panel
        )
    }

    /// Resize in place, keeping the top edge where the user parked it.
    private func layoutPanel(for usage: Usage?) {
        let size = UsageView.size(for: usage)
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        usageView.frame = NSRect(origin: .zero, size: size)
    }

    @objc private func panelMoved() {
        defaults.set(Double(panel.frame.origin.x), forKey: "widgetX")
        defaults.set(Double(panel.frame.maxY), forKey: "widgetTopY")
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

    /// A per-model weekly cap usually resets with the all-model window, so
    /// limits are grouped by reset moment and announced once per moment
    /// instead of once per limit.
    private func scheduleResetNotifications(for usage: Usage?) {
        resetTimers.values.forEach { $0.invalidate() }
        resetTimers.removeAll()
        guard let usage else { return }

        var groups: [Int: [Limit]] = [:]
        for limit in usage.limits {
            guard let r = limit.resetsAt else { continue }
            groups[Int(r.timeIntervalSince1970.rounded()), default: []].append(limit)
        }
        for (epoch, limits) in groups {
            scheduleResetNotification(epoch: epoch, limits: limits)
        }
    }

    private func scheduleResetNotification(epoch: Int, limits: [Limit]) {
        let stamp = Double(epoch)
        // Capture the defaults store rather than self: these closures outlive
        // the call inside a Timer, and holding self there would retain it.
        let defaults = self.defaults
        let unseen = { limits.contains { defaults.double(forKey: $0.notifyKey) != stamp } }
        guard unseen() else { return }

        let markSeen = { limits.forEach { defaults.set(stamp, forKey: $0.notifyKey) } }

        let interval = stamp - Date().timeIntervalSince1970
        if interval <= 0 {
            // The reset already happened — the cache was simply lagging behind
            // it. Announcing it now would be noise, so just record it.
            markSeen()
            return
        }

        let key = String(epoch)
        resetTimers[key] = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.resetTimers[key] = nil
            guard unseen() else { return }
            markSeen()
            let names = limits.map(\.label).joined(separator: " / ")
            self.notify(title: "Claude Code", body: "\(names) のリミットがリセットされました")
        }
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
                self.layoutPanel(for: usage)
                self.usageView.usage = usage
                self.scheduleResetNotifications(for: usage)
            }
        }
    }

    private func tooltip(_ u: Usage?) -> String {
        guard let u, !u.limits.isEmpty else { return "Claude Code の使用状況を取得できません" }
        var lines = u.limits.map { limit -> String in
            var l = String(format: "%@: %.0f%%", limit.title, limit.pct)
            if limit.resetsAt != nil { l += "（リセット \(Fmt.full(limit))）" }
            return l
        }
        if u.isStale {
            lines.append("※ \(Int(u.age / 60))分前のデータ（取得が止まっている可能性）")
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
