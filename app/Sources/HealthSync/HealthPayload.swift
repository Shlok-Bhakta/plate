// What the app posts to the health service (`kind: "hk"`). Foundation only, so it can be tested on a Mac.
import Foundation

struct SampleRecord: Encodable {
    let type: String
    let start: String
    let end: String
    let value: Double?
    let category: String?
    let unit: String?
    let source: String
    let device: String?
    let metadata: [String: String]?
}

struct WorkoutRecord: Encodable {
    let activity_type: String
    let start: String
    let end: String
    let duration: Double
    let duration_unit: String
    let distance: Double?
    let distance_unit: String?
    let energy: Double?
    let energy_unit: String?
    let statistics: [[String: String]]?
    let metadata: [String: String]?
    let source: String
    let device: String?
}

struct Batch: Encodable {
    var kind = "hk"
    let label: String
    var samples: [SampleRecord] = []
    var workouts: [WorkoutRecord] = []
    var profile: [String: String]? = nil
}

enum HealthFormat {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    /// `2026-09-15 07:25:44 -0600`, the shape export.xml uses, so the server has one date parser.
    static func date(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func metadata(_ metadata: [String: Any]?) -> [String: String]? {
        guard let metadata, !metadata.isEmpty else { return nil }
        return metadata.mapValues { value in
            if let date = value as? Date { return Self.date(date) }
            return String(describing: value)
        }
    }
}
