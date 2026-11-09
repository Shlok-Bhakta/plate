// The meal camera: an AVCaptureSession with a photo output on its own queue, and a preview layer view.
// One shot returns the photo's file data; AgentImage re-encodes it before anything is sent.
import AVFoundation
import SwiftUI
import UIKit

final class CameraSession: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "plate.meal-camera")
    private var configured = false
    private var pending: CheckedContinuation<Data?, Never>?

    static var hasCamera: Bool { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil }

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if configured && !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        output.maxPhotoQualityPrioritization = .balanced
        session.commitConfiguration()
        configured = true
    }

    /// One photo's data (JPEG), or nil if the camera couldn't take it.
    func capture() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            queue.async { [self] in
                guard configured, session.isRunning, pending == nil else { c.resume(returning: nil); return }
                pending = c
                if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                let settings = output.availablePhotoCodecTypes.contains(.jpeg)
                    ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) : AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        queue.async { [self] in
            pending?.resume(returning: data)
            pending = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    var session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
