import Charts
import SwiftUI

// The speed of every peer right now, like the web interface's Live page.
// The server streams its short in-memory history (the last 2 minutes in
// 2-second steps) and then each new step as it is sampled.

/// Below this, a peer counts as idle: keepalives and pings, no real traffic.
nonisolated let idleBPS = 2000.0

/// The figures and the list average the last few steps so they do not swing
/// with every burst; the chart shows each step.
let avgSteps = 5

struct LiveView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var peers: [Peer] = []
    @State private var points: [SpeedPoint] = []
    @State private var step = 2
    @State private var size = 60
    @State private var paused = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(paused ? "Paused · the chart keeps the moment you paused"
                                : "Updated every \(step) s · figures are \(avgSteps * step)-second averages")
                        .font(.footnote)
                        .foregroundStyle(Color.gwText2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let error { Notice(text: error, isError: true) }
                    totalsCard
                    peersCard
                }
                .padding(16)
            }
            .background(Color.gwGround)
            .navigationTitle("Live")
            .serverToolbar()
            .toolbar {
                Button { paused.toggle() } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                }
            }
            .navigationDestination(for: String.self) { PeerDetailView(peerID: $0) }
            // The stream runs only while the screen is visible, not paused
            // and the app is in front.
            .task(id: !paused && scenePhase == .active) {
                if !paused && scenePhase == .active { await stream() }
            }
            .task {
                while !Task.isCancelled {
                    await loadPeers()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }

    // MARK: - Data

    private func loadPeers() async {
        guard let api = session.api else { return }
        if let l: PeerList = try? await api.get("/peers") { peers = l.peers }
    }

    /// The first message of a stream is the whole history; later ones carry
    /// one new step each. One step more than the server keeps is held, so
    /// the chart's left edge stays filled.
    private func stream() async {
        var retry = 0
        while !Task.isCancelled {
            guard let api = session.api else { return }
            do {
                let bytes = try await api.events("/live/stream")
                var first = true
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    let m = try API.decoder.decode(LiveSpeeds.self, from: Data(line.dropFirst(5).utf8))
                    step = m.step
                    size = m.size
                    points = first ? m.points : Array((points + m.points).suffix(m.size + 1))
                    first = false
                    retry = 0
                    error = nil
                }
            } catch {
                if Task.isCancelled { return }
                if case APIError.unauthorized = error {
                    self.error = session.message(for: error)
                    return
                }
                self.error = "Live updates stopped. Reconnecting…"
            }
            try? await Task.sleep(for: .seconds(min(30, 2 << min(retry, 4))))
            retry += 1
        }
    }

    private var recent: ArraySlice<SpeedPoint> { points.suffix(avgSteps) }

    private func average(_ f: (SpeedPoint) -> Int64) -> Double {
        recent.isEmpty ? 0 : Double(recent.reduce(0) { $0 + f($1) }) / Double(recent.count)
    }

    /// A peer's averaged download and upload.
    private func rate(_ id: String) -> (down: Double, up: Double) {
        (average { $0.rate(id).down }, average { $0.rate(id).up })
    }

    // MARK: - Views

    private var totalsCard: some View {
        let online = peers.filter { $0.stats.online }
        let active = peers.filter { let r = rate($0.id); return r.down + r.up >= idleBPS }.count
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "All peers · right now")
            HStack(alignment: .top, spacing: 12) {
                figure("Download", fmtRate(average { $0.total.down }), key: .gwDown)
                figure("Upload", fmtRate(average { $0.total.up }), key: .gwUp)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active peers").font(.caption).foregroundStyle(Color.gwText2)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(active)").font(.title3.weight(.semibold))
                        Text("/ \(online.count) online").font(.caption).foregroundStyle(Color.gwText2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LiveChart(points: points, step: step, size: size)
        }
        .card()
    }

    private func figure(_ title: String, _ value: String, key: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(key).frame(width: 10, height: 10)
                Text(title).font(.caption).foregroundStyle(Color.gwText2)
            }
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var peersCard: some View {
        let rows = peers.filter { $0.stats.online }
            .map { p in (p, rate(p.id), points.map { pt in let r = pt.rate(p.id); return Double(r.down + r.up) }) }
            .sorted { a, b in
                let x = a.1.down + a.1.up, y = b.1.down + b.1.up
                return x != y ? x > y : a.0.name.localizedCompare(b.0.name) == .orderedAscending
            }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle(text: "Peers")
                Spacer()
                Text("Busiest first").font(.caption).foregroundStyle(Color.gwText2)
            }
            .padding(.bottom, 8)
            if rows.isEmpty {
                Text("No peer is online.").font(.footnote).foregroundStyle(Color.gwText2).padding(.vertical, 8)
            }
            ForEach(rows, id: \.0.id) { p, r, hist in
                NavigationLink(value: p.id) { liveRow(p, r, hist) }
                    .buttonStyle(.plain)
                if p.id != rows.last?.0.id { Divider() }
            }
        }
        .card()
    }

    private func liveRow(_ p: Peer, _ r: (down: Double, up: Double), _ hist: [Double]) -> some View {
        let idle = r.down + r.up < idleBPS
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(p.name).font(.body.weight(.semibold)).foregroundStyle(idle ? Color.gwText2 : Color.gwText)
                    if idle {
                        Text("idle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.gwText2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.gwBadge, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                HStack(spacing: 6) {
                    Text(p.stats.endpoint.isEmpty ? "–" : p.stats.endpoint.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression))
                        .font(.mono(.caption))
                        .foregroundStyle(Color.gwText2)
                        .lineLimit(1)
                    if let cc = p.stats.location?.country, !cc.isEmpty {
                        Text(cc).font(.caption2.weight(.semibold)).foregroundStyle(Color.gwText2)
                    }
                }
            }
            Spacer(minLength: 8)
            RateSpark(values: hist)
            VStack(alignment: .trailing, spacing: 4) {
                Text(idle ? "–" : "↓ " + fmtRate(r.down)).font(.footnote.monospacedDigit())
                Text(idle ? "–" : "↑ " + fmtRate(r.up)).font(.footnote.monospacedDigit()).foregroundStyle(Color.gwText2)
            }
            .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(idle ? "\(p.name), idle" : "\(p.name), download \(fmtRate(r.down)), upload \(fmtRate(r.up))")
    }
}

