// DESIGN 4.4 barcode scanner: VisionKit DataScannerViewController (EAN-13, EAN-8, UPC-E, Code 128)
// without the system highlight, a reticle that snaps to the code, lookup, and a glass result card.
// Handles unsupported devices (and the simulator) with manual entry, and a denied camera.
import AVFoundation
import SwiftUI
import Vision
import VisionKit

struct DataScannerView: UIViewControllerRepresentable {
    var paused: Bool
    var torch: Bool
    var onCode: (String, CGRect) -> Void
    var onBounds: (CGRect?) -> Void
    /// Food packages by default; onboarding's setup link scanner reads QR codes.
    var symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce, .code128]

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: symbologies)],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true, isGuidanceEnabled: false, isHighlightingEnabled: false)
        vc.delegate = context.coordinator
        DispatchQueue.main.async { try? vc.startScanning() }
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        if !paused && !vc.isScanning { try? vc.startScanning() }
        setTorch(torch)
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch,
              (device.torchMode == .on) != on, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: DataScannerView
        init(parent: DataScannerView) { self.parent = parent }

        private func rect(_ b: RecognizedItem.Bounds) -> CGRect {
            let xs = [b.topLeft.x, b.topRight.x, b.bottomLeft.x, b.bottomRight.x]
            let ys = [b.topLeft.y, b.topRight.y, b.bottomLeft.y, b.bottomRight.y]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !parent.paused else { return }
            for item in items {
                if case .barcode(let code) = item, let value = code.payloadStringValue, !value.isEmpty {
                    parent.onCode(value, rect(code.bounds))
                    return
                }
            }
        }

        func dataScanner(_ s: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) {
            if case .barcode(let code)? = items.first { parent.onBounds(rect(code.bounds)) }
        }

        func dataScanner(_ s: DataScannerViewController, didRemove items: [RecognizedItem], allItems: [RecognizedItem]) {
            if allItems.isEmpty { parent.onBounds(nil) }
        }
    }
}

@MainActor
enum CameraAccess {
    static var isScannerAvailable: Bool { DataScannerViewController.isSupported }
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
}

/// The scanner used by the Add flow. `onClose(route)` dismisses, optionally pushing a route in the sheet.
struct BarcodeScannerView: View {
    var meal: Meal
    var day: String
    var onClose: (AddRoute?) -> Void

    @Environment(Store.self) private var store
    @Environment(\.units) private var units
    @Namespace private var glass
    @State private var phase: Phase = .idle
    @State private var servings = 1.0
    @State private var reticle: CGRect?
    @State private var torch = false
    @State private var status = CameraAccess.status
    @State private var pulse = false
    @State private var added = false
    @State private var manual = ""

