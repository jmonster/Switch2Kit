#if os(Linux)
import Foundation
import Glibc
import Switch2KitDBus

// Only the BlueZ adapter uses these types. They are not a public D-Bus API.
package indirect enum BlueZValue: Sendable {
    case string(String), number(Int64), bytes(Data), array([BlueZValue]), dictionary([String: BlueZValue]), ignored
    package var string: String? { if case .string(let value) = self { value } else { nil } }
    package var number: Int64? { if case .number(let value) = self { value } else { nil } }
    package var bytes: Data? { if case .bytes(let value) = self { value } else { nil } }
    package var dictionary: [String: BlueZValue]? { if case .dictionary(let value) = self { value } else { nil } }
    package var array: [BlueZValue]? { if case .array(let value) = self { value } else { nil } }
}
package struct BlueZError: Error, Sendable {
    package let name: String
    package static let malformed = Self(name: "Switch2Kit.InvalidDBusMessage")
    package static let unavailable = Self(name: "Switch2Kit.DBusUnavailable")
    package var isPermission: Bool {
        name == "org.freedesktop.DBus.Error.AccessDenied" || name == "org.bluez.Error.NotAuthorized"
            || name == "org.bluez.Error.NotPermitted"
    }
}
package indirect enum BlueZArgument {
    case string(String), boolean(Bool), bytes(Data), options([(String, BlueZArgument)])
    private var signature: String {
        switch self { case .string: "s"; case .boolean: "b"; case .bytes: "ay"; case .options: "a{sv}" }
    }
    package func append(to message: OpaquePointer) throws {
        func check(_ result: Int32) throws { if result < 0 { throw BlueZError.malformed } }
        switch self {
        case .string(let value): try check(s2k_bus_append_string(message, 115, value))
        case .boolean(let value): try check(s2k_bus_append_bool(message, value ? 1 : 0))
        case .bytes(let bytes):
            try bytes.withUnsafeBytes { try check(s2k_bus_append_bytes(message, $0.baseAddress, $0.count)) }
        case .options(let entries):
            try check(s2k_bus_open_container(message, 97, "{sv}"))
            for (name, value) in entries {
                try check(s2k_bus_open_container(message, 101, "sv"))
                try check(s2k_bus_append_string(message, 115, name))
                try check(s2k_bus_open_container(message, 118, value.signature))
                try value.append(to: message)
                try check(s2k_bus_close_container(message))
                try check(s2k_bus_close_container(message))
            }
            try check(s2k_bus_close_container(message))
        }
    }
}

private struct BlueZDecoder {
    private var remaining = 65536
    private var bytesRemaining = 4 * 1024 * 1024
    private mutating func consume(_ bytes: Int) throws {
        bytesRemaining -= bytes
        guard bytesRemaining >= 0 else { throw BlueZError.malformed }
    }
    mutating func all(_ message: OpaquePointer) throws -> [BlueZValue] {
        var values: [BlueZValue] = []
        while let next = try value(message, depth: 0) { values.append(next) }
        return values
    }
    private mutating func value(_ message: OpaquePointer, depth: Int) throws -> BlueZValue? {
        remaining -= 1
        guard remaining >= 0, depth <= 16 else { throw BlueZError.malformed }
        var type: CChar = 0
        var contents: UnsafePointer<CChar>?
        let result = s2k_bus_peek(message, &type, &contents)
        guard result >= 0 else { throw BlueZError.malformed }
        if result == 0 { return nil }
        if type == 115 || type == 111 || type == 103 { // string, path, signature
            var text: UnsafePointer<CChar>?
            guard s2k_bus_read_string(message, type, &text) > 0, let text else { throw BlueZError.malformed }
            let count = strnlen(text, 65537)
            guard count <= 65536 else { throw BlueZError.malformed }
            try consume(count)
            return .string(String(cString: text))
        }
        if [121, 98, 110, 113, 105, 117, 120].contains(type) {
            var number: Int64 = 0
            guard s2k_bus_read_integer(message, type, &number) > 0 else { throw BlueZError.malformed }
            return .number(number)
        }
        if type == 97, let contents, String(cString: contents) == "y" {
            var bytes: UnsafeRawPointer?
            var count = 0
            guard s2k_bus_read_bytes(message, &bytes, &count) > 0, count <= 65536 else { throw BlueZError.malformed }
            try consume(count)
            return .bytes(count == 0 ? Data() : Data(bytes: bytes!, count: count))
        }
        if [97, 118, 114, 101].contains(type), let contents {
            let signature = String(cString: contents)
            guard s2k_bus_enter(message, type, contents) > 0 else { throw BlueZError.malformed }
            var children: [BlueZValue] = []
            while let child = try value(message, depth: depth + 1) { children.append(child) }
            guard s2k_bus_exit(message) >= 0 else { throw BlueZError.malformed }
            if type == 118 {
                guard children.count == 1 else { throw BlueZError.malformed }
                return children[0]
            }
            if type == 97 && signature.hasPrefix("{") {
                var dict: [String: BlueZValue] = [:]
                for entry in children {
                    guard let pair = entry.array, pair.count == 2 else { throw BlueZError.malformed }
                    let key: String
                    if let text = pair[0].string { key = text }
                    else if let number = pair[0].number { key = String(number) }
                    else { throw BlueZError.malformed }
                    guard dict.updateValue(pair[1], forKey: key) == nil else { throw BlueZError.malformed }
                }
                return .dictionary(dict)
            }
            return .array(children)
        }
        // Unused BlueZ metadata (e.g. uint64/double) must not invalidate the
        // entire object snapshot. The C reader skips exactly one scalar.
        guard s2k_bus_skip_scalar(message, type) > 0 else { throw BlueZError.malformed }
        return .ignored
    }
}

