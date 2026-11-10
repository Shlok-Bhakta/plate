// The capture screen: opens straight into the camera. Shutter, then Send, is the whole flow; a note
// (typed or dictated) is optional. A photo from the library or a text-only description work the same way.
// Without a camera (the simulator) the demo shows its drawn plate; otherwise library and text still work.
import AVFoundation
import PhotosUI
import SwiftUI

struct CaptureView: View {
    var request: AgentCaptureRequest
    /// Hands back the run to start (the cover closes, then the job sheet opens).
    var onSend: (AgentRun) -> Void
    var onClose: () -> Void

    @Environment(Store.self) private var store
    @State private var camera = CameraSession()
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var mode: Mode = .camera
    @State private var photo: UIImage?
    @State private var prep: Task<PreparedPhoto?, Never>?
    @State private var note = ""
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var flash = false
    @State private var sending = false
    @State private var unreadable = false
    @FocusState private var noteFocused: Bool
    @FocusState private var textFocused: Bool

    enum Mode { case camera, review, text }

    private var useDemoCamera: Bool { !CameraSession.hasCamera && store.isDemo }
    private var cameraLive: Bool { CameraSession.hasCamera && status == .authorized }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch mode {
            case .camera: cameraLayer
            case .review: reviewLayer
            case .text: textLayer
            }
            Color.white.opacity(flash ? 0.85 : 0).ignoresSafeArea().allowsHitTesting(false)
        }
        .animation(Motion.smooth, value: mode)
        .statusBarHidden(mode != .text)
        .task {
            if case .text(let initial) = request.mode {
                text = initial
                mode = .text
                textFocused = true
            }
            if CameraSession.hasCamera && status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
            if cameraLive { camera.start() }
            // Debug: -PlateCaptureReview YES starts on the demo shot.
            if store.isDemo && UserDefaults.standard.bool(forKey: "PlateCaptureReview") { use(DemoPhoto.image) }
        }
        .onDisappear { camera.stop() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    use(img, data: data)
                } else {
                    unreadable = true
                }
                pickerItem = nil
            }
        }
        .alert("Couldn't open that photo", isPresented: $unreadable) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Camera

    private var cameraLayer: some View {
        ZStack {
            if cameraLive {
                CameraPreview(session: camera.session).ignoresSafeArea()
            } else if useDemoCamera {
                FilledImage(image: DemoPhoto.image)
                    .accessibilityLabel("Demo camera")
            } else {
                noCamera
            }
            VStack {
                topBar(leading: closeButton)
                Spacer()
                if cameraLive || useDemoCamera {
                    Text("Snap your meal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(.bottom, 18)
                }
                cameraControls
            }
        }
    }

    private var noCamera: some View {
        VStack(spacing: 14) {
            Image(systemName: status == .denied || status == .restricted ? "camera.fill" : "camera.metering.unknown")
                .font(.system(size: 46, weight: .light)).foregroundStyle(.white.opacity(0.7))
            Text(status == .denied || status == .restricted ? "Camera access is off" : "No camera here")
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(status == .denied || status == .restricted
                 ? "Allow the camera in Settings to snap meals, or pick a photo or describe it below."
                 : "Pick a photo from your library, or describe the meal in a few words.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if status == .denied || status == .restricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.glass).controlSize(.large)
            }
        }
        .environment(\.colorScheme, .dark)
        .padding(.bottom, 80)
    }

    private var cameraControls: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(alignment: .center) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    sideLabel("photo.on.rectangle", "Library")
                }
                .accessibilityLabel("Choose from library")
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                        Circle().fill(.white).frame(width: 64, height: 64)
                    }
                    .opacity(cameraLive || useDemoCamera ? 1 : 0.35)
                    .contentShape(Circle())
                }
                .buttonStyle(ShutterStyle())
                .disabled(!(cameraLive || useDemoCamera))
                .accessibilityLabel("Take photo")
                Spacer()
                Button {
                    mode = .text
                    textFocused = true
                } label: { sideLabel("character.cursor.ibeam", "Describe") }
                .buttonStyle(.plain)
                .accessibilityLabel("Describe instead")
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 24)
        }
    }

    private func sideLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .glassEffect(.regular.interactive(), in: .circle)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
    }

    private func shoot() {
        Haptics.medium()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.3).delay(0.08)) { flash = false }
        if useDemoCamera {
            use(DemoPhoto.image)
            return
        }
        Task {
            guard let data = await camera.capture(), let img = UIImage(data: data) else {
                Haptics.warning()
                return
            }
            use(img, data: data)
        }
    }

    /// The shot (or picked photo) is in; preparing starts at once, so Send rarely waits.
    private func use(_ image: UIImage, data: Data? = nil) {
        photo = image
        let raw = data ?? PhotoPrep.data(from: image)
        prep = Task { raw == nil ? nil : await PhotoPrep.prepare(raw!) }
        camera.stop()
        mode = .review
    }

    // MARK: Review

    private var reviewLayer: some View {
        ZStack {
            if let photo {
                FilledImage(image: photo)
                    .onTapGesture { noteFocused = false }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                topBar(leading: retakeButton)
                Spacer()
                sendBar(placeholder: "Add a note, like “only half the rice”", text: $note, focus: $noteFocused,
                        enabled: true)
            }
        }
    }

    private var retakeButton: some View {
        Button {
            photo = nil
            prep?.cancel()
            prep = nil
            note = ""
            mode = .camera
            if cameraLive { camera.start() }
        } label: {
            Label("Retake", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 44)
        }
        .foregroundStyle(.white)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: Text

    private var textLayer: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
                .onTapGesture { textFocused = true }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if case .text = request.mode { closeButton } else {
                        Button {
                            textFocused = false
                            mode = .camera
                            if cameraLive { camera.start() }
                        } label: {
                            Image(systemName: "camera.fill").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                        }
                        .foregroundStyle(.primary)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Back to camera")
                    }
                    Spacer()
                    Text(request.meal.title).font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, Space.l)
                .padding(.top, 8)
                Text("What did you eat?")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, Space.l + 4)
                    .padding(.top, 28)
                Text("A few words is enough. Plate finds the foods and sizes, and you check them before anything is logged.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.l + 4)
                    .padding(.top, 6)
                TextField("2 enchiladas, rice and a Diet Coke", text: $text, axis: .vertical)
                    .scaledFont(24, .medium, relativeTo: .title2)
                    .lineLimit(2...8)
                    .focused($textFocused)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .padding(.horizontal, Space.l + 4)
                    .padding(.top, 28)
                Spacer()
                Button(action: send) {
                    HStack(spacing: 8) {
                        if sending { ProgressView().tint(.white) }
                        Text("Send").font(.headline)
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .padding(.horizontal, Space.l)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: Shared

    private func topBar<L: View>(leading: L) -> some View {
        HStack {
            leading
            Spacer()
            if mode == .review { closeButton }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, 8)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
        }
        .foregroundStyle(mode == .text ? Color.primary : .white)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Close")
    }

    private func sendBar(placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding, enabled: Bool) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(placeholder, text: text, axis: .vertical)
                    .lineLimit(1...4)
                    .focused(focus)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .frame(minHeight: 50)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 25, style: .continuous))
                Button(action: send) {
                    ZStack {
                        if sending { ProgressView().tint(.white) } else {
                            Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold))
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(!enabled || sending)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, 12)
        }
        .environment(\.colorScheme, .dark)
    }

    private func send() {
        guard !sending else { return }
        let input = AgentJobInput(image: nil, text: nil, meal: request.meal, day: request.day)
        if mode == .text {
            var i = input
            i.text = text
            guard !i.isEmpty else { return }
            Haptics.light()
            onSend(AgentRun(input: i, thumbnail: nil))
            return
        }
        guard let photo else { return }
        sending = true
        Haptics.light()
        let pending = prep
        Task {
            guard let prepared = await pending?.value else {
                sending = false
                unreadable = true
                return
            }
            onSend(AgentRun(input: PhotoPrep.input(prepared, note: note, meal: request.meal, day: request.day), thumbnail: photo))
        }
    }
}

/// A photo filling the screen edge to edge without widening the layout around it.
private struct FilledImage: View {
    var image: UIImage
    var body: some View {
        Color.clear
            .overlay { Image(uiImage: image).resizable().scaledToFill() }
            .clipped()
            .ignoresSafeArea()
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
