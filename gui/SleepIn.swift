import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI

struct TimerEvent: Decodable {
    let status: String
    let deadline: Double?
    let message: String?
    let lid_closed: Bool?
    let lid_awake: Bool?
}

extension Color {
    static let moon = Color(red: 0.42, green: 0.42, blue: 0.95)
    static let moonText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.66, green: 0.66, blue: 1, alpha: 1)
            : NSColor(red: 0.33, green: 0.32, blue: 0.84, alpha: 1)
    })
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
}

enum DurationText {
    static let presets = [(1800, "30m"), (3600, "1h"), (7200, "2h"), (14400, "4h"), (28800, "8h")]
    static let maximum = 604800

    /// Accepts minutes (90), h:mm (1:30), 1h30, or unit forms such as 1h30m and 45s.
    static func parse(_ input: String) -> Int? {
        let text = input.lowercased().filter { !$0.isWhitespace }
        let range = NSRange(text.startIndex..., in: text)
        func groups(_ pattern: String) -> [Double]? {
            guard let regex = try? NSRegularExpression(pattern: "^\(pattern)$"),
                  let match = regex.firstMatch(in: text, range: range) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).flatMap { Double(text[$0]) } }
        }
        let number = "([0-9]+(?:\\.[0-9]+)?)"
        var total = 0.0
        if let parts = groups("([0-9]+):([0-5][0-9])") {
            total = parts[0] * 3600 + parts[1] * 60
        } else if let parts = groups(number) {
            total = parts[0] * 60
        } else if let parts = groups(number + "h([0-9]+)") {
            total = parts[0] * 3600 + parts[1] * 60
        } else if groups("(?:[0-9]+(?:\\.[0-9]+)?[hms])+") != nil,
                  let regex = try? NSRegularExpression(pattern: number + "([hms])") {
            for match in regex.matches(in: text, range: range) {
                guard let amount = Range(match.range(at: 1), in: text).flatMap({ Double(text[$0]) }),
                      let unit = Range(match.range(at: 2), in: text).map({ text[$0] }) else { return nil }
                total += amount * (unit == "h" ? 3600 : unit == "m" ? 60 : 1)
            }
        } else {
            return nil
        }
        guard total.isFinite, total >= 1, total <= Double(maximum) else { return nil }
        return Int(total.rounded(.up))
    }

    static func parts(_ seconds: Int) -> [(value: String, unit: String)] {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        var parts: [(String, String)] = []
        if hours > 0 {
            parts = [(String(hours), "h"), (String(format: "%02d", minutes), "m")]
        } else if minutes > 0 {
            parts = [(String(minutes), "m")]
        }
        if rest > 0 { parts.append((parts.isEmpty ? String(rest) : String(format: "%02d", rest), "s")) }
        return parts
    }

    static func compact(_ seconds: Int) -> String {
        parts(seconds).map { $0.value + $0.unit }.joined(separator: " ")
    }

    static func styled(_ seconds: Int) -> Text {
        let parts = parts(seconds)
        return parts.enumerated().reduce(Text(verbatim: "")) { text, item in
            let gap = item.offset < parts.count - 1 ? " " : ""
            return text
                + Text(verbatim: item.element.value)
                    .font(.system(size: 58, weight: .light, design: .rounded).monospacedDigit())
                + Text(verbatim: item.element.unit + gap)
                    .font(.system(size: 22, design: .rounded))
                    .foregroundStyle(.secondary)
        }
    }

    static func countdown(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    static func spoken(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(seconds)) ?? ""
    }

    static func clock(_ date: Date, from now: Date) -> String {
        date.timeIntervalSince(now) >= 20 * 3600
            ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : date.formatted(date: .omitted, time: .shortened)
    }
}

final class TimerModel: ObservableObject {
    enum Phase { case idle, starting, running, stopping }

    struct Banner: Equatable {
        enum Kind { case done, note, error }
        let kind: Kind
        let text: String
    }

    @Published var seconds: Int
    @Published var lidClosed = UserDefaults.standard.bool(forKey: "lidClosed") {
        didSet { UserDefaults.standard.set(lidClosed, forKey: "lidClosed") }
    }
    @Published private(set) var editing = false
    @Published var draft = "" { didSet { draftInvalid = false } }
    @Published private(set) var draftInvalid = false
    @Published var banner: Banner?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var deadline: Date?
    @Published private(set) var now = Date()
    @Published private(set) var notice: String?
    @Published private(set) var activeLidClosed = false
    @Published private(set) var lidAwake = false

