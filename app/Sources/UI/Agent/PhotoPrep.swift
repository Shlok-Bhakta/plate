// Turns a shot or a picked photo into what a job sends: the 1024 px metadata-free JPEG (AgentImage), already
// base64-encoded, and the product barcodes Vision reads in it, off the main thread. It starts the moment the
// shutter is pressed (CaptureView), so by Send, while a note was typed, the upload is ready. One log line
// says how long it took and how big it is. Also the demo "photo" for `-PlateDemo`.
import SwiftUI
import UIKit
import Vision

struct PreparedPhoto: Sendable {
    var jpeg: Data
    /// `jpeg` as base64, for the job body.
    var base64: String
    var barcodes: [String]
}

enum PhotoPrep {
    /// nil when the data isn't an image ImageIO can read. The JPEG and the barcode scan run side by side.
    static func prepare(_ data: Data) async -> PreparedPhoto? {
        let started = Date()
        async let encoded: (jpeg: Data, base64: String, ms: Int)? = Task.detached(priority: .userInitiated) {
            let t = Date()
            guard let jpeg = AgentImage.prepare(data) else { return nil }
            let base64 = jpeg.base64EncodedString()
            return (jpeg, base64, Int(Date().timeIntervalSince(t) * 1000))
        }.value
        async let codes: [String] = Task.detached(priority: .utility) {
            // Barcodes read better from more pixels than the upload keeps.
            AgentImage.uprightImage(data, maxEdge: 2048).map(barcodes) ?? []
        }.value
        guard let e = await encoded else { return nil }
        let found = await codes
        let size = AgentImage.pixelSize(e.jpeg).map { "\($0.width)×\($0.height)" } ?? "?"
        print("Plate: photo encoded in \(e.ms) ms: \(size), \(e.jpeg.count / 1024) KB JPEG, \(e.base64.utf8.count / 1024) KB base64; "
              + "ready to send after \(Int(Date().timeIntervalSince(started) * 1000)) ms with \(found.count) barcode(s)")
        return PreparedPhoto(jpeg: e.jpeg, base64: e.base64, barcodes: found)
    }

    /// The job input with this photo attached (the JPEG, its base64 and the barcodes).
    static func input(_ p: PreparedPhoto, note: String?, meal: Meal, day: String) -> AgentJobInput {
        var i = AgentJobInput(image: p.jpeg, text: note, barcodes: p.barcodes, meal: meal, day: day)
        i.imageBase64 = p.base64
        return i
    }

    /// Digits of the product barcodes in the image (EAN, UPC, Code 128, ITF-14), for `barcodes`.
    nonisolated static func barcodes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean13, .ean8, .upce, .code128, .itf14]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        return AgentImage.barcodeDigits(payloads)
    }

    /// A camera or library image as JPEG data for `prepare` (ImageIO applies the orientation there).
    static func data(from image: UIImage) -> Data? { image.jpegData(compressionQuality: 0.95) }
}

// MARK: - Demo photo

/// The demo's meal "photo": a top-down plate of salmon, rice and avocado, drawn, so screenshots don't need
/// a camera. `-PlateDemoPhoto <path>` uses an image file instead (e.g. one copied into the app's Documents).
@MainActor
enum DemoPhoto {
    static var image: UIImage {
        if let path = UserDefaults.standard.string(forKey: "PlateDemoPhoto") {
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: path)
            if let img = UIImage(contentsOfFile: url.path) { return img }
        }
        if let cached { return cached }
        let renderer = ImageRenderer(content: DemoPlate().frame(width: 900, height: 1200))
        renderer.scale = 1
        let img = renderer.uiImage ?? UIImage()
        cached = img
        return img
    }
    private static var cached: UIImage?
}

