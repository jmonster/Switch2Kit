import Foundation
import Switch2Kit

@main
struct SolverRegression {
    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid known-rate fixture was accepted") }
        catch { }
    }
    static func main() throws {
        let binding = try CaptureBinding(["00112233-4455-6677-8899-aabbccddeeff", "8297", "bt-report-v1", "0xa7", "fixture"])
        let means: [[Int]] = [[11, -7, 1003], [11, -7, -997], [-4989, -7, 3], [5011, -7, 3], [11, -2007, 3], [11, 1993, 3]]
        var windows = [[CalibrationSample]]()
        for mean in means {
            // Keep overload resolution bounded on Apple Swift as well as Linux Swift.
            let gyroFields = mean.map { String($0) }
            var window = [CalibrationSample]()
            for i in 0..<128 {
                let receivedAt = 10.0 + Double(i) * 0.01
                var fields = [String(i + 1), String(receivedAt), "0", "0", "1000"]
                fields.append(contentsOf: gyroFields)
                window.append(try CalibrationSample(fields))
            }
            windows.append(window)
        }
        let bytes = try knownRateReference(binding: binding, windows: windows, rate: 1, evidence: "Synthetic regression only")
        let reference = try GyroReference(data: bytes)
        precondition(reference.binding == binding && reference.basis == .knownRate)
        precondition(reference.calibration.xAxis == .positiveZ && reference.calibration.yAxis == .negativeX && reference.calibration.zAxis == .negativeY)
        for (actual, expected) in zip(components(reference.calibration.unitsPerCount), [0.0002, 0.0005, 0.001]) {
            precondition(abs(actual - expected) < 1e-12)
        }
        for rate in [0, -1, Double.infinity, Double.nan] {
            rejected { _ = try knownRateReference(binding: binding, windows: windows, rate: rate, evidence: "Fixture") }
        }
        for evidence in ["", "Injected\nrecord", String(repeating: "x", count: 513)] {
            rejected { _ = try knownRateReference(binding: binding, windows: windows, rate: 1, evidence: evidence) }
        }
        rejected { _ = try knownRateReference(binding: binding, windows: Array(windows.dropLast()), rate: 1, evidence: "Fixture") }
        windows[0][50] = try CalibrationSample(["51", "10.5", "0", "0", "1000", "11", "-7", "5000"])
        rejected { _ = try knownRateReference(binding: binding, windows: windows, rate: 1, evidence: "Noisy fixture") }
        print("PASS known-rate acquisition solver: independent axes/gain, invalid references, noisy capture rejection")
    }
}
