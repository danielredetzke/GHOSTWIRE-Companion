import SwiftUI

struct DashboardView: View {
    @Environment(AppSession.self) private var session
    @State private var status: Status?
    @State private var peers: [Peer] = []
    @State private var points: [StatPoint] = []
    @State private var range = "24h"
    @State private var activity: [ActivityLine]?
    @State private var error: String?
    @AppStorage("hiddenUpdate") private var hiddenUpdate = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let error { Notice(text: error, isError: true) }
                    if let s = status {
                        content(s)
                    } else if error == nil {
                        ProgressView().padding(40)
                    }
                }
                .padding(16)
            }
            .background(Color.gwGround)
            .navigationTitle("Dashboard")
            .serverToolbar()
            .navigationDestination(for: String.self) { PeerDetailView(peerID: $0) }
            .refreshable { await load() }
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    @ViewBuilder private func content(_ s: Status) -> some View {
        let failing = s.checks.filter { !$0.ok }
        let ifUp = s.checks.first { $0.name == "WireGuard interface" }?.ok ?? false

        Text("Endpoint \(s.endpoint) · \(s.ipv4)")
            .font(.mono(.caption))
            .foregroundStyle(Color.gwText2)
            .frame(maxWidth: .infinity, alignment: .leading)

        if let v = s.visitor { VisitorCard(visitor: v) }

        if !failing.isEmpty {
            Notice(text: "Needs attention: " + failing.map { "\($0.name) (\($0.detail))" }.joined(separator: " · "), isError: true)
        }

        if let me = session.me, let v = me.updateAvailable, v != hiddenUpdate {
            UpdateBanner(available: v, current: me.version) { hiddenUpdate = v }
        }

        // A Grid (not LazyVGrid) gives both tiles of a row the same height.
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Tile(title: "Peers online", value: "\(s.peers.online)", suffix: "/ \(s.peers.total)",
                     sub: "\(s.peers.disabled) disabled · \(s.peers.never) never connected")
                Tile(title: "Interface", value: ifUp ? "Up" : "Down", dot: ifUp ? .gwGood : .gwBad,
                     sub: "Service up " + ago(s.started).replacingOccurrences(of: " ago", with: "") + " · "
                        + (s.healthy ? "all checks pass" : "\(failing.count) check(s) failing"))
            }
            GridRow {
                Tile(title: "Last 24 h", value: fmtBytes(s.traffic24h.down + s.traffic24h.up),
                     sub: "Down \(fmtBytes(s.traffic24h.down)) · Up \(fmtBytes(s.traffic24h.up))")
                Tile(title: "Last 30 days", value: fmtBytes(s.traffic30d.down + s.traffic30d.up),
                     sub: s.topPeer30d.isEmpty ? "No traffic yet" : "Top peer: \(s.topPeer30d)")
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Traffic, all peers")
            Picker("Range", selection: $range) {
                Text("24 h").tag("24h")
                Text("7 days").tag("7d")
                Text("30 days").tag("30d")
            }
            .pickerStyle(.segmented)
            .onChange(of: range) { Task { await loadStats() } }
            TrafficChart(points: points, range: range, mode: .total)
        }
        .card()

        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Peers").padding(.bottom, 8)
            let top = peers.sorted { $0.stats.down24h + $0.stats.up24h > $1.stats.down24h + $1.stats.up24h }.prefix(6)
            if top.isEmpty {
                Text("No peers yet.").font(.footnote).foregroundStyle(Color.gwText2).padding(.vertical, 8)
            }
            ForEach(Array(top)) { p in
                NavigationLink(value: p.id) {
                    PeerRow(peer: p, period: .day)
                }
                .buttonStyle(.plain)
                if p.id != top.last?.id { Divider() }
            }
        }
        .card()

        if let activity {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionTitle(text: "Recent activity")
                    Spacer()
                    NavigationLink("Log") { LogView() }.font(.subheadline)
                }
                .padding(.bottom, 8)
                if activity.isEmpty {
                    Text("No changes yet.").font(.footnote).foregroundStyle(Color.gwText2).padding(.vertical, 8)
                }
                ForEach(activity) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(fmtWhen(a.time))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.gwText2)
                            .frame(width: 52, alignment: .leading)
                        Text(a.text).font(.footnote)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    if a.id != activity.last?.id { Divider() }
                }
            }
            .card()
        }
    }

    /// The latest audit entries: who changed what.
    private func loadActivity(_ api: API) async throws -> [ActivityLine] {
        let data = try await api.data("GET", "/logs?audit=1&limit=6")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["lines"] as? [[String: Any]] ?? []).enumerated().compactMap { i, rec in
            guard let t = rec["time"] as? String, let time = parseGoDate(t) else { return nil }
            return ActivityLine(id: i, time: time, text: describeAudit(rec))
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            async let s: Status = api.get("/status")
            async let p: PeerList = api.get("/peers")
            async let st: StatsResponse = api.get("/stats?range=\(range)")
            let (a, b, c) = try await (s, p, st)
            status = a
            if let id = api.server { session.report(a, for: id) }
            peers = b.peers
            if c.range == range { points = c.points }
            error = nil
            activity = try? await loadActivity(api)
            // The server checks for releases daily; pick up what it found.
            if let m: Me = try? await api.get("/auth/me") { session.me = m }
        } catch {
            self.error = session.message(for: error)
        }
    }

    /// A range switch fetches and redraws only the chart.
    private func loadStats() async {
        guard let api = session.api else { return }
        let r = range
        if let s: StatsResponse = try? await api.get("/stats?range=\(r)"), r == range { points = s.points }
    }
}

