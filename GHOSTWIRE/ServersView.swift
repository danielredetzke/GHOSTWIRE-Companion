import SwiftUI

extension ServerHealth? {
    /// Green: reachable, orange: checks failing, red: unreachable or
    /// revoked, grey: not asked yet.
    var dot: Color {
        switch self {
        case .ok: .gwGood
        case .failing: .gwUp
        case .unreachable, .revoked: .gwBad
        case nil: .gwText2.opacity(0.5)
        }
    }

    var summary: String {
        switch self {
        case .ok(let on, let total, _): "\(on) / \(total) online"
        case .failing(let n, let on, let total, _): (n == 1 ? "1 check failing" : "\(n) checks failing") + " · \(on) / \(total) online"
        case .unreachable: "Not reachable"
        case .revoked: "Token revoked"
        case nil: "Checking…"
        }
    }
}

/// The logo and the current server's name; opens the switcher.
struct ServerChip: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Button { session.showServers = true } label: {
            HStack(spacing: 8) {
                HannyaMark(size: 26)
                Circle().fill(session.health[session.current?.id ?? UUID()].dot).frame(width: 8, height: 8)
                Text(session.current?.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Color.gwText2)
            }
            .foregroundStyle(Color.gwText)
        }
        .accessibilityLabel("Server: \(session.current?.name ?? ""). Switch server")
        .accessibilityIdentifier("serverChip")
    }
}

extension View {
    /// The server chip at the leading edge of a tab's navigation bar.
    func serverToolbar() -> some View {
        toolbar { ToolbarItem(placement: .topBarLeading) { ServerChip() } }
    }
}

/// All paired servers: switch, add, rename, reorder and remove.
struct ServersView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var renaming: Server?
    @State private var newName = ""
    @State private var removing: Server?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.servers) { s in
                        Button {
                            session.select(s.id)
                            dismiss()
                        } label: { row(s) }
                        .accessibilityIdentifier("server-\(s.name)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { removing = s } label: { Label("Remove", systemImage: "trash") }
                                .tint(Color.gwBad)
                        }
                        .swipeActions(edge: .leading) {
                            Button { newName = s.name; renaming = s } label: { Label("Rename", systemImage: "pencil") }
                                .tint(.gray)
                        }
                        .contextMenu {
                            Button { newName = s.name; renaming = s } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { removing = s } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    .onMove { session.move(from: $0, to: $1) }
                } footer: {
                    if session.servers.contains(where: { session.health[$0.id]?.tunnel == true }) {
                        Text("“Your tunnel” marks the server this iPhone's traffic goes out through.")
                    }
                }
                Section {
                    Button { adding = true } label: { Label("Add server", systemImage: "plus") }
                        .accessibilityIdentifier("addServer")
                } footer: {
                    Text("Swipe a server to rename or remove it.")
                }
            }
            .groundBackground()
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await session.probeAll() }
            .task { await session.probeAll() }
            .sheet(isPresented: $adding) {
                PairingView(asSheet: true) {
                    adding = false
                    dismiss()
                }
            }
            .alert("Rename server", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { s in
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { session.rename(s.id, to: newName) }
            } message: { _ in
                Text("The name is used in this app only.")
            }
            .confirmationDialog("Remove server?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { s in
                Button("Remove \(s.name)", role: .destructive) { session.remove(s.id) }
            } message: { _ in
                Text("The token is removed from this iPhone. Revoke it in the web interface too.")
            }
        }
    }

    private func row(_ s: Server) -> some View {
        let h = session.health[s.id]
        return HStack(spacing: 12) {
            Circle().fill(h.dot).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.body.weight(.semibold)).foregroundStyle(Color.gwText)
                Text((s.name == s.pairing.host ? "" : s.pairing.host + " · ") + h.summary)
                    .font(.caption)
                    .foregroundStyle(Color.gwText2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if h?.tunnel == true { Pill(text: "Your tunnel", fg: .gwGood, bg: Color.gwGood.opacity(0.14)) }
            if case .revoked = h { Pill(text: "Revoked", fg: .gwErrInk, bg: .gwErrBg) }
            if case .failing = h { Pill(text: "Check", fg: .gwWarnInk, bg: .gwWarnBg) }
            if s.id == session.current?.id {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.gwDown)
                    .accessibilityLabel("Shown")
            }
        }
        .contentShape(Rectangle())
    }
}

private struct Pill: View {
    let text: String
    let fg: Color
    let bg: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
            .fixedSize()
    }
}

/// Shown in place of the tabs when the server refused this iPhone's token.
struct RevokedView: View {
    @Environment(AppSession.self) private var session
    let server: Server
    @State private var pairing = false
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Notice(text: "\(server.name) no longer accepts this iPhone. Its token was revoked in the web interface. Pair it again with a new QR code from Settings → Pair iOS app, or remove the server."
                           + (session.servers.count > 1 ? " Your other servers are not affected." : ""), isError: true)
                    Button("Pair again") { pairing = true }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Remove \(server.name)") { confirmRemove = true }
                        .buttonStyle(SecondaryButtonStyle(ink: .gwErrInk))
                    if session.servers.count > 1 {
                        Button("Switch server") { session.showServers = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(16)
            }
            .background(Color.gwGround)
            .navigationTitle("Not paired")
            .serverToolbar()
            .sheet(isPresented: $pairing) { PairingView(asSheet: true) { pairing = false } }
            .confirmationDialog("Remove server?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove \(server.name)", role: .destructive) { session.remove(server.id) }
            } message: {
                Text("The revoked token is removed from this iPhone.")
            }
        }
    }
}
