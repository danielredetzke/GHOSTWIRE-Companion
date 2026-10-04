import SwiftUI

// Users, the signed-in user's account and API tokens. Full-access tokens may
// manage all of these; backups stay in the web interface.

nonisolated struct LastUse: Decodable, Hashable {
    let at: Date
    let ip: String
}

nonisolated struct UserInfo: Decodable, Identifiable, Hashable {
    let id: String
    let username: String
    let note: String
    let mustChangePassword: Bool
    let created: Date
    let lastLogin: LastUse?
    let tokens: Int
    let you: Bool
    let mfa: MFASummary?  // nil on servers without two-step sign-in
}

/// A user's two-step sign-in methods.
nonisolated struct MFASummary: Decodable, Hashable {
    let totp: Bool
    let keys: Int
    let passkeys: Int

    /// "App, 1 key" or "" when off.
    var text: String {
        var parts: [String] = []
        if totp { parts.append("App") }
        if keys > 0 { parts.append(keys == 1 ? "1 key" : "\(keys) keys") }
        if passkeys > 0 { parts.append(passkeys == 1 ? "1 passkey" : "\(passkeys) passkeys") }
        return parts.joined(separator: ", ")
    }
}

nonisolated struct UsersResponse: Decodable {
    let users: [UserInfo]
}

nonisolated struct UserResult: Decodable {
    let user: UserInfo
}

nonisolated struct TokenInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let scope: String
    let owner: String
    let ownerId: String
    let created: Date
    let lastUsed: LastUse?
}

nonisolated struct TokensResponse: Decodable {
    let tokens: [TokenInfo]
}

nonisolated struct TokenCreated: Decodable, Identifiable {
    let token: String
    let id: String
    let name: String
    let scope: String
    let pairing: String
    let qr: String
}

nonisolated struct OKResult: Decodable {
    let ok: Bool
}

private func lastUse(_ u: LastUse?) -> String {
    u.map { "\(ago($0.at)) · \($0.ip)" } ?? "Not since restart"
}

// MARK: - Users

struct UsersView: View {
    @Environment(AppSession.self) private var session
    @State private var users: [UserInfo] = []
    @State private var error: String?
    @State private var adding = false
    @State private var editing: UserInfo?
    @State private var required: Bool?

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(Color.gwErrInk) }
            }
            Section {
                ForEach(users) { u in
                    if u.you {
                        NavigationLink { AccountView() } label: { row(u) }
                    } else {
                        Button { editing = u } label: { row(u) }
                            .foregroundStyle(Color.gwText)
                    }
                }
            } footer: {
                Text("Everyone here is an admin. You cannot delete yourself, so one user always remains. Change your own details under My account.")
            }
            if let required {
                Section {
                    Toggle("Require two-step sign-in", isOn: Binding(get: { required }, set: { on in Task { await setRequired(on) } }))
                } footer: {
                    Text("Users without it set it up right after their next sign-in in the browser. Methods are added in the web interface under My account. This app is not affected.")
                }
            }
        }
        .groundBackground()
        .navigationTitle("Users")
        .toolbar {
            Button { adding = true } label: { Label("Add user", systemImage: "plus") }
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) { AddUserView() }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { UserEditView(user: $0) }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ u: UserInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(u.username).font(.body.weight(.semibold))
                if u.you {
                    Text("You").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.gwBadge, in: Capsule())
                }
                Spacer()
                if u.mustChangePassword {
                    Text("Must choose a password").font(.caption2.weight(.medium)).foregroundStyle(Color.gwWarnInk)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.gwWarnBg, in: Capsule())
                }
            }
            if !u.note.isEmpty { Text(u.note).font(.caption).foregroundStyle(Color.gwText2) }
            if let m = u.mfa {
                Text("Two-step sign-in: " + (m.text.isEmpty ? "off" : m.text)).font(.caption).foregroundStyle(Color.gwText2)
            }
            Text("Last sign-in: \(u.lastLogin.map { "\(ago($0.at)) · \($0.ip)" } ?? "not since restart") · \(u.tokens) app token\(u.tokens == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(Color.gwText2)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            let r: UsersResponse = try await api.get("/users")
            users = r.users
            if let s: SignInSettings = try? await api.get("/settings"), let si = s.signin { required = si.requireMfa }
            error = nil
        } catch {
            self.error = session.message(for: error)
        }
    }
}