    private var startedAt: Date?
    private var process: Process?
    private var ticker: Timer?
    private var finalEvent: TimerEvent?
    private var cancelled = false

    // The timer is the sleep-in command that ships inside the app.
    private static let command = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sleep-in")
    // An explicit isolated state directory allows safe local verification.
    private static let stateArguments = ProcessInfo.processInfo.environment["SLEEP_IN_STATE_DIR"]
        .map { ["--state-dir", $0] } ?? []
    private static let lidDaemon = SMAppService.daemon(plistName: "io.github.qwertyu-alex.sleep-in.lid-daemon.plist")

    init() {
        let saved = UserDefaults.standard.integer(forKey: "lastDuration")
        seconds = (1...DurationText.maximum).contains(saved) ? saved : 7200
    }

    var isBusy: Bool { phase != .idle }
    var isRunning: Bool { phase == .running || phase == .stopping }

    var remaining: Int {
        guard let deadline else { return seconds }
        return max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    var progress: Double {
        guard let deadline, let startedAt else { return 1 }
        let total = deadline.timeIntervalSince(startedAt)
        return total > 0 ? min(1, max(0, deadline.timeIntervalSince(now) / total)) : 0
    }

    var windowTitle: String {
        isRunning && deadline != nil ? "Sleep In — \(DurationText.countdown(remaining))" : "Sleep In"
    }

    func step(_ direction: Int, by size: Int) {
        guard phase == .idle, !editing else { return }
        let next = direction > 0 ? (seconds / size + 1) * size : ((seconds + size - 1) / size - 1) * size
        seconds = min(DurationText.maximum, max(300, next))
    }

    func choose(_ value: Int) {
        cancelEdit()
        seconds = value
    }

    func beginEditing(with text: String = "") {
        guard phase == .idle else { return }
        draft = text
        editing = true
    }

    /// Applies the typed duration. Returns false and keeps editing when it can't be read.
    @discardableResult
    func commitEdit() -> Bool {
        guard editing else { return true }
        if draft.trimmingCharacters(in: .whitespaces).isEmpty {
            editing = false
            return true
        }
        guard let value = DurationText.parse(draft) else {
            draftInvalid = true
            return false
        }
        seconds = value
        editing = false
        return true
    }

    func cancelEdit() {
        editing = false
        draftInvalid = false
    }

    func endEditingOnBlur() {
        if editing && !commitEdit() { cancelEdit() }
    }

    /// Window-level shortcuts. Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.isDisjoint(with: [.command, .control, .option]) { return false }
        if editing {
            if event.keyCode == 53 { cancelEdit(); return true }
            return false
        }
        guard phase == .idle else { return false }
        switch event.keyCode {
        case 126: step(1, by: flags.contains(.shift) ? 3600 : 900); return true
        case 125: step(-1, by: flags.contains(.shift) ? 3600 : 900); return true
        case 36, 76: start(); return true
        default:
            guard let key = event.charactersIgnoringModifiers, key.count == 1,
                  key.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) && $0.isASCII }) else { return false }
            beginEditing(with: key)
            return true
        }
    }

    /// Lid-closed mode uses a background helper that macOS asks the user to allow once.
    private func lidDaemonReady() -> Bool {
        let daemon = Self.lidDaemon
        var failure: Error?
        if daemon.status != .enabled {
            do { try daemon.register() } catch { failure = error }
        }
        switch daemon.status {
        case .enabled:
            return true
        case .requiresApproval:
            banner = Banner(kind: .note, text: "Turn on Sleep In under Login Items & Extensions in System Settings, then press Start again. Lid-closed mode needs this once.")
            SMAppService.openSystemSettingsLoginItems()
        default:
            banner = Banner(kind: .error, text: "Couldn't set up lid-closed mode: \(failure?.localizedDescription ?? "the helper is missing. Rebuild Sleep In.")")
        }
        return false
    }

    func start() {
        guard phase == .idle, commitEdit() else { return }
        UserDefaults.standard.set(seconds, forKey: "lastDuration")
        banner = nil
        if lidClosed && !lidDaemonReady() { return }
        let child = Process()
        let output = Pipe()
        child.executableURL = Self.command
        var arguments = ["\(seconds)s", "--json", "--gui-parent", String(getpid())]
        if lidClosed {
            arguments += ["--lid-closed", "--lid-helper",
                          Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SleepInLidClient").path]
        }
        child.arguments = arguments + Self.stateArguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = output
        notice = nil
        deadline = nil
        finalEvent = nil
        cancelled = false
        activeLidClosed = lidClosed
        lidAwake = false
        do {
            try child.run()
        } catch {
            banner = Banner(kind: .error, text: "Couldn't start the timer: \(error.localizedDescription)")
            return
        }
        phase = .starting
        process = child
        // Read off the main thread so the window remains responsive.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            var diagnostics = ""
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if let event = try? JSONDecoder().decode(TimerEvent.self, from: line) {
                        DispatchQueue.main.async { self?.receive(event) }
                    } else if let text = String(data: line, encoding: .utf8) {
                        diagnostics += text + "\n"
                    }
                }
            }
            if let tail = String(data: buffer, encoding: .utf8) { diagnostics += tail }
            child.waitUntilExit()
            try? handle.close()
            let result = diagnostics
            DispatchQueue.main.async {
                self?.finished(child, diagnostics: result)
            }
        }
    }

    private func receive(_ event: TimerEvent) {
        guard event.status == "running" else {
            finalEvent = event
            return
        }
        guard !cancelled, let timestamp = event.deadline else { return }
        now = Date()
        // Later running events carry a new deadline after time is added.
        deadline = Date(timeIntervalSince1970: timestamp)
        activeLidClosed = event.lid_closed ?? false
        lidAwake = event.lid_awake ?? false
        guard phase == .starting else { return }
        phase = .running
        startedAt = now
        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.now = Date() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func finished(_ child: Process, diagnostics: String) {
        guard process === child else { return }
        ticker?.invalidate()
        ticker = nil
        process = nil
        deadline = nil
        startedAt = nil
        notice = nil
        phase = .idle
        let time = Date().formatted(date: .omitted, time: .shortened)
        if cancelled && child.terminationStatus == 0 {
            banner = nil
        } else if finalEvent?.status == "cancelled" {
            banner = Banner(kind: .note, text: "The timer was cancelled from Terminal.")
        } else if child.terminationStatus == 0, finalEvent?.status == "completed" {
            banner = Banner(kind: .done, text: "Slept at \(time)")
        } else {
            let text = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? finalEvent?.message ?? ""
                : diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("Use --replace") {
                banner = Banner(kind: .error, text: "A timer is already running in Terminal. Stop it with sleep-in cancel, then try again.")
            } else {
                banner = Banner(kind: .error, text: text.isEmpty ? "The timer stopped unexpectedly. Please try again." : String(text.prefix(300)))
            }
        }
    }

    func extend(by extra: Int) {
        guard phase == .running else { return }
        notice = nil
        let child = Process()
        let output = Pipe()
        child.executableURL = Self.command
        child.arguments = ["extend", "\(extra)s"] + Self.stateArguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = output
        // The running timer reports the new deadline itself; only failures need handling here.
        child.terminationHandler = { [weak self] finished in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard finished.terminationStatus != 0 else { return }
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self?.notice = text.isEmpty ? "Couldn't add time. Please try again." : text
            }
        }
        do {
            try child.run()
        } catch {
            notice = "Couldn't add time: \(error.localizedDescription)"
        }
    }

    func cancel() {
        guard let process else { return }
        cancelled = true
        phase = .stopping
        if process.isRunning { process.terminate() }
    }
}

