import Foundation

/// Reads the durable event log and reports, per call, how long each stage of
/// the release took. The question this answers: after a hangup, how long
/// until the menu bar stops saying "on a call"?
enum CallReport {

    private struct Event {
        let at: Date
        let kind: String      // audio | call | hold | linger | icon | presence
        let detail: String
    }

    static func run() {
        let events = load()
        guard !events.isEmpty else {
            print("No events yet at \(Trace.logURL.path).")
            print("Use the app normally (place a call, hang up) and run this again.")
            return
        }
        let first = events.first!.at, last = events.last!.at
        print("Halftone call report")
        print("log: \(Trace.logURL.path)")
        print("window: \(stamp(first)) to \(stamp(last))  (\(events.count) events)\n")

        let calls = sessions(from: events)
        guard !calls.isEmpty else {
            print("No call sessions recorded in this window.")
            return
        }

        print("app                        started    talk   mic->end  end->icon  hangup->icon")
        print(String(repeating: "-", count: 78))
        for c in calls {
            let app = c.app.count > 24 ? String(c.app.suffix(24)) : c.app
            print(String(format: "%-26s %-10s %6s %10s %10s %13s",
                         (app as NSString).utf8String!,
                         (clock(c.started) as NSString).utf8String!,
                         (dur(c.talk) as NSString).utf8String!,
                         (dur(c.micDropToEnd) as NSString).utf8String!,
                         (dur(c.endToIcon) as NSString).utf8String!,
                         (dur(c.hangupToIcon) as NSString).utf8String!))
        }
        print("""

        talk          mic held, first detection to the mic dropping
        mic->end      mic released to the call session ending (survivorship)
        end->icon     session ended to the menu bar icon changing back (linger)
        hangup->icon  what you actually see: mic released to icon back to normal
        """)
    }

    // MARK: - Parsing

    private struct Session {
        var app: String
        var started: Date
        var talk: TimeInterval?
        var micDropToEnd: TimeInterval?
        var endToIcon: TimeInterval?
        var hangupToIcon: TimeInterval?
    }

    private static func sessions(from events: [Event]) -> [Session] {
        var out: [Session] = []
        var live: (started: Date, app: String, micDrop: Date?, ended: Date?)?

        for e in events {
            switch e.kind {
            case "call" where e.detail.hasPrefix("LIVE"):
                if live == nil {
                    live = (e.at, apps(in: e.detail), nil, nil)
                }
            case "audio":
                // A mic list that is empty is the hangup (or the mute).
                if var l = live, l.micDrop == nil, micIsEmpty(e.detail) {
                    l.micDrop = e.at
                    live = l
                }
                // Mic came back (unmute): the previous drop was not a hangup.
                if var l = live, l.micDrop != nil, l.ended == nil, !micIsEmpty(e.detail) {
                    l.micDrop = nil
                    live = l
                }
            case "call" where e.detail.hasPrefix("ended"):
                if var l = live {
                    l.ended = e.at
                    live = l
                }
            case "icon" where e.detail == "circle.lefthalf.filled" || e.detail == "moon.zzz":
                if let l = live, let ended = l.ended {
                    out.append(Session(
                        app: l.app,
                        started: l.started,
                        talk: l.micDrop.map { $0.timeIntervalSince(l.started) },
                        micDropToEnd: l.micDrop.map { ended.timeIntervalSince($0) },
                        endToIcon: e.at.timeIntervalSince(ended),
                        hangupToIcon: l.micDrop.map { e.at.timeIntervalSince($0) }))
                    live = nil
                }
            default:
                break
            }
        }
        // A call still in progress: report what is known so far.
        if let l = live {
            out.append(Session(app: l.app, started: l.started,
                               talk: l.micDrop.map { $0.timeIntervalSince(l.started) },
                               micDropToEnd: nil, endToIcon: nil, hangupToIcon: nil))
        }
        return out
    }

    private static func micIsEmpty(_ detail: String) -> Bool {
        guard let r = detail.range(of: "mic=[") else { return false }
        return detail[r.upperBound...].hasPrefix("]")
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
            return Event(at: at, kind: parts[2],
                         detail: parts.count > 3 ? parts[3] : "")
        }
    }

    // MARK: - Formatting

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
