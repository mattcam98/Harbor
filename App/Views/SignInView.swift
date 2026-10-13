import SwiftUI

struct SignInView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var appleID = ""
    @State private var password = ""
    @State private var rememberPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID", text: $appleID)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Your Apple ID and password are sent only to Apple. Harbor keeps the session Apple returns, in this device's keychain.")
                }

                Section {
                    Toggle("Remember password", isOn: $rememberPassword)
                } footer: {
                    Text("Off: when the session expires you sign in again. On: Harbor keeps the password in this device's keychain so it can renew the session by itself.")
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") {
                        let credentials = (appleID, password, rememberPassword)
                        password = ""
                        dismiss()
                        Task {
                            await model.signIn(
                                appleID: credentials.0, password: credentials.1, rememberPassword: credentials.2)
                        }
                    }
                    .disabled(appleID.isEmpty || password.isEmpty)
                }
            }
        }
    }
}
