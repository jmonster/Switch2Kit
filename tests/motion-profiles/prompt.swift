import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Tests the production prompt, not a replacement capture loop or Bluetooth implementation.
@main
struct PromptRegression {
    enum Expected: Error { case service }

    static func pipeTest(_ body: (Int32, Int32) throws -> Void) throws {
        var descriptors: [Int32] = [-1, -1]
        precondition(pipe(&descriptors) == 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        try body(descriptors[0], descriptors[1])
    }

    static func send(_ text: String, to descriptor: Int32) {
        let bytes = Array(text.utf8)
        precondition(bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count)
    }

    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected rejection") }
        catch { }
    }

    static func main() throws {
        try pipeTest { input, output in
            var calls = 0
            try waitForCaptureReturn(input: input, timeoutNanoseconds: 1_000_000_000) {
                calls += 1
                if calls == 3 { send("\n", to: output) }
            }
            precondition(calls == 3, "The run loop must be serviced while no terminal input is ready")
        }
        try pipeTest { input, output in
            send(String(repeating: "x", count: 1024) + "\n", to: output)
            try waitForCaptureReturn(input: input, timeoutNanoseconds: 1_000_000_000, service: {})
        }
        try pipeTest { input, output in
            send(String(repeating: "x", count: 1025) + "\n", to: output)
            rejected { try waitForCaptureReturn(input: input, timeoutNanoseconds: 1_000_000_000, service: {}) }
        }
        try pipeTest { input, _ in
            var calls = 0
            rejected { try waitForCaptureReturn(input: input, timeoutNanoseconds: 20_000_000) { calls += 1 } }
            precondition(calls > 0)
        }
        try pipeTest { input, _ in
            do {
                try waitForCaptureReturn(input: input) { throw Expected.service }
                fatalError("Service failure must stop prompting")
            } catch Expected.service { }
        }
        let eof = open("/dev/null", O_RDONLY)
        precondition(eof >= 0)
        defer { close(eof) }
        rejected { try waitForCaptureReturn(input: eof, timeoutNanoseconds: 1_000_000_000, service: {}) }
        print("PASS: 6 production prompt regressions")
    }
}
