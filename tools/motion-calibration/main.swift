import Foundation
import Switch2Kit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func arguments(_ values: ArraySlice<String>, allowed: Set<String>) throws -> [String: String] {
    guard values.count.isMultiple(of: 2) else { throw CalibrationFailure.usage }
    var result = [String: String]()
    var iterator = values.makeIterator()
    while let key = iterator.next() {
        guard allowed.contains(key), result[key] == nil, let value = iterator.next(), !value.isEmpty else {
            throw CalibrationFailure.usage
        }
        result[key] = value
    }
    guard Set(result.keys) == allowed else { throw CalibrationFailure.usage }
    return result
}

func selection(_ args: [String: String]) throws -> CaptureBinding {
    guard let text = args["--model"],
          let model = UInt16(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: text.hasPrefix("0x") ? 16 : 10) else {
        throw CalibrationFailure.usage
    }
    return try .init([args["--device"]!, String(model), args["--configuration"]!, args["--features"]!, args["--holding"]!])
}

do {
    let values = Array(CommandLine.arguments.dropFirst())
    guard let command = values.first else { throw CalibrationFailure.usage }
    let bindingArguments: Set<String> = ["--device", "--model", "--configuration", "--features", "--holding"]
    switch command {
    case "list":
        guard values.count == 1 else { throw CalibrationFailure.usage }
        try listControllers()
    case "capture":
        let args = try arguments(values.dropFirst(), allowed: bindingArguments.union(["--output"]))
        let data = try capture(binding: selection(args))
        try saveNew(data, to: args["--output"]!)
        print("Saved explicit raw diagnostic capture. This is not a calibrated profile.")
    case "capture-rate":
        let args = try arguments(values.dropFirst(), allowed: bindingArguments.union(["--rate", "--evidence", "--output"]))
        guard let rate = Double(args["--rate"]!), rate.isFinite, rate > 0,
              args["--evidence"]!.utf8.count <= 512,
              !args["--evidence"]!.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CalibrationFailure.reference
        }
        let data = try capture(binding: selection(args), rate: rate, evidence: args["--evidence"]!)
        try saveNew(data, to: args["--output"]!)
        print("Saved gyro reference means. The fixture's physical rotation rate must be independently measured.")
    case "fit":
        let args = try arguments(values.dropFirst(), allowed: ["--capture", "--gyro-reference", "--output"])
        let record = try StationaryRecord(data: readBounded(args["--capture"]!, limit: captureLimit))
        let gyro = try GyroReference(data: readBounded(args["--gyro-reference"]!, limit: 4096))
        let profile = try fit(record, gyro: gyro)
        try saveNew(profile.encoded(), to: args["--output"]!)
        print("Saved explicit user-supplied profile. This tool does not certify physical scale, frame or reference evidence.")
    case "validate":
        let args = try arguments(values.dropFirst(), allowed: bindingArguments.union(["--profile"]))
        let binding = try selection(args)
        let profile = try Switch2MotionProfile(encoded: readBounded(args["--profile"]!, limit: Switch2MotionProfile.maximumEncodedSize))
        guard profile.device == binding.device, profile.model == binding.model,
              profile.orientationName == binding.holding, profile.featureFlags == binding.featureFlags else {
            throw CalibrationFailure.format
        }
        print("Valid matching user-supplied profile; physical scale/frame acceptance remains the user's responsibility.")
    default: throw CalibrationFailure.usage
    }
} catch let error as CalibrationFailure {
    FileHandle.standardError.write(Data((error.rawValue + "\n").utf8)); exit(2)
} catch {
    // Do not echo input filenames, identifiers, sensor contents or arbitrary decoder errors.
    FileHandle.standardError.write(Data("Calibration failed; no usable profile was installed. Check the input format and output path.\n".utf8)); exit(2)
}