struct AddUserView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var note = ""
    @State private var password = ""
    @State private var mustChange = true
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username).textContentType(.username)
                    TextField("Note (optional)", text: $note)
                } footer: {
                    Text("Letters, numbers, . @ _ - · max 32")
                }
                Section {
                    SecureField("Temporary password", text: $password).textContentType(.newPassword)
                    Toggle("Must choose a new password", isOn: $mustChange)
                } footer: {
                    Text("At least 12 characters. With the switch on, the user can do nothing but choose a new password at the first sign-in.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Color.gwErrInk) }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .groundBackground()
            .navigationTitle("Add user")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }.disabled(busy || username.isEmpty || password.isEmpty)
                }
            }
        }
    }

    private func add() async {
        guard let api = session.api else { return }
        busy = true
        defer { busy = false }
        do {
            let _: UserResult = try await api.send("POST", "/users", [
                "username": username.trimmingCharacters(in: .whitespaces), "note": note.trimmingCharacters(in: .whitespaces),
                "password": password, "mustChangePassword": mustChange,
            ])
            dismiss()
        } catch {
            self.error = session.message(for: error)
        }
    }
}

struct UserEditView: View {
    let user: UserInfo
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var note = ""
    @State private var mustChange = false
    @State private var newPassword = ""
    @State private var resetMustChange = true
    @State private var confirmDelete = false
    @State private var confirmResetMFA = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                    TextField("Note", text: $note)
                    Toggle("Must choose a new password", isOn: $mustChange)
                } footer: {
                    Text("Created \(fmtDate(user.created)) · last sign-in \(lastUse(user.lastLogin).lowercased())")
                }
                Section {
                    SecureField("New temporary password", text: $newPassword).textContentType(.newPassword)
                    Toggle("Must choose a new password", isOn: $resetMustChange)
                    Button("Reset password") { Task { await reset() } }.disabled(busy || newPassword.isEmpty)
                } header: {
                    Text("Reset password")
                } footer: {
                    Text("Signs \(user.username) out everywhere. App tokens keep working.")
                }
                if let m = user.mfa, !m.text.isEmpty {
                    Section {
                        LabeledContent("Methods", value: m.text)
                        Button("Reset two-step sign-in…", role: .destructive) { confirmResetMFA = true }.disabled(busy)
                    } header: {
                        Text("Two-step sign-in")
                    } footer: {
                        Text("For a lost phone or key. \(user.username) then signs in with their password and sets it up again.")
                    }
                }
                Section {
                    Button("Delete user…", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text(user.tokens > 0 ? "Their \(user.tokens) app token\(user.tokens == 1 ? " is" : "s are") revoked too." : "")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Color.gwErrInk) }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .groundBackground()
            .navigationTitle(user.username)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(busy || username.isEmpty)
                }
            }
            .confirmationDialog("Reset two-step sign-in?", isPresented: $confirmResetMFA, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { Task { await resetMFA() } }
            } message: {
                Text("The authenticator app, security keys, passkeys and recovery codes of \(user.username) are removed.")
            }
            .confirmationDialog("Delete \(user.username)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete user", role: .destructive) { Task { await delete() } }
            } message: {
                Text("They are signed out immediately and their app tokens stop working. This cannot be undone.")
            }
            .onAppear {
                username = user.username
                note = user.note
                mustChange = user.mustChangePassword
            }
        }
    }

    private func save() async {
        guard let api = session.api else { return }
        busy = true
        defer { busy = false }
        do {
            let _: UserResult = try await api.send("PATCH", "/users/\(user.id)", [
                "username": username.trimmingCharacters(in: .whitespaces), "note": note.trimmingCharacters(in: .whitespaces),
                "mustChangePassword": mustChange,
            ])
            dismiss()
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func reset() async {
        guard let api = session.api else { return }
        busy = true
        defer { busy = false }
        do {
            let _: OKResult = try await api.send("POST", "/users/\(user.id)/reset-password",
                                                 ["password": newPassword, "mustChangePassword": resetMustChange])
            session.alert = "Password of \(user.username) reset."
            dismiss()
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func resetMFA() async {
        guard let api = session.api else { return }
        busy = true
        defer { busy = false }
        do {
            let _: OKResult = try await api.send("POST", "/users/\(user.id)/reset-mfa")
            session.alert = "Two-step sign-in of \(user.username) reset."
            dismiss()
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func delete() async {
        guard let api = session.api else { return }
        busy = true
        defer { busy = false }
        do {
            let _: OKResult = try await api.send("DELETE", "/users/\(user.id)")
            dismiss()
        } catch {
            self.error = session.message(for: error)
        }
    }
}

nonisolated struct SignInSettings: Decodable {
    struct Rules: Decodable { let requireMfa: Bool }
    let signin: Rules?
}

extension UsersView {
    func setRequired(_ on: Bool) async {
        guard let api = session.api else { return }
        do {
            let _: SettingsResult = try await api.send("PATCH", "/settings", ["signin": ["requireMfa": on]])
            required = on
        } catch {
            self.error = session.message(for: error)
        }
    }
}

// MARK: - My account

struct AccountView: View {
    @Environment(AppSession.self) private var session
    @State private var me: AccountMe?
    @State private var username = ""
    @State private var note = ""
    @State private var current = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            if let error {
                Section { Text(error).foregroundStyle(Color.gwErrInk) }
            }
            if let me {
                Section {
                    TextField("Username", text: $username).textContentType(.username)
                    TextField("Note", text: $note)
                    Button("Save profile") { Task { await saveProfile(me) } }
                        .disabled(busy || username.isEmpty || (username == me.username && note == (me.note ?? "")))
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Your username is what you sign in with. Other admins see the note in the Users list." +
                         (me.created.map { " Account created \(fmtDate($0))." } ?? ""))
                }
                Section {
                    SecureField("Current password", text: $current).textContentType(.password)
                    SecureField("New password", text: $new1).textContentType(.newPassword)
                    SecureField("Repeat new password", text: $new2).textContentType(.newPassword)
                    Button("Change password") { Task { await changePassword() } }
                        .disabled(busy || current.isEmpty || new1.isEmpty || new2.isEmpty)
                } header: {
                    Text("Password")
                } footer: {
                    Text("At least 12 characters. Changing it signs you out in browsers. App tokens, including this iPhone's, keep working.")
                }
                Section {
                    NavigationLink("My app tokens") { TokensView(onlyMine: true) }
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .groundBackground()
        .navigationTitle("My account")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            let m: AccountMe = try await api.get("/auth/me")
            me = m
            username = m.username
            note = m.note ?? ""
            error = nil
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func saveProfile(_ m: AccountMe) async {
        guard let api = session.api else { return }
        busy = true
        defer { busy = false }
        var body: [String: Any?] = [:]
        if username.trimmingCharacters(in: .whitespaces) != m.username { body["username"] = username.trimmingCharacters(in: .whitespaces) }
        if note.trimmingCharacters(in: .whitespaces) != (m.note ?? "") { body["note"] = note.trimmingCharacters(in: .whitespaces) }
        do {
            let _: UserResult = try await api.send("PATCH", "/users/\(m.id)", body)
            session.alert = "Profile saved."
            await load()
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func changePassword() async {
        guard let api = session.api else { return }
        guard new1 == new2 else { error = "The new passwords do not match."; return }
        busy = true
        defer { busy = false }
        do {
            let _: OKResult = try await api.send("POST", "/auth/password", ["current": current, "new": new1])
            current = ""; new1 = ""; new2 = ""
            error = nil
            session.alert = "Password changed. Browsers are signed out."
        } catch {
            self.error = session.message(for: error)
        }
    }
}

/// The user behind this app's token, as /auth/me reports it.
nonisolated struct AccountMe: Decodable {
    let id: String
    let username: String
    let note: String?
    let created: Date?
    let tokenId: String?
}

// MARK: - API tokens

struct TokensView: View {
    var onlyMine = false
    @Environment(AppSession.self) private var session
    @State private var tokens: [TokenInfo] = []
    @State private var me: AccountMe?
    @State private var error: String?
    @State private var pairing = false
    @State private var revoking: TokenInfo?

    private var shown: [TokenInfo] {
        onlyMine ? tokens.filter { $0.ownerId == me?.id } : tokens
    }

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(Color.gwErrInk) }
            }
            Section {
                ForEach(shown) { t in
                    row(t)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { revoking = t } label: { Label("Revoke", systemImage: "trash") }
                                .tint(Color.gwBad)
                        }
                }
                if shown.isEmpty && error == nil {
                    Text(onlyMine ? "You have no app tokens." : "No API tokens.").font(.footnote).foregroundStyle(Color.gwText2)
                }
            } footer: {
                Text("For the iOS app and scripts. A token appears once when you create it, and only a hash is stored. Swipe left to revoke.")
            }
        }
        .groundBackground()
        .navigationTitle(onlyMine ? "My app tokens" : "API tokens")
        .toolbar {
            Button { pairing = true } label: { Label("Pair a device", systemImage: "plus") }
        }
        .sheet(isPresented: $pairing, onDismiss: { Task { await load() } }) { PairDeviceView() }
        .confirmationDialog("Revoke \(revoking?.name ?? "token")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { t in
            Button("Revoke", role: .destructive) { Task { await revoke(t) } }
        } message: { t in
            Text(t.id == me?.tokenId
                 ? "This is the token of this iPhone. The app disconnects and has to be paired again."
                 : "Apps using this token are signed out immediately.")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ t: TokenInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(t.name).font(.body.weight(.semibold))
                if t.id == me?.tokenId {
                    Text("This iPhone").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.gwBadge, in: Capsule())
                }
                Spacer()
                Text(t.scope == "ro" ? "Read only" : "Full access").font(.caption).foregroundStyle(Color.gwText2)
            }
            Text((onlyMine ? "" : "\(t.owner) · ") + "created \(fmtDate(t.created)) · used \(lastUse(t.lastUsed).lowercased())")
                .font(.caption)
                .foregroundStyle(Color.gwText2)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            async let t: TokensResponse = api.get("/tokens")
            async let m: AccountMe = api.get("/auth/me")
            (tokens, me) = try await (t.tokens, m)
            error = nil
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func revoke(_ t: TokenInfo) async {
        guard let api = session.api else { return }
        do {
            let _: OKResult = try await api.send("DELETE", "/tokens/\(t.id)")
            if t.id == me?.tokenId {
                session.disconnect()
                return
            }
            await load()
        } catch {
            self.error = session.message(for: error)
        }
    }
}

/// Creates a token and shows it once, with the pairing QR code for another
/// iPhone or iPad.
struct PairDeviceView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = "iPhone app"
    @State private var scope = "rw"
    @State private var created: TokenCreated?
    @State private var copied = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let c = created {
                    Section {
                        if let img = qrImage(c.qr) {
                            Image(uiImage: img)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 260)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Pairing QR code")
                        }
                        Button { UIPasteboard.general.string = c.pairing; copied = true } label: {
                            Label(copied ? "Copied" : "Copy pairing code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        KV(key: "Token", value: c.token, mono: true)
                    } footer: {
                        Text("Scan this with the GHOSTWIRE app on the other device. This is the only time the token is shown.")
                    }
                } else {
                    Section {
                        TextField("Name", text: $name)
                        Picker("Access", selection: $scope) {
                            Text("Full access").tag("rw")
                            Text("Read only").tag("ro")
                        }
                    } footer: {
                        Text("Read-only tokens can see everything but change nothing.")
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(Color.gwErrInk) }
                    }
                }
            }
            .groundBackground()
            .navigationTitle("Pair a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { await create() } }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(created != nil)
    }

    private func create() async {
        guard let api = session.api else { return }
        busy = true
        defer { busy = false }
        do {
            created = try await api.send("POST", "/tokens", ["name": name.trimmingCharacters(in: .whitespaces), "scope": scope])
        } catch {
            self.error = session.message(for: error)
        }
    }
}