/// Whether this iPhone is behind the VPN, like the web dashboard: the
/// address websites see next to the server's. The same address means
/// protected.
struct VisitorCard: View {
    let visitor: Visitor

    var body: some View {
        let v = visitor
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: v.protected ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.title3)
                    .foregroundStyle(v.protected ? Color.gwGood : Color.gwWarnInk)
                    .frame(width: 40, height: 40)
                    .background(v.protected ? Color.gwGood.opacity(0.12) : Color.gwWarnBg, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.protected ? "You are protected" : "Not protected")
                        .font(.headline)
                        .foregroundStyle(v.protected ? Color.gwText : Color.gwWarnInk)
                    Text(explanation).font(.footnote).foregroundStyle(Color.gwText2)
                    if let p = v.peer {
                        NavigationLink(value: p.id) {
                            Label(p.name, systemImage: "person.crop.circle").font(.footnote.weight(.medium))
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                address("Your IP address", v.ip, note: yourNote, warn: !v.protected)
                address("Server IP address", v.serverIP,
                        note: v.protected ? "Same address: you are behind the VPN" : "Different address: you are not behind the VPN", warn: false)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var explanation: String {
        switch (visitor.protected, visitor.peer != nil) {
        case (true, true): "This iPhone is connected through the tunnel. All its traffic goes out through this server, so websites see the server's address, not yours."
        case (true, false): "This iPhone's traffic goes out through this server, so websites see the server's address, not yours."
        case (false, true): "This iPhone uses the tunnel only for the VPN network. Its other traffic skips the VPN, so websites see your own address."
        case (false, false): "This iPhone connects directly, not through the VPN. Websites see your own address. Turn on the tunnel to go out through this server."
        }
    }

    private var yourNote: String {
        if visitor.protected { return "What websites see" }
        if let p = visitor.peer { return "Tunnel address of " + p.name }
        if let l = visitor.location, !l.label.isEmpty { return l.label }
        return "What websites see"
    }

    private func address(_ label: String, _ value: String, note: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Color.gwText2)
            Text(value.isEmpty ? "Unknown" : value)
                .font(.mono(.subheadline, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .textSelection(.enabled)
            Text(note).font(.caption2).foregroundStyle(Color.gwText2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(warn ? Color.gwWarnBg : Color.gwBadge, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "GHOSTWIRE v0.9.1 is available", until hidden for that version.
struct UpdateBanner: View {
    let available: String
    let current: String
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("**GHOSTWIRE \(available) is available.** You're on v\(current.hasPrefix("v") ? String(current.dropFirst()) : current). Update it on the server; VPN connections stay up.")
                .font(.footnote)
                .foregroundStyle(Color.gwText)
            Button("Hide until the next version", action: hide).font(.footnote.weight(.medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gwDown.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ActivityLine: Identifiable {
    let id: Int
    let time: Date
    let text: String
}

/// "Peer created: phone · dan", like the web dashboard.
func describeAudit(_ rec: [String: Any]) -> String {
    let msg = rec["msg"] as? String ?? ""
    var s = msg.prefix(1).uppercased() + msg.dropFirst()
    if let p = rec["peer"] as? String { s += ": " + p }
    if let t = rec["token"] as? String { s += ": " + t }
    if let f = rec["fields"] as? [String], !f.isEmpty { s += " (" + f.joined(separator: ", ") + ")" }
    return s + " · " + (rec["actor"] as? String ?? "")
}

/// Time today, "Yest." or a short date, like the web dashboard.
func fmtWhen(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yest." }
    return d.formatted(.dateTime.day().month(.abbreviated))
}
