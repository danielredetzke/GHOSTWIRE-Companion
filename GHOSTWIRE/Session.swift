import Foundation
import Observation
import Security

/// What the web interface's "Pair iOS app" QR code contains.
struct Pairing: Codable, Equatable {
    var url: String
    var token: String
    var fingerprint: String

    /// Parses the pairing JSON from the QR code or the "Copy pairing code" button.
    static func parse(_ text: String) throws -> Pairing {
        guard let p = try? JSONDecoder().decode(Pairing.self, from: Data(text.utf8)),
              p.url.hasPrefix("https://") || p.url.hasPrefix("http://"),
              p.token.hasPrefix("wgt_") else {
            throw APIError.badPairing("This is not a GHOSTWIRE pairing code.")
        }
        return p
    }

    /// The address without trailing slashes, as the API uses it.
    var base: String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// Identifies the server: two pairings with the same key are the same
    /// server, so pairing it again replaces the token.
    var key: String { base.lowercased() }

    /// The host, with the port when it is not the default one.
    var host: String {
        guard let c = URLComponents(string: base), let h = c.host else { return base }
        return c.port.map { "\(h):\($0)" } ?? h
    }
}

/// A paired server. The name is chosen in the app; the server has none.
struct Server: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var pairing: Pairing
}

/// The paired servers are stored in the keychain, readable only on this
/// device. Earlier versions stored a single pairing under "pairing".
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "aero.redetzke.ghostwire",
         kSecAttrAccount as String: account]
    }

    static func save(_ servers: [Server]) {
        SecItemDelete(query("servers") as CFDictionary)
        var q = query("servers")
        q[kSecValueData as String] = try? JSONEncoder().encode(servers)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> [Server] {
        if let d = read("servers"), let s = try? JSONDecoder().decode([Server].self, from: d) { return s }
        // Move the single pairing of earlier versions over.
        guard let d = read("pairing"), let p = try? JSONDecoder().decode(Pairing.self, from: d) else { return [] }
        let servers = [Server(name: p.host, pairing: p)]
        save(servers)
        SecItemDelete(query("pairing") as CFDictionary)
        return servers
    }

    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

/// What the switcher shows for a server, from its /status.
enum ServerHealth {
    case ok(online: Int, total: Int, tunnel: Bool)
    case failing(checks: Int, online: Int, total: Int, tunnel: Bool)
    case unreachable(String)
    case revoked

    init(_ s: Status) {
        let failing = s.checks.filter { !$0.ok }.count
        let tunnel = s.visitor?.protected ?? false
        self = failing == 0 ? .ok(online: s.peers.online, total: s.peers.total, tunnel: tunnel)
            : .failing(checks: failing, online: s.peers.online, total: s.peers.total, tunnel: tunnel)
    }

    /// Whether this iPhone's traffic goes out through the server.
    var tunnel: Bool {
        switch self {
        case .ok(_, _, let t), .failing(_, _, _, let t): t
        default: false
        }
    }
}

/// App-wide state: the paired servers, the one shown, and messages shown
/// as alerts.
@Observable
final class AppSession {
    private(set) var servers: [Server] = []
    private(set) var current: Server?
    private(set) var api: API?
    /// Servers whose token was refused, until a request succeeds again.
    private(set) var revoked: Set<UUID> = []
    private(set) var health: [UUID: ServerHealth] = [:]
    var me: Me?
    var alert: String?
    var tab: MainTabView.Tab = .dashboard
    var showServers = false

    private static let currentKey = "currentServer"

    var pairing: Pairing? { current?.pairing }

    init() {
        servers = Keychain.load()
        var selected = UserDefaults.standard.string(forKey: Self.currentKey).flatMap(UUID.init)
        #if DEBUG
        // Development: `-pairing '<json>'` (repeatable) adds servers,
        // `-server <name>` shows one and `-tab peers` opens a tab. Read the
        // raw arguments: UserDefaults would parse the JSON as a plist.
        let args = ProcessInfo.processInfo.arguments
        for (i, a) in args.enumerated() where a == "-pairing" && i + 1 < args.count {
            if let p = try? Pairing.parse(args[i + 1]) { selected = store(p) }
        }
        if let name = UserDefaults.standard.string(forKey: "server") {
            selected = servers.first { $0.name == name }?.id ?? selected
        }
        if let t = UserDefaults.standard.string(forKey: "tab").flatMap(MainTabView.Tab.init) { tab = t }
        #endif
        show(servers.first { $0.id == selected } ?? servers.first)
    }

    /// Adds a server, or replaces the token of one already paired, and shows it.
    func pair(_ p: Pairing) async throws {
        let me: Me = try await API(pairing: p).get("/auth/me")
        let id = store(p)
        revoked.remove(id)
        health[id] = nil
        show(servers.first { $0.id == id })
        self.me = me
    }

    /// Saves a pairing and returns its server's ID.
    private func store(_ p: Pairing) -> UUID {
        let id: UUID
        if let i = servers.firstIndex(where: { $0.pairing.key == p.key }) {
            servers[i].pairing = p
            id = servers[i].id
        } else {
            var name = p.host
            if servers.contains(where: { $0.name == name }) { name = p.base }
            let s = Server(name: name, pairing: p)
            servers.append(s)
            id = s.id
        }
        Keychain.save(servers)
        return id
    }

    func select(_ id: UUID) {
        guard id != current?.id, let s = servers.first(where: { $0.id == id }) else { return }
        show(s)
    }

    private func show(_ s: Server?) {
        current = s
        api = s.map { API(pairing: $0.pairing, server: $0.id) }
        me = nil
        UserDefaults.standard.set(s?.id.uuidString, forKey: Self.currentKey)
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].name = name
        if current?.id == id { current = servers[i] }
        Keychain.save(servers)
    }

    func move(from: IndexSet, to: Int) {
        servers.move(fromOffsets: from, toOffset: to)
        Keychain.save(servers)
    }

    /// Removes the token from this iPhone. Without servers left, the app
    /// returns to pairing.
    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        revoked.remove(id)
        health[id] = nil
        Keychain.save(servers)
        if current?.id == id { show(servers.first) }
    }

    func loadMe() async {
        guard let api, me == nil else { return }
        me = try? await api.get("/auth/me")
    }

    /// Fetches /status of every server for the switcher.
    func probeAll() async {
        let probes = servers.map { s in Task { await probe(s) } }
        for p in probes { await p.value }
    }

    private func probe(_ s: Server) async {
        do {
            let st: Status = try await API(pairing: s.pairing, server: s.id, timeout: 6).get("/status")
            report(st, for: s.id)
        } catch APIError.unauthorized {
            revoke(s.id)
        } catch {
            if servers.contains(where: { $0.id == s.id }) { health[s.id] = .unreachable(error.localizedDescription) }
        }
    }

    /// Records a server's status; an answer means its token works.
    func report(_ st: Status, for id: UUID) {
        guard servers.contains(where: { $0.id == id }) else { return }
        health[id] = ServerHealth(st)
        revoked.remove(id)
    }

    private func revoke(_ id: UUID) {
        guard servers.contains(where: { $0.id == id }) else { return }
        revoked.insert(id)
        health[id] = .revoked
    }

    /// Turns an error into a message. A refused token marks its server as
    /// revoked; the app then offers to pair it again or remove it.
    func message(for error: Error) -> String {
        if case APIError.unauthorized(let id) = error, let id {
            revoke(id)
        }
        return error.localizedDescription
    }

    /// Reports a kernel apply failure after a successful save.
    func reportApply(_ applyError: String?) {
        if let e = applyError, !e.isEmpty {
            alert = "Saved, but applying to WireGuard failed: " + e
        }
    }
}