private struct DemoPlate: View {
    var body: some View {
        ZStack {
            // A warm wooden table.
            LinearGradient(colors: [Color(red: 0.36, green: 0.25, blue: 0.17), Color(red: 0.24, green: 0.16, blue: 0.11)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(0..<14, id: \.self) { i in
                Rectangle().fill(Color.black.opacity(i % 3 == 0 ? 0.07 : 0.035))
                    .frame(width: 1400, height: CGFloat(4 + (i * 7) % 11))
                    .rotationEffect(.degrees(-8))
                    .offset(y: CGFloat(i) * 92 - 620)
            }
            // A linen napkin and a fork.
            RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.86, green: 0.83, blue: 0.76))
                .frame(width: 260, height: 760).rotationEffect(.degrees(-8)).offset(x: 400, y: 40)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            Capsule().fill(LinearGradient(colors: [.white.opacity(0.95), Color(white: 0.62)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 26, height: 560).rotationEffect(.degrees(-8)).offset(x: 395, y: 90)
            // The plate.
            Circle().fill(Color.black.opacity(0.45)).frame(width: 760, height: 760).blur(radius: 30).offset(x: -40, y: 40)
            Circle().fill(RadialGradient(colors: [Color(white: 0.99), Color(white: 0.9)], center: .center, startRadius: 120, endRadius: 380))
                .frame(width: 740, height: 740).offset(x: -50, y: 10)
            Circle().stroke(Color(white: 0.82), lineWidth: 3).frame(width: 520, height: 520).offset(x: -50, y: 10)
            Circle().fill(Color(white: 0.965)).frame(width: 516, height: 516).offset(x: -50, y: 10)
            // Rice.
            ZStack {
                Ellipse().fill(RadialGradient(colors: [Color(red: 1, green: 0.99, blue: 0.95), Color(red: 0.9, green: 0.87, blue: 0.79)],
                                              center: .init(x: 0.4, y: 0.35), startRadius: 10, endRadius: 190))
                    .frame(width: 330, height: 260)
                ForEach(0..<70, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: 16, height: 6)
                        .rotationEffect(.degrees(Double(i * 47 % 180)))
                        .offset(x: CGFloat((i * 53) % 260) - 130, y: CGFloat((i * 37) % 190) - 95)
                }
                ForEach(0..<9, id: \.self) { i in
                    Circle().fill(Color(red: 0.3, green: 0.55, blue: 0.25)).frame(width: 9, height: 9)
                        .offset(x: CGFloat((i * 71) % 220) - 110, y: CGFloat((i * 43) % 150) - 75)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
            .offset(x: -190, y: 130)
            // Salmon.
            ZStack {
                RoundedRectangle(cornerRadius: 70, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.38), Color(red: 0.86, green: 0.38, blue: 0.24)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 360, height: 190)
                ForEach(0..<6, id: \.self) { i in
                    Capsule().fill(Color(red: 1, green: 0.8, blue: 0.68).opacity(0.75))
                        .frame(width: 7, height: 150).rotationEffect(.degrees(24))
                        .offset(x: CGFloat(i) * 52 - 130)
                }
                RoundedRectangle(cornerRadius: 70, style: .continuous)
                    .stroke(Color(red: 0.55, green: 0.24, blue: 0.14).opacity(0.55), lineWidth: 10)
                    .frame(width: 360, height: 190)
                // Grill marks and herbs.
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Color(red: 0.45, green: 0.2, blue: 0.1).opacity(0.35))
                        .frame(width: 260, height: 12).rotationEffect(.degrees(-28)).offset(y: CGFloat(i) * 50 - 50)
                }
                ForEach(0..<7, id: \.self) { i in
                    Circle().fill(Color(red: 0.2, green: 0.42, blue: 0.18)).frame(width: 12, height: 12)
                        .offset(x: CGFloat((i * 61) % 280) - 140, y: CGFloat((i * 29) % 120) - 60)
                }
            }
            .frame(width: 360, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 70, style: .continuous))
            .rotationEffect(.degrees(-12))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
            .offset(x: 10, y: -110)
            // Avocado slices.
            ForEach(0..<4, id: \.self) { i in
                Ellipse()
                    .fill(LinearGradient(colors: [Color(red: 0.86, green: 0.9, blue: 0.5), Color(red: 0.55, green: 0.72, blue: 0.28)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(Ellipse().stroke(Color(red: 0.2, green: 0.35, blue: 0.12), lineWidth: 6))
                    .frame(width: 70, height: 170)
                    .rotationEffect(.degrees(Double(i) * 14 + 20))
                    .offset(x: CGFloat(i) * 46 + 60, y: 150 + CGFloat(i) * 8)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
            }
            // A lemon wedge.
            Circle().trim(from: 0, to: 0.5)
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.95, blue: 0.6), Color(red: 0.98, green: 0.82, blue: 0.2)],
                                     center: .center, startRadius: 10, endRadius: 80))
                .frame(width: 140, height: 140).rotationEffect(.degrees(200)).offset(x: 180, y: -260)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
        .frame(width: 900, height: 1200)
        .clipped()
    }
}