struct FillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, chip(selected: Bool), round }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        FillButton(configuration: configuration, kind: kind)
    }
}

private struct FillButton: View {
    let configuration: ButtonStyle.Configuration
    let kind: FillButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var shape: RoundedRectangle {
        switch kind {
        case .primary, .secondary: return RoundedRectangle(cornerRadius: 10, style: .continuous)
        case .chip: return RoundedRectangle(cornerRadius: 14, style: .continuous)
        case .round: return RoundedRectangle(cornerRadius: 17, style: .continuous)
        }
    }

    private var height: CGFloat {
        switch kind {
        case .primary, .secondary: return 40
        case .chip: return 28
        case .round: return 34
        }
    }

    private var font: Font {
        switch kind {
        case .primary, .secondary: return .system(size: 14, weight: .semibold)
        case .chip: return .system(size: 12.5, weight: .medium)
        case .round: return .system(size: 15, weight: .medium)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .chip(selected: true): return .moonText
        default: return .primary
        }
    }

    private var fill: Color {
        let pressed = configuration.isPressed && isEnabled
        switch kind {
        case .primary: return .moon.opacity(pressed ? 0.8 : 1)
        case .chip(selected: true): return .moon.opacity(0.22)
        default: return .primary.opacity(pressed ? 0.16 : hovering && isEnabled ? 0.12 : 0.075)
        }
    }

