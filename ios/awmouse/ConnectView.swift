import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var client: Client
    @State private var urlText: String = ""
    @State private var codeText: String = ""

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

            if case .needsCode(let target) = client.state {
                // First contact from this phone: the host wants the six digits
                // it is showing under its QR code.
                VStack(spacing: 10) {
                    Text("This computer hasn't seen this phone before. Enter the pairing code shown under its QR code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    TextField("000000", text: $codeText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .font(.system(.title2, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .onChange(of: codeText) { _, new in
                            codeText = String(new.filter(\.isNumber).prefix(6))
                        }
                    Button("Pair") { client.connect(to: target, code: codeText) }
                        .buttonStyle(.borderedProminent)
                        .disabled(codeText.count != 6)
                }
            } else {
                Button("Connect") {
                    if let target = Target(parsing: urlText) {
                        client.connect(to: target)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(Target(parsing: urlText) == nil)
            }

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
