import Foundation

/// Reads the durable event log and reports, per signal episode, how long each
/// stage took. The questions this answers: which signal held breaks, and how
/// long after it ended did the menu bar catch up?
enum CallReport {

    private struct Event {
        let at: Date
        let kind: String      // signal | call | hold | linger | icon | audio | presence
        let detail: String
    }

    private struct Episode {
        var signal: String
        var on: Date
        var off: Date?
        var iconOn: Date?         // icon first showed a hold symbol
        var holdClear: Date?
        var iconOff: Date?        // icon returned to the counting symbol
        var linger: String?
        var app: String?
        var overlapped = false    // another signal was live at release
        var gated = false         // the user's toggle for this signal is off
    }

    private static let neutralIcons: Set<String> = ["circle.lefthalf.filled", "moon.zzz",
                                                    "pause.circle", "sunset", "eye"]

    static func run(callsOnly: Bool) {
        let events = load()
        guard !events.isEmpty else {
            print("No events yet at \(Trace.logURL.path).")
            print("Use the app for a while, then run this again.")
            return
        }
        let episodes = build(from: events).filter { !callsOnly || $0.signal == "micInUse" }

        print("Halftone diagnostics")
        print("log:    \(Trace.logURL.path)")
        print("window: \(stamp(events.first!.at)) to \(stamp(events.last!.at))  (\(events.count) events)")
        print("debug:  \(debugOn ? "on (verbose)" : "off (state changes only)")\n")

        guard !episodes.isEmpty else {
            print(callsOnly ? "No calls recorded in this window."
                            : "No hold episodes recorded in this window.")
            return
        }

        print(pad("signal", 15) + pad("start", 10) + rpad("held for", 9)
              + rpad("ON lag", 8) + rpad("OFF lag", 9) + rpad("linger", 8) + "  app")
        print(String(repeating: "-", count: 82))
        for e in episodes {
            let heldFor = e.off.map { $0.timeIntervalSince(e.on) }
            let onLag = e.gated ? nil : e.iconOn.map { $0.timeIntervalSince(e.on) }
            let offLag = (!e.gated && e.off != nil && e.iconOff != nil && !e.overlapped)
                ? e.iconOff!.timeIntervalSince(e.off!) : nil
            print(pad(e.signal + (e.gated ? " (off)" : ""), 15) + pad(clock(e.on), 10) + rpad(dur(heldFor), 9)
                  + rpad(dur(onLag), 8) + rpad(dur(offLag), 9)
                  + rpad(e.linger ?? "-", 8) + "  " + (e.app ?? "-"))
        }

        summary(episodes)

        print("""

        held for  the signal itself, on to off (a call's talk time)
        ON lag    signal on to the menu bar showing the hold icon
        OFF lag   signal off to the icon counting again. This is the wait you see.
        linger    the configured hold-after-activity that OFF lag mostly consists of
        "-" in OFF lag means another signal was still holding, or this signal's
        toggle is off ("(off)"), so the wait is not attributable to it.
        """)
    }

    private static func summary(_ episodes: [Episode]) {
        let bySignal = Dictionary(grouping: episodes, by: \.signal)
        var rows: [(String, Int, TimeInterval?, TimeInterval?)] = []
        for (sig, eps) in bySignal {
            let ons = eps.filter { !$0.gated }
                .compactMap { e in e.iconOn.map { $0.timeIntervalSince(e.on) } }
            let offs = eps.compactMap { e -> TimeInterval? in
                guard !e.gated, let off = e.off, let icon = e.iconOff, !e.overlapped else { return nil }
                return icon.timeIntervalSince(off)
            }
            rows.append((sig, eps.count, median(ons), median(offs)))
        }
        guard !rows.isEmpty else { return }
        print("\nmedian by signal")
        print(String(repeating: "-", count: 46))
        for (sig, n, on, off) in rows.sorted(by: { $0.0 < $1.0 }) {
            print(pad(sig, 15) + pad("n=\(n)", 7)
                  + "ON " + rpad(dur(on), 8) + "   OFF " + rpad(dur(off), 8))
        }
    }