    private var border: Color {
        if case .chip(selected: true) = kind { return .moon.opacity(0.45) }
        return .clear
    }

    private var isRound: Bool {
        if case .round = kind { return true }
        return false
    }

    var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .frame(width: isRound ? height : nil, height: height)
            .frame(maxWidth: isRound ? nil : .infinity)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(isRound && configuration.isPressed ? 0.94 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Transparent layer over the duration: scroll or drag to change it, click to type.
final class ScrubberView: NSView {
    var onStep: ((Int) -> Void)?
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var scrolled: CGFloat = 0
    private var dragOrigin: CGFloat?
    private var dragged = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        // Moving fingers or the wheel up adds time, whatever the scroll direction setting.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            if delta != 0 { onStep?(delta > 0 ? 1 : -1) }
            return
        }
        scrolled += delta
        while abs(scrolled) >= 14 {
            onStep?(scrolled > 0 ? 1 : -1)
            scrolled -= scrolled > 0 ? 14 : -14
        }
        if event.phase == .ended || event.phase == .cancelled { scrolled = 0 }
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow.y
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let steps = Int((event.locationInWindow.y - origin) / 8)
        guard steps != 0 else { return }
        dragged = true
        for _ in 0..<abs(steps) { onStep?(steps > 0 ? 1 : -1) }
        dragOrigin = origin + CGFloat(steps * 8)
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil && !dragged { onClick?() }
        dragOrigin = nil
    }
}

struct TimeScrubber: NSViewRepresentable {
    let onStep: (Int) -> Void
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ScrubberView {
        let view = ScrubberView()
        view.toolTip = "Scroll, drag, or click to type a time"
        return view
    }

    func updateNSView(_ view: ScrubberView, context: Context) {
        view.onStep = onStep
        view.onClick = onClick
        view.onHover = onHover
    }
}

struct BannerView: View {
    let banner: TimerModel.Banner
    let dismiss: () -> Void

    var body: some View {
        let tint: Color = banner.kind == .error ? .orange : banner.kind == .done ? .green : .secondary
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : banner.kind == .done ? "checkmark" : "info.circle")
            Text(banner.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 12))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct SetupView: View {
    @ObservedObject var model: TimerModel
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .padding(.bottom, 8)
            }

            HStack(spacing: 0) {
                Button { model.step(-1, by: 900) } label: { Image(systemName: "minus") }
                    .buttonStyle(FillButtonStyle(kind: .round))
                    .buttonRepeatBehavior(.enabled)
                    .accessibilityLabel("Less time")
                duration
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                Button { model.step(1, by: 900) } label: { Image(systemName: "plus") }
                    .buttonStyle(FillButtonStyle(kind: .round))
                    .buttonRepeatBehavior(.enabled)
                    .accessibilityLabel("More time")
            }
            .disabled(model.isBusy)
            .padding(.top, 8)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let end = context.date.addingTimeInterval(TimeInterval(model.seconds))
                (Text("Mac sleeps at ").foregroundStyle(.secondary)
                    + Text(DurationText.clock(end, from: context.date)).fontWeight(.medium).foregroundStyle(.primary))
                    .font(.system(size: 13))
            }
            .padding(.top, 4)

            Text(model.editing ? (model.draftInvalid ? "Try 90, 1:30, or 1h30" : "Type 90, 1:30, or 1h30 · ↩ to set") : "")
                .font(.system(size: 11))
                .foregroundStyle(model.draftInvalid ? Color.orange : Color.tertiaryText)
                .frame(height: 14)
                .padding(.top, 2)

            HStack(spacing: 6) {
                ForEach(DurationText.presets, id: \.0) { value, label in
                    Button(label) { model.choose(value) }
                        .buttonStyle(FillButtonStyle(kind: .chip(selected: model.seconds == value && !model.editing)))
                        .accessibilityLabel("Set duration to \(DurationText.spoken(value))")
                }
            }
            .disabled(model.isBusy)
            .padding(.top, 22)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep awake with lid closed", isOn: $model.lidClosed)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Text("Charger only · approve with Touch ID or your password")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.isBusy)
            .padding(.top, 16)

            Button(action: model.start) {
                HStack(spacing: 8) {
                    Text(model.phase == .starting ? "Starting…" : "Start")
                    Text(verbatim: "↩").fontWeight(.medium).opacity(0.55)
                }
            }
            .buttonStyle(FillButtonStyle(kind: .primary))
            .disabled(model.isBusy)
            .padding(.top, 18)

            if model.phase == .starting {
                Button("Cancel", action: model.cancel)
                    .buttonStyle(FillButtonStyle(kind: .secondary))
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var duration: some View {
        if model.editing {
            TextField("Duration", text: $model.draft, prompt: Text(DurationText.compact(model.seconds)))
                .textFieldStyle(.plain)
                .font(.system(size: 46, weight: .light, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                .onSubmit { model.commitEdit() }
                .onAppear { fieldFocused = true }
                .onChange(of: fieldFocused) { _, focused in
                    if focused {
                        // Focusing selects the text; keep a typed first digit and type after it.
                        DispatchQueue.main.async {
                            for case let editor as NSTextView in NSApp.windows.map(\.firstResponder) where editor.isFieldEditor {
                                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                            }
                        }
                    } else {
                        model.endEditingOnBlur()
                    }
                }
                .frame(height: 76)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.moon.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.moon, lineWidth: 1.5))
        } else {
            DurationText.styled(model.seconds)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .frame(height: 76)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering && !model.isBusy ? 0.04 : 0)))
                .animation(.easeOut(duration: 0.15), value: hovering)
                .overlay(TimeScrubber(
                    onStep: { model.step($0, by: 300) },
                    onClick: { hovering = false; model.beginEditing() },
                    onHover: { hovering = $0 }))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Duration")
                .accessibilityValue(DurationText.spoken(model.seconds))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.step(1, by: 900)
                    case .decrement: model.step(-1, by: 900)
                    @unknown default: break
                    }
                }
        }
    }
}

struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: 7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.moon, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
        }
        .padding(3.5)
    }
}

struct RunningView: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ProgressRing(progress: model.progress)
                VStack(spacing: 2) {
                    Text(DurationText.countdown(model.remaining))
                        .font(.system(size: 44, weight: .light, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.easeOut(duration: 0.16), value: model.remaining)
                        .accessibilityLabel("Time remaining: \(DurationText.spoken(model.remaining))")
                    if let deadline = model.deadline {
                        Text("Sleeps at \(DurationText.clock(deadline, from: model.now))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 208, height: 208)
            .padding(.top, 6)

            HStack(spacing: 6) {
                Button("+15 min") { model.extend(by: 900) }
                Button("+1 hour") { model.extend(by: 3600) }
            }
            .buttonStyle(FillButtonStyle(kind: .chip(selected: false)))
            .disabled(model.phase != .running)
            .padding(.top, 18)

            Button(model.phase == .stopping ? "Cancelling…" : "Cancel", action: model.cancel)
                .buttonStyle(FillButtonStyle(kind: .secondary))
                .disabled(model.phase != .running)
                .padding(.top, 18)

            Text(model.notice ?? (model.activeLidClosed
                 ? (model.lidAwake ? "Lid may be closed · keep charger connected" : "Lid sleep allowed · connect charger to stay awake")
                 : "Display may turn off · keep the lid open"))
                .font(.system(size: 11))
                .foregroundStyle(model.notice == nil ? Color.tertiaryText : .orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }
}

struct TimerView: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                Text("Sleep In")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep In")

            Group {
                if model.isRunning {
                    RunningView(model: model)
                } else {
                    SetupView(model: model)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.moon)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = TimerModel()
    // Release builds name an update feed; Sparkle checks it daily and installs updates when the app quits.
    private let updates = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil
        ? nil : SPUStandardUpdaterController(updaterDelegate: nil, userDriverDelegate: nil)
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var titleUpdates: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sleep In", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let updates {
            appMenu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
                .target = updates
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sleep In", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        windowItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu

        let content = NSHostingView(rootView: TimerView(model: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Sleep In"
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
            return self.model.handleKey(event) ? nil : event
        }
        titleUpdates = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let window = self.window else { return }
                let title = self.model.windowTitle
                if window.title != title { window.title = title }
            }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isBusy, let window else { return .terminateNow }
        guard window.attachedSheet == nil else { return .terminateCancel }
        window.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cancel the timer and quit?"
        alert.informativeText = "Sleep In has to stay open to keep your Mac awake. To keep the timer running, minimize the window instead."
        alert.addButton(withTitle: "Keep Timer")
        alert.addButton(withTitle: "Cancel Timer and Quit").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            NSApp.reply(toApplicationShouldTerminate: response == .alertSecondButtonReturn)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
