import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var client: Client
    @State private var scanning = false
    @State private var scanProblem: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("awmouse")
                .font(.largeTitle.weight(.semibold))
                .padding(.top, 24)

            message

            if client.hosts.isEmpty {
                Spacer()
                scanButton
                Spacer()
            } else {
                // A list rather than a stack of buttons: swipe-to-delete comes
                // with it, and forgetting a computer needs somewhere to live.
                List {
                    Section("Computers") {
                        ForEach(client.hosts) { host in
                            Button { client.connect(to: host) } label: { row(host) }
                                .disabled(isConnecting)
                        }
                        .onDelete { offsets in
                            offsets.map { client.hosts[$0] }.forEach(client.forget)
                        }
                    }
                    Section {
                        Button { beginScan() } label: {
                            Label("Add another computer", systemImage: "qrcode.viewfinder")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .onAppear {
            // A paired phone needs no code, so reconnecting to the most recent
            // computer is silent — and it is what the user wants nine times in
            // ten. The list is there for the tenth, and Disconnect is honoured:
            // reconnectIfNeeded declines after a deliberate one.
            client.reconnectIfNeeded()
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

    private var isConnecting: Bool {
        if case .connecting = client.state { return true }
        return false
    }

    /// One line saying where things stand. A failure names the computer it
    /// was for, because with several known the interesting part of "couldn't
    /// connect" is which one.
    @ViewBuilder private var message: some View {
        switch client.state {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                Text("Connecting to \(client.attempting?.name ?? "your computer")…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

        case .needsRescan:
            note("That computer doesn't recognise this phone any more. Scan its QR code again.", .orange)

        case .failed(let why):
            note("\(client.attempting?.name ?? "That computer"): \(why)", .red)

        default:
            note(client.hosts.isEmpty
                 ? "Open awmouse on your computer and scan the code it shows."
                 : "Pick a computer, or add another.", .secondary)
        }

        if let scanProblem {
            note(scanProblem, .red)
        }
    }

    private func note(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(colour)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private func row(_ host: KnownHost) -> some View {
        HStack {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .foregroundStyle(.primary)
                Text(host.lastUsed, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if host.address == client.attempting?.address, isConnecting {
                ProgressView()
            }
        }
    }

    private var scanButton: some View {
        Button { beginScan() } label: {
            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 24)
    }

    private func beginScan() {
        scanProblem = nil
        scanning = true
    }
}
