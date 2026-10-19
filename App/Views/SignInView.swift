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
                    Text("Your password goes only to Apple. A free Apple ID works.")
                }

                Section {
                    Toggle("Remember Password", isOn: $rememberPassword)
                } footer: {
                    Text("Lets Harbor sign in again by itself when Apple ends the session, so automatic renewals keep working. Kept only in this iPhone's keychain.")
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In") {
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
