import Charts
import SwiftUI

// Latency is the round trip from the server through the tunnel to the device
// and back, measured by the server's ping. Values are in milliseconds.

/// A peer's current latency: the median of the last 5 minutes.
nonisolated struct LatencyView: Decodable, Hashable {
    let ms: Double?        // nil = no ping reply
    let min: Double
    let max: Double
    let loss: Int          // percent
    let at: Date           // newest ping
    let spark: [Double?]?  // medians of the last hour, oldest first
}

/// One 5-minute step of the latency history.
nonisolated struct LatencyPoint: Decodable, Identifiable, Hashable {
    let t: Int64
    let sent: Int
    let lost: Int
    let min: Double?
    let med: Double?
    let max: Double?
    var id: Int64 { t }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
    var ok: Bool { sent > lost }
}

nonisolated struct LatencyResponse: Decodable {
    let stepSeconds: Int
    let points: [LatencyPoint]
}

func fmtMs(_ ms: Double) -> String {
    (ms < 10 ? String(format: "%.1f", ms) : String(Int(ms.rounded()))) + " ms"
}

/// A value is stale when the server stopped pinging, e.g. because the device
/// went idle; it is then shown greyed out.
func latencyStale(_ l: LatencyView) -> Bool {
    Date().timeIntervalSince(l.at) > 90
}

enum LatencyCheck {
    static let options: [(String, String)] = [("off", "Off"), ("active", "While the device is active"), ("always", "Always")]

    static func hint(_ mode: String) -> String {
        switch mode {
        case "active": "Pings every 30 s while the device sends traffic. An idle device is left alone."
        case "always": "Pings every 30 s, even when idle. This keeps the tunnel up, so the peer always shows as Online. Best for servers and routers."
        default: "The server never pings this peer."
        }
    }
}

/// Latency for the peer lists: value with sparkline, or a short note.
struct LatencyBadge: View {
    let peer: Peer

    var body: some View {
        if peer.enabled, !peer.publicKey.isEmpty {
            if peer.latencyCheck == "off" {
                note("Check off")
            } else if let l = peer.stats.latency {
                if let ms = l.ms {
                    HStack(spacing: 4) {
                        Sparkline(values: l.spark ?? [])
                        Text(fmtMs(ms)).font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(latencyStale(l) ? Color.gwText2 : Color.gwText)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Latency \(fmtMs(ms))")
                } else {
                    note("No ping reply")
                }
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(Color.gwText2)
    }
}

/// The medians of the last hour as a small line; gaps are skipped.
struct Sparkline: View {
    let values: [Double?]

    var body: some View {
        Canvas(renderer: Self.renderer(values))
            .frame(width: 40, height: 14)
            .accessibilityHidden(true)
    }

    // nonisolated: SwiftUI may render a Canvas on its background render
    // thread, and a main-actor closure would trap there.
    nonisolated private static func renderer(_ values: [Double?]) -> (inout GraphicsContext, CGSize) -> Void {
        { ctx, size in
            let pts = values.enumerated().compactMap { i, v in v.map { (i, $0) } }
            guard pts.count >= 2, values.count >= 2 else { return }
            let lo = pts.map(\.1).min()!, hi = pts.map(\.1).max()!
            let span = Swift.max(hi - lo, hi * 0.2, 1)
            func xy(_ p: (Int, Double)) -> CGPoint {
                CGPoint(x: CGFloat(p.0) / CGFloat(values.count - 1) * (size.width - 4) + 2,
                        y: size.height - 2 - CGFloat((p.1 - lo) / span) * (size.height - 4))
            }
            var path = Path()
            path.addLines(pts.map(xy))
            ctx.stroke(path, with: .color(.gwDown), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let end = xy(pts.last!)
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2, y: end.y - 2, width: 4, height: 4)), with: .color(.gwDown))
        }
    }
}

/// The median as a line over a min–max band, one point per 5 minutes. Steps
/// without replies leave a gap. Touch the chart to see a step's values.
struct LatencyChart: View {
    let points: [LatencyPoint]
    @State private var selected: Date?

    /// Runs of consecutive steps with replies; each run is drawn separately.
    private var runs: [(Int, [LatencyPoint])] {
        var out: [(Int, [LatencyPoint])] = []
        var cur: [LatencyPoint] = []
        for p in points {
            if p.ok { cur.append(p) } else if !cur.isEmpty { out.append((out.count, cur)); cur = [] }
        }
        if !cur.isEmpty { out.append((out.count, cur)) }
        return out
    }

    private var selectedPoint: LatencyPoint? {
        guard let selected else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
                .font(.footnote)
                .foregroundStyle(Color.gwText2)
                .frame(minHeight: 18, alignment: .leading)
            Chart {
                ForEach(runs, id: \.0) { run, pts in
                    ForEach(pts) { p in
                        AreaMark(x: .value("Time", p.date), yStart: .value("Min", p.min ?? 0), yEnd: .value("Max", p.max ?? 0),
                                 series: .value("Run", "band\(run)"))
                            .foregroundStyle(Color.gwDown.opacity(0.18))
                        LineMark(x: .value("Time", p.date), y: .value("Median", p.med ?? 0), series: .value("Run", "med\(run)"))
                            .foregroundStyle(Color.gwDown)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                    if pts.count == 1, let p = pts.first {
                        PointMark(x: .value("Time", p.date), y: .value("Median", p.med ?? 0))
                            .foregroundStyle(Color.gwDown)
                            .symbolSize(16)
                    }
                }
                if let p = selectedPoint {
                    RuleMark(x: .value("Time", p.date)).foregroundStyle(Color.gwText2.opacity(0.5))
                }
            }
            .chartXScale(domain: (points.first?.date ?? .now)...(points.last?.date ?? .now))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ms = v.as(Double.self) { Text(fmtMs(ms)).font(.caption2) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 140)
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.gwDown).frame(width: 12, height: 3)
                    Text("Median")
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gwDown.opacity(0.18)).frame(width: 12, height: 12)
                    Text("Min–max")
                }
            }
            .font(.caption)
            .foregroundStyle(Color.gwText2)
        }
    }

    @ViewBuilder private var readout: some View {
        let time = { (p: LatencyPoint) in p.date.formatted(date: .omitted, time: .shortened) }
        if let p = selectedPoint {
            if p.ok, let med = p.med, let lo = p.min, let hi = p.max {
                Text("\(time(p)) · median **\(fmtMs(med))** · \(fmtMs(lo))–\(fmtMs(hi)) · \(p.lost * 100 / p.sent) % loss")
            } else {
                Text("\(time(p)) · " + (p.sent > 0 ? "no reply" : "not measured"))
            }
        } else {
            let meds = points.filter(\.ok).compactMap(\.med).sorted()
            if meds.isEmpty {
                Text("No measurements in the last 24 hours.")
            } else {
                Text("Median over 24 hours **\(fmtMs(meds[meds.count / 2]))** · touch the chart to see a time.")
            }
        }
    }
}
