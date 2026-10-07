import SwiftUI

struct PeerRow: View {
    enum Period { case day, month }
    let peer: Peer
    let period: Period

    var body: some View {
        let down = period == .day ? peer.stats.down24h : peer.stats.down30d
        let up = period == .day ? peer.stats.up24h : peer.stats.up30d
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(peer.name).font(.body.weight(.semibold)).foregroundStyle(Color.gwText)
                    if let cc = peer.stats.location?.country, !cc.isEmpty {
                        Text(cc)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.gwText2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.gwBadge, in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityLabel(peer.stats.location?.label ?? cc)
                    }
                }
                if !peer.note.isEmpty {
                    Text(peer.note).font(.caption).foregroundStyle(Color.gwText2).lineLimit(1)
                }
                StatusBadge(state: PeerState(peer))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("↓ " + fmtBytes(down)).font(.footnote.monospacedDigit())
                Text("↑ " + fmtBytes(up)).font(.footnote.monospacedDigit()).foregroundStyle(Color.gwText2)
                LatencyBadge(peer: peer)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct PeersView: View {
    @Environment(AppSession.self) private var session
    @State private var list: PeerList?
    @State private var query = ""
    @State private var filter = "all"
    @State private var sort: PeerSort?
    @State private var sortDesc = false
    @State private var error: String?
    @State private var adding = false
    @State private var deleting: Peer?
    @State private var path = NavigationPath()

    private var filtered: [Peer] {
        let q = query.lowercased()
        let peers = (list?.peers ?? []).filter { p in
            let hit = q.isEmpty || "\(p.name) \(p.ipv4) \(p.note)".lowercased().contains(q)
            return hit && (filter == "all" || PeerState(p).key == filter)
        }
        guard let sort else { return peers }
        return sort.sorted(peers, descending: sortDesc)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Status", selection: $filter) {
                        Text("All").tag("all")
                        Text("Online").tag("online")
                        Text("Offline").tag("offline")
                        Text("Disabled").tag("disabled")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let error {
                    Section { Notice(text: error, isError: true) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(filtered) { p in
                        NavigationLink(value: p.id) { PeerRow(peer: p, period: .month) }
                            .swipeActions(edge: .trailing) {
                                // The app-wide ink tint would override the destructive red.
                                Button(role: .destructive) { deleting = p } label: { Label("Delete", systemImage: "trash") }
                                    .tint(Color.gwBad)
                                Button { Task { await toggle(p) } } label: {
                                    Label(p.enabled ? "Disable" : "Enable", systemImage: p.enabled ? "pause.circle" : "play.circle")
                                }
                                .tint(.gray)
                            }
                    }
                    if list != nil && filtered.isEmpty {
                        Text(list?.peers.isEmpty == true ? "No peers yet. Tap + to add one." : "No peers match this filter.")
                            .font(.footnote)
                            .foregroundStyle(Color.gwText2)
                    }
                } footer: {
                    if let list {
                        Text("\(list.peers.count) of \(list.capacity) addresses in \(list.network) used. Traffic is for the last 30 days, from the peer's side.")
                    }
                }
            }
            .groundBackground()
            .searchable(text: $query, prompt: "Name, address or note")
            .navigationTitle("Peers")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { sortMenu }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add peer", systemImage: "plus") }
                }
            }
            .navigationDestination(for: String.self) { PeerDetailView(peerID: $0) }
            .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) { AddPeerView() }
            .confirmationDialog("Delete peer?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { p in
                Button("Delete \(p.name)", role: .destructive) { Task { await delete(p) } }
            } message: { _ in
                Text("The device loses access immediately. Its traffic history is deleted too.")
            }
            .refreshable { await load() }
            .task {
                await load()
                #if DEBUG
                // Development: `-openFirstPeer YES` and `-addPeer YES`.
                if UserDefaults.standard.bool(forKey: "openFirstPeer"), let first = list?.peers.first { path.append(first.id) }
                if UserDefaults.standard.bool(forKey: "addPeer") { adding = true }
                #endif
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    await load()
                }
            }
        }
    }

    /// Choosing the current key again reverses the order, like the column
    /// headers in the web interface.
    private var sortMenu: some View {
        Menu {
            Button { sort = nil } label: {
                if sort == nil { Label("Server order", systemImage: "checkmark") } else { Text("Server order") }
            }
            ForEach(PeerSort.allCases) { k in
                Button {
                    if sort == k { sortDesc.toggle() } else { sort = k; sortDesc = k.startsDescending }
                } label: {
                    if sort == k { Label(k.label, systemImage: sortDesc ? "chevron.down" : "chevron.up") } else { Text(k.label) }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            list = try await api.get("/peers")
            error = nil
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func toggle(_ p: Peer) async {
        guard let api = session.api else { return }
        do {
            let r: PeerResult = try await api.send("POST", "/peers/\(p.id)/" + (p.enabled ? "disable" : "enable"))
            session.reportApply(r.applyError)
            await load()
        } catch {
            session.alert = session.message(for: error)
        }
    }

    private func delete(_ p: Peer) async {
        guard let api = session.api else { return }
        do {
            let r: ApplyResult = try await api.send("DELETE", "/peers/\(p.id)")
            session.reportApply(r.applyError)
            await load()
        } catch {
            session.alert = session.message(for: error)
        }
    }
}

/// Sort keys of the peer list, as in the web interface's peers table.
/// Numbers start descending, text ascending; peers without a value (no
/// endpoint, no latency) always come last.
enum PeerSort: String, CaseIterable, Identifiable {
    case name, address, status, endpoint, latency, down, up, enabled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .address: "Address"
        case .status: "Status"
        case .endpoint: "Endpoint"
        case .latency: "Latency"
        case .down: "Download, 30 d"
        case .up: "Upload, 30 d"
        case .enabled: "Enabled"
        }
    }

    var startsDescending: Bool { self == .down || self == .up }

    private enum Value: Comparable {
        case num(Double), text(String)
    }

    private static let stateOrder = ["online", "offline", "never", "setup", "nokey", "disabled"]

    private func value(_ p: Peer) -> Value? {
        switch self {
        case .name: return .text(p.name.lowercased())
        case .address:
            return .num(p.ipv4.split(separator: ".").reduce(0.0) { $0 * 256 + (Double($1) ?? 0) })
        case .status:
            let key: String = switch PeerState(p) {
            case .online: "online"
            case .offline: "offline"
            case .never: "never"
            case .waiting: "setup"
            case .noConfig: "nokey"
            case .disabled: "disabled"
            }
            let order = Double(Self.stateOrder.firstIndex(of: key) ?? 0)
            return .num(order * 1e13 - (p.stats.lastHandshake?.timeIntervalSince1970 ?? 0) * 1000)
        case .endpoint:
            guard !p.stats.endpoint.isEmpty else { return nil }
            return .text((p.stats.location?.country ?? "~") + " " + p.stats.endpoint)
        case .latency:
            guard p.latencyCheck != "off", let ms = p.stats.latency?.ms else { return nil }
            return .num(ms)
        case .down: return .num(Double(p.stats.down30d))
        case .up: return .num(Double(p.stats.up30d))
        case .enabled: return .num(p.enabled ? 0 : 1)
        }
    }

    func sorted(_ peers: [Peer], descending: Bool) -> [Peer] {
        peers.map { ($0, value($0)) }.sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?) where x != y: return descending ? x > y : x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.0.name.localizedCompare(b.0.name) == .orderedAscending
            }
        }.map(\.0)
    }
}
