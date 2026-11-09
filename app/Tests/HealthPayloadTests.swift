// The health upload's payload and date format (Sources/HealthSync/HealthPayload.swift), compiled alone on
// the Mac by ios-test.sh. Carried over unchanged from the Personal Health app's ios-test.sh.
import Foundation
let date = Date(timeIntervalSince1970: 1_762_441_200)
let text = HealthFormat.date(date)
precondition(text.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}$"#, options: .regularExpression) != nil, "date shape: \(text)")
var batch = Batch(label: "HKQuantityTypeIdentifierHeartRate")
batch.samples = [SampleRecord(type: "HKQuantityTypeIdentifierHeartRate", start: text, end: text, value: 61, category: nil,
                              unit: "count/min", source: "Watch", device: nil, metadata: HealthFormat.metadata(["k": 1, "d": date]))]
let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as! [String: Any]
precondition(json["kind"] as? String == "hk")
let sample = (json["samples"] as! [[String: Any]])[0]
precondition(sample["value"] as? Double == 61 && sample["unit"] as? String == "count/min")
precondition((sample["metadata"] as! [String: String])["d"] == text)
print("payload tests ok")