// All interaction with sd-bus, pending calls and signal handlers is confined to
// the transport queue. I/O is nonblocking, driven by fd readiness and sd-bus's
// monotonic deadline, not a polling subprocess or a fixed-frequency input timer.
package final class BlueZBus: @unchecked Sendable {
    private final class Owner: @unchecked Sendable {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { s2k_bus_close(handle) }
    }
    private final class Call {
        weak var bus: BlueZBus?
        let id: UInt64
        let completion: (Result<[BlueZValue], BlueZError>) -> Void
        var slot: OpaquePointer?
        init(bus: BlueZBus, id: UInt64, completion: @escaping (Result<[BlueZValue], BlueZError>) -> Void) {
            self.bus = bus; self.id = id; self.completion = completion
        }
        deinit { if let slot { s2k_bus_cancel(slot) } }
    }
    private let queue: DispatchQueue
    private var owner: Owner?
    private var read: DispatchSourceRead?
    private var write: DispatchSourceWrite?
    private var timer: DispatchSourceTimer?
    private var writeSuspended = false
    private var matches: [OpaquePointer] = []
    private var calls: [UInt64: Call] = [:]
    private var nextID: UInt64 = 0
    private var pumping = false
    package var signal: ((String, String, String, [BlueZValue]) -> Void)?
    package var failed: ((BlueZError) -> Void)?

    package init(queue: DispatchQueue) throws {
        self.queue = queue
        var handle: OpaquePointer?
        let status = s2k_bus_open(&handle)
        guard status >= 0, let handle else {
            throw BlueZError(name: status == -EACCES ? "org.freedesktop.DBus.Error.AccessDenied" : "Switch2Kit.DBusUnavailable")
        }
        let owner = Owner(handle)
        self.owner = owner
        let fd = s2k_bus_fd(handle)
        guard fd >= 0 else { throw BlueZError.unavailable }
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.read = read; self.write = write; self.timer = timer
        read.setEventHandler { [weak self] in self?.pump() }
        write.setEventHandler { [weak self] in self?.pump() }
        timer.setEventHandler { [weak self] in self?.pump() }
        // sd-bus owns the fd. Keep its owner until both dispatch sources have
        // acknowledged cancellation, so closing/reusing the descriptor is safe.
        read.setCancelHandler { withExtendedLifetime(owner) {} }
        write.setCancelHandler { withExtendedLifetime(owner) {} }
        read.resume(); write.resume(); timer.resume()
    }
    deinit { close() }
    package func close() {
        read?.cancel(); read = nil
        if writeSuspended { write?.resume(); writeSuspended = false }
        write?.cancel(); write = nil
        timer?.cancel(); timer = nil
        matches.forEach { s2k_bus_cancel($0) }; matches.removeAll()
        calls.removeAll()
        signal = nil; failed = nil
        owner = nil
    }
    package func subscribe(_ rule: String) throws {
        guard let owner else { throw BlueZError.unavailable }
        var slot: OpaquePointer?
        let status = s2k_bus_match(owner.handle, &slot, rule, { message, context, _ in
            guard let message, let context else { return 0 }
            let bus = Unmanaged<BlueZBus>.fromOpaque(context).takeUnretainedValue()
            // The same callback receives AddMatch acknowledgement. A denied
            // subscription must not masquerade as an idle, working radio.
            if let name = s2k_bus_error_name(message) {
                bus.fail(BlueZError(name: String(cString: name))); return 1
            }
            do {
                var decoder = BlueZDecoder()
                let values = try decoder.all(message)
                if let path = s2k_bus_path(message), let interface = s2k_bus_interface(message), let member = s2k_bus_member(message) {
                    bus.signal?(String(cString: path), String(cString: interface), String(cString: member), values)
                }
            } catch { bus.fail(.malformed) }
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
        guard status >= 0, let slot else { throw BlueZError.unavailable }
        matches.append(slot)
        pump()
    }
    package func call(path: String, interface: String, member: String,
                      arguments: [BlueZArgument] = [], timeout: UInt64 = 5_000_000,
                      completion: @escaping (Result<[BlueZValue], BlueZError>) -> Void) {
        guard let owner, calls.count < 256 else { completion(.failure(.unavailable)); return }
        var message: OpaquePointer?
        guard s2k_bus_method(owner.handle, &message, "org.bluez", path, interface, member) >= 0,
              let message else { completion(.failure(.malformed)); return }
        defer { s2k_bus_message_release(message) }
        do { for argument in arguments { try argument.append(to: message) } }
        catch { completion(.failure(.malformed)); return }
        nextID &+= 1
        let call = Call(bus: self, id: nextID, completion: completion)
        calls[call.id] = call
        let status = s2k_bus_call(owner.handle, &call.slot, message, { message, context, _ in
            guard let message, let context else { return 0 }
            let call = Unmanaged<Call>.fromOpaque(context).takeUnretainedValue()
            guard let bus = call.bus else { return 0 }
            let result: Result<[BlueZValue], BlueZError>
            if let name = s2k_bus_error_name(message) {
                result = .failure(BlueZError(name: String(cString: name)))
            } else {
                do { var decoder = BlueZDecoder(); result = .success(try decoder.all(message)) }
                catch { result = .failure(.malformed) }
            }
            // Keep the request alive through its completion, even after removing
            // the pending entry; its slot cancels exactly once on final release.
            withExtendedLifetime(call) {
                bus.calls.removeValue(forKey: call.id)
                call.completion(result)
            }
            return 1
        }, Unmanaged.passUnretained(call).toOpaque(), timeout)
        if status < 0 { calls.removeValue(forKey: call.id); completion(.failure(.unavailable)); return }
        pump()
    }
    private func fail(_ error: BlueZError) {
        let handler = failed
        close()
        handler?(error)
    }
    private func pump() {
        guard !pumping, let owner else { return }
        pumping = true
        defer { pumping = false }
        var processed = 0
        while self.owner != nil && processed < 128 {
            let status = s2k_bus_process(owner.handle)
            if status < 0 { fail(.unavailable); return }
            if status == 0 { break }
            processed += 1
        }
        guard self.owner != nil else { return }
        let events = s2k_bus_events(owner.handle)
        guard events >= 0 else { fail(.unavailable); return }
        let needsWrite = events & Int32(POLLOUT) != 0
        if needsWrite && writeSuspended { write?.resume(); writeSuspended = false }
        if !needsWrite && !writeSuspended { write?.suspend(); writeSuspended = true }
        var deadline: UInt64 = .max
        guard s2k_bus_timeout(owner.handle, &deadline) >= 0 else { fail(.unavailable); return }
        if deadline == .max { timer?.schedule(deadline: .distantFuture) }
        else {
            var now = timespec()
            clock_gettime(CLOCK_MONOTONIC, &now)
            let micros = UInt64(now.tv_sec) * 1_000_000 + UInt64(now.tv_nsec / 1000)
            let delay = deadline > micros ? min(deadline - micros, 60_000_000) : 0
            timer?.schedule(deadline: .now() + .microseconds(Int(delay)), leeway: .microseconds(100))
        }
        if processed == 128 { queue.async { [weak self] in self?.pump() } }
    }
}
#endif
