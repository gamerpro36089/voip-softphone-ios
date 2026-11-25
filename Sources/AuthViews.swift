import SwiftUI

struct AuthGateView: View {
    @EnvironmentObject var store: PBXStore
    @State private var isSignup = false
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var department = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Serverless MeshPBX", systemImage: "phone.connection.fill")
                            .font(.title2.bold())
                        Text("Every iPhone runs its own lightweight VoIP server over local Wi-Fi or mesh VPN.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    Picker("Mode", selection: $isSignup) {
                        Text("Sign In").tag(false)
                        Text("Create Account").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section(isSignup ? "New Account" : "Credentials") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    if isSignup {
                        TextField("Display Name", text: $displayName)
                        TextField("Department (Optional)", text: $department)
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    Button {
                        if isSignup {
                            errorMessage = store.signUp(
                                username: username,
                                password: password,
                                displayName: displayName,
                                department: department
                            )
                        } else {
                            errorMessage = store.signIn(username: username, password: password)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text(isSignup ? "Create Account & Start Server" : "Sign In & Start Server")
                                .font(.headline)
                            Spacer()
                        }
                    }
                }

                Section("Default Super Admin") {
                    LabeledContent("Username", value: "admin")
                    LabeledContent("Password", value: "admin")
                    LabeledContent("Extension", value: "100")
                    Button("Fill Admin Credentials") {
                        isSignup = false
                        username = "admin"
                        password = "admin"
                    }
                }
            }
            .navigationTitle("MeshPBX Phone")
        }
    }
}