    enum Phase: Equatable {
        case idle
        case looking(String)
        case found(Food, String)
        case notFound(String)
        case offline(String)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !CameraAccess.isScannerAvailable {
                unsupported
            } else if status == .denied || status == .restricted {
                denied
            } else if status == .authorized {
                DataScannerView(paused: phase != .idle, torch: torch, onCode: detected, onBounds: { r in
                    if phase == .idle { withAnimation(.spring(duration: 0.3)) { reticle = r } }
                })
                .ignoresSafeArea()
                reticleOverlay
            }
            overlay
        }
        .toastHost(bottom: 200)
        .task {
            if CameraAccess.isScannerAvailable && status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = CameraAccess.status
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: phase.isLooking)
        .statusBarHidden()
    }

    // MARK: Pieces

    private var reticleOverlay: some View {
        GeometryReader { g in
            let base = CGRect(x: (g.size.width - 264) / 2, y: g.size.height * 0.36 - 80, width: 264, height: 160)
            let frame = (reticle.map { $0.insetBy(dx: -16, dy: -16) } ?? base)
            ZStack {
                Color.black.opacity(0.35)
                    .mask {
                        Rectangle().overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                ReticleCorners()
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(phase == .idle ? (pulse ? 1 : 0.6) : 1)
                Text("Point at a barcode")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .position(x: g.size.width / 2, y: base.maxY + 36)
                    .opacity(phase == .idle ? 1 : 0)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true } }
    }

    private var overlay: some View {
        GlassEffectContainer(spacing: 20) {
            VStack {
                HStack {
                    Button { onClose(nil) } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Close")
                    Spacer()
                    if CameraAccess.isScannerAvailable && status == .authorized {
                        Button { torch.toggle() } label: {
                            Image(systemName: torch ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                        }
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel(torch ? "Torch off" : "Torch on")
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Space.l)
                Spacer()
                bottom
                    .padding(.horizontal, Space.l)
                    .padding(.bottom, 16)
            }
        }
        .animation(Motion.morph, value: phase)
    }

    @ViewBuilder private var bottom: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .looking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up…").font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 18).frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("result", in: glass)
        case .found(let food, _):
            resultCard(food)
        case .notFound(let code):
            messageCard("Not found in Open Food Facts", detail: code) {
                Button("Create food") { onClose(.create(name: "", barcode: code)) }
                    .buttonStyle(.glassProminent).tint(Palette.accent)
                Button("Search instead") { onClose(nil) }.buttonStyle(.glass)
            }
        case .offline(let code):
            messageCard("Can't look up barcodes offline", detail: code) {
                Button("Scan again") { resume() }.buttonStyle(.glass)
            }
        }
    }

    private func resultCard(_ food: Food) -> some View {
        let kcal = (food.kcal ?? 0) * servings
        return VStack(alignment: .leading, spacing: 12) {
            Button { onClose(.food(food)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(food.name).font(.headline).lineLimit(2)
                        Spacer()
                        if food.favorite { Image(systemName: "star.fill").foregroundStyle(Palette.accent) }
                    }
                    Text("\(food.servingLabel(units)) · \(Fmt.kcal(food.kcal)) kcal")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack {
                HStack(spacing: 2) {
                    Button { servings = max(0.25, servings - 0.25); Haptics.selection() } label: {
                        Image(systemName: "minus").frame(width: 40, height: 36)
                    }
                    Text(Fmt.trim(servings)).numberFont(17, .semibold).frame(minWidth: 36)
                        .contentTransition(.numericText(value: servings))
                    Button { servings += 0.25; Haptics.selection() } label: {
                        Image(systemName: "plus").frame(width: 40, height: 36)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    guard !added else { return }
                    guard Actions.log(food, servings: servings, meal: meal, day: day, source: "barcode") != nil else {
                        resume()
                        return
                    }
                    Haptics.success()
                    withAnimation(.bouncy) { added = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        resume()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if added { Image(systemName: "checkmark").transition(.scale) }
                        Text(added ? "Added" : "Add · \(Fmt.whole(kcal)) kcal").monospacedDigit()
                            .contentTransition(.numericText(value: kcal))
                    }
                    .font(.headline)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(added)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 32, style: .continuous))
        .glassEffectID("result", in: glass)
    }

    private func messageCard<B: View>(_ title: String, detail: String, @ViewBuilder buttons: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 10) { buttons() }.controlSize(.large)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 32, style: .continuous))
        .glassEffectID("result", in: glass)
    }

    private var unsupported: some View {
        VStack(spacing: 16) {
            Image(systemName: "barcode.viewfinder").font(.system(size: 54, weight: .light)).foregroundStyle(.white.opacity(0.7))
            Text("Scanning needs a camera").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("This device can't scan barcodes. Type the number instead.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            HStack {
                TextField("Barcode", text: $manual)
                    .keyboardType(.numberPad)
                    .font(.body.monospaced())
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white)
                Button("Look up") { detected(manual, .zero) }
                    .buttonStyle(.glassProminent).tint(Palette.accent)
                    .disabled(manual.count < 6)
            }
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 120)
        .environment(\.colorScheme, .dark)
    }

    private var denied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 48)).foregroundStyle(.white.opacity(0.7))
            Text("Camera access is off").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("Plate uses the camera to read barcodes on food packages and to snap meals.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.glassProminent).tint(Palette.accent).controlSize(.large)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Flow

    private func detected(_ code: String, _ bounds: CGRect) {
        guard phase == .idle || !CameraAccess.isScannerAvailable else { return }
        if bounds != .zero { withAnimation(.spring(duration: 0.3)) { reticle = bounds } }
        servings = 1
        added = false
        phase = .looking(code)
        Task { @MainActor in
            do {
                if let food = try await store.lookup(barcode: code) {
                    phase = .found(food, code)
                } else {
                    phase = .notFound(code)
                }
            } catch {
                phase = .offline(code)
            }
        }
    }

    private func resume() {
        withAnimation(.smooth) {
            phase = .idle
            reticle = nil
            added = false
        }
    }
}

private extension BarcodeScannerView.Phase {
    var isLooking: Bool { if case .looking = self { return true }; return false }
}

/// Four 24 pt corner arms of the reticle.
struct ReticleCorners: Shape {
    func path(in r: CGRect) -> Path {
        let arm: CGFloat = 24, radius: CGFloat = 20
        var p = Path()
        // top left
        p.move(to: CGPoint(x: r.minX, y: r.minY + arm + radius))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + radius + arm, y: r.minY))
        // top right
        p.move(to: CGPoint(x: r.maxX - radius - arm, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius + arm))
        // bottom right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - radius - arm))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - radius - arm, y: r.maxY))
        // bottom left
        p.move(to: CGPoint(x: r.minX + radius + arm, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius - arm))
        return p
    }
}

/// Barcode capture for the custom food form: returns the first code read, or nil when closed.
struct BarcodeCaptureView: View {
    var onCode: (String?) -> Void
    @State private var status = CameraAccess.status
    @State private var manual = ""
    /// The scanner reports a code on every detection; only the first one counts. Each presentation is a
    /// new view, so this re-arms whenever the capture opens again.
    @State private var fired = false

    private func deliver(_ code: String?) {
        guard !fired else { return }
        fired = true
        onCode(code)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if CameraAccess.isScannerAvailable && status == .authorized {
                DataScannerView(paused: fired, torch: false, onCode: { code, _ in
                    guard !fired else { return }
                    Haptics.medium()
                    deliver(code)
                }, onBounds: { _ in })
                .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    Text(status == .denied ? "Camera access is off" : "Type the barcode")
                        .font(.headline).foregroundStyle(.white)
                    TextField("Barcode", text: $manual)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 40)
                    Button("Use") { deliver(manual) }.buttonStyle(.glassProminent).tint(Palette.accent)
                        .disabled(manual.isEmpty)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { onCode(nil) } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .foregroundStyle(.white)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(Space.l)
        }
        .environment(\.colorScheme, .dark)
        .task {
            if CameraAccess.isScannerAvailable && status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = CameraAccess.status
            }
        }
    }
}
