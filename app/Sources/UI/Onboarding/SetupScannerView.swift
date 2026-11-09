// Scans a plate://setup QR code (for example from `qrencode -t ansiutf8 "plate://setup?url=...&token=..."`
// on the server) with the barcode scanner's VisionKit view. Returns the link, or nil when closed.
import AVFoundation
import SwiftUI

struct SetupScannerView: View {
    var onLink: (SetupLink?) -> Void
    @State private var status = CameraAccess.status
    @State private var fired = false
    @State private var wrongCode = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if CameraAccess.isScannerAvailable && status == .authorized {
                DataScannerView(paused: fired, torch: false, onCode: { code, _ in read(code) }, onBounds: { _ in },
                                symbologies: [.qr])
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text(wrongCode ? "That QR code isn't a Plate setup link." : "Point the camera at the setup QR code.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 60)
                        .contentTransition(.opacity)
                        .animation(Motion.smooth, value: wrongCode)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: Space.m) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 44)).foregroundStyle(.white.opacity(0.7))
                    Text(status == .denied ? "Camera access is off" : "Scanning isn't available here")
                        .font(.headline).foregroundStyle(.white)
                    Text(status == .denied ? "Turn on the camera for Plate in the Settings app, or paste the setup link instead."
                                           : "This device can't scan codes. Paste the setup link instead.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { onLink(nil) } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .foregroundStyle(.white)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(Space.l)
            .accessibilityLabel("Close")
        }
        .environment(\.colorScheme, .dark)
        .task {
            if CameraAccess.isScannerAvailable && status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = CameraAccess.status
            }
        }
    }

    private func read(_ code: String) {
        guard !fired else { return }
        if let link = SetupLink.parse(code) {
            fired = true
            Haptics.medium()
            onLink(link)
        } else if !wrongCode {
            wrongCode = true
            Haptics.warning()
        }
    }
}