    // MARK: - Episode building

    private static func build(from events: [Event]) -> [Episode] {
        var open: [String: Episode] = [:]     // signal -> episode awaiting release
        var closed: [Episode] = []
        var liveSignals: Set<String> = []
        var lastCallApp: String?

        for e in events {
            switch e.kind {
            case "signal":
                let parts = e.detail.split(separator: " ").map(String.init)
                guard parts.count >= 2 else { break }
                let sig = parts[0], on = parts[1] == "ON"
                if on {
                    liveSignals.insert(sig)
                    if open[sig] == nil {
                        var ep = Episode(signal: sig, on: e.at)
                        ep.gated = e.detail.contains("toggle off")
                        if sig == "micInUse" { ep.app = lastCallApp }
                        open[sig] = ep
                    }
                } else {
                    liveSignals.remove(sig)
                    open[sig]?.off = e.at
                    if sig == "micInUse" { open[sig]?.app = lastCallApp }
                }

            case "call":
                if e.detail.hasPrefix("LIVE") {
                    lastCallApp = apps(in: e.detail)
                    open["micInUse"]?.app = lastCallApp
                }

            case "linger":
                let n = e.detail.split(separator: " ").first.map(String.init) ?? "-"
                for k in open.keys where open[k]?.off != nil && open[k]?.linger == nil {
                    open[k]?.linger = n
                }

            case "hold":
                if e.detail.hasPrefix("CLEAR") {
                    for k in open.keys where open[k]?.off != nil { open[k]?.holdClear = e.at }
                }

            case "icon":
                let symbol = e.detail
                if neutralIcons.contains(symbol) {
                    // Icon is counting again: close every released episode.
                    for (k, var ep) in open where ep.off != nil {
                        ep.iconOff = e.at
                        ep.overlapped = !liveSignals.isEmpty
                        closed.append(ep)
                        open.removeValue(forKey: k)
                    }
                } else {
                    for (k, var ep) in open where ep.iconOn == nil && ep.off == nil {
                        ep.iconOn = e.at
                        open[k] = ep
                    }
                }

            default:
                break
            }
        }
        // Episodes still open (signal live now, or never released).
        closed.append(contentsOf: open.values)
        return closed.sorted { $0.on < $1.on }
    }

    private static func apps(in detail: String) -> String {
        guard let open = detail.firstIndex(of: "["),
              let close = detail.lastIndex(of: "]"), open < close else { return "?" }
        let inner = detail[detail.index(after: open)..<close]
        let names = inner.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? "?" : names.joined(separator: "+")
    }

    private static func load() -> [Event] {
        var lines: [String] = []
        for url in [Trace.logURL.deletingPathExtension().appendingPathExtension("log.1"),
                    Trace.logURL] {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                lines += text.split(separator: "\n").map(String.init)
            }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return lines.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count >= 3, let at = f.date(from: "\(parts[0]) \(parts[1])") else { return nil }
            return Event(at: at, kind: parts[2], detail: parts.count > 3 ? parts[3] : "")
        }
    }

    // MARK: - Formatting

    // Defaults.store already picks the right domain for bundled and unbundled
    // runs. Naming the suite by hand made AppKit warn, because the report runs
    // inside the app bundle whose identifier that is.
    private static var debugOn: Bool { Defaults.store.bool(forKey: "debugLogging") }

    private static func median(_ xs: [TimeInterval]) -> TimeInterval? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count)
    }

    private static func rpad(_ s: String, _ n: Int) -> String {
        s.count >= n ? " " + s : String(repeating: " ", count: n - s.count) + s
    }

    private static func dur(_ t: TimeInterval?) -> String {
        guard let t else { return "-" }
        if t < 60 { return String(format: "%.1fs", t) }
        return String(format: "%dm%02ds", Int(t) / 60, Int(t) % 60)
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f.string(from: d)
    }
}