/// Download and upload of all peers as lines over light areas, the newest
/// step at the right edge. Touch the chart to read a step.
struct LiveChart: View {
    let points: [SpeedPoint]
    let step: Int
    let size: Int
    @State private var selected: Date?

    private struct Sample: Identifiable {
        let date: Date
        let down: Double
        let up: Double
        var id: Date { date }
    }

    var body: some View {
        let samples = points.map { p in let t = p.total; return Sample(date: p.date, down: Double(t.down), up: Double(t.up)) }
        let end = samples.last?.date ?? Date()
        let start = end.addingTimeInterval(-Double((size - 1) * step))
        let pick = selected.flatMap { s in samples.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let p = pick {
                    Text("\(p.date.formatted(date: .omitted, time: .standard)) · Download **\(fmtRate(p.down))** · Upload **\(fmtRate(p.up))**")
                } else {
                    Text("Touch the chart to see a step.")
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.gwText2)
            .frame(minHeight: 18, alignment: .leading)
            Chart {
                ForEach(samples) { s in
                    AreaMark(x: .value("Time", s.date), y: .value("Speed", s.down), series: .value("Series", "Download"), stacking: .unstacked)
                        .foregroundStyle(Color.gwDown.opacity(0.12))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.date), y: .value("Speed", s.down), series: .value("Series", "Download"))
                        .foregroundStyle(Color.gwDown)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Time", s.date), y: .value("Speed", s.up), series: .value("Series", "Upload"), stacking: .unstacked)
                        .foregroundStyle(Color.gwUp.opacity(0.12))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.date), y: .value("Speed", s.up), series: .value("Series", "Upload"))
                        .foregroundStyle(Color.gwUp)
                        .interpolationMethod(.monotone)
                }
                if let p = pick {
                    RuleMark(x: .value("Time", p.date)).foregroundStyle(Color.gwText2.opacity(0.5))
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...max(samples.map { max($0.down, $0.up) }.max() ?? 0, 1_000_000))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let b = v.as(Double.self) { Text(fmtRate(b)).font(.caption2) }
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartXSelection(value: $selected)
            .frame(height: 160)
            .accessibilityLabel("Speed of all peers over the last 2 minutes")
        }
    }
}

/// A peer's total speed over the same window, scaled to its own peak.
struct RateSpark: View {
    let values: [Double]

    var body: some View {
        Canvas(renderer: Self.renderer(values))
            .frame(width: 56, height: 18)
            .accessibilityHidden(true)
    }

    // nonisolated: SwiftUI may render a Canvas on its background render
    // thread, and a main-actor closure would trap there.
    nonisolated private static func renderer(_ values: [Double]) -> (inout GraphicsContext, CGSize) -> Void {
        { ctx, size in
            guard values.count >= 2 else { return }
            let top = Swift.max(values.max() ?? 0, idleBPS * 4)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * size.width,
                        y: size.height - 1 - CGFloat(v / top) * (size.height - 3))
            }
            var line = Path()
            line.addLines(pts)
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(.gwDown.opacity(0.15)))
            ctx.stroke(line, with: .color(.gwDown), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
        }
    }
}
