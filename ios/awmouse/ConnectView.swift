import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var client: Client
    @State private var urlText: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("awmouse")
                .font(.largeTitle.weight(.semibold))

            Text("Open awmouse on your computer, then scan its QR code — or "
                 + "paste the address it shows.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("tc… address from the computer", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            Button("Connect") {
                if let target = Target(parsing: urlText) {
                    client.connect(to: target)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(Target(parsing: urlText) == nil)

            if case .failed(let message) = client.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if case .connecting = client.state {
                ProgressView()
            }

            Spacer()
        }
        .padding(24)
        .onAppear {
            if urlText.isEmpty { urlText = client.lastTarget }
        }
    }
}
