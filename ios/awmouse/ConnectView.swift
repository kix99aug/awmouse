import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var client: Client
    @State private var scanning = false
    @State private var scanProblem: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("awmouse")
                .font(.largeTitle.weight(.semibold))

            Text("Open awmouse on your computer and scan the code it shows.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            switch client.state {
            case .connecting:
                ProgressView("Connecting…")

            case .needsRescan:
                Text("That code has expired. Scan the computer's screen again — it shows a fresh one every minute.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                scanButton

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                scanButton
                if let last = client.lastTarget {
                    Button("Try \(last.address.prefix(8))… again") { client.connect(to: last) }
                        .font(.footnote)
                }

            default:
                scanButton
            }

            if let scanProblem {
                Text(scanProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(24)
        .onAppear {
            // A paired phone needs no code, so reconnecting to the last
            // computer is silent — and it is what the user wants nine times in
            // ten. The scan button is there for the tenth.
            if case .disconnected = client.state, let last = client.lastTarget {
                client.connect(to: last)
            }
        }
        .sheet(isPresented: $scanning) {
            ScannerView { value in
                scanning = false
                guard let url = URL(string: value), let target = Target(pairingLink: url) else {
                    scanProblem = "That isn't an awmouse code."
                    return
                }
                scanProblem = nil
                client.connect(to: target)
            }
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button { scanning = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding()
                }
            }
        }
    }

    private var scanButton: some View {
        Button {
            scanProblem = nil
            scanning = true
        } label: {
            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
