import Foundation
import CoreFoundation

/// Bounded FIFO for control edges, with latest-value coalescing inside each held state.
/// Use only on the same serial queue as the WebSocket sender.
struct ControlInputBuffer {
    private struct Frame {
        let text: String
        let signature: UInt32
        let isReset: Bool
    }

    private static let buttonKeys = ["gu", "gd", "dp", "ot", "lb", "ra", "mf", "st", "du", "dd", "dl", "dr", "ll", "lr"]
    private static let allowedKeys = Set(["a", "t", "b"] + buttonKeys)
    private let capacity: Int
    private var frames: [Frame] = []

    init(capacity: Int = 16) {
        self.capacity = max(2, min(32, capacity))
    }

    var count: Int { frames.count }

    /// False means malformed input or too many pending edges: close the connection.
    /// Never retain a stale partial queue on failure.
    mutating func enqueue(_ text: String) -> Bool {
        guard let frame = Self.parse(text) else { clear(); return false }
        if frame.isReset {
            frames = [frame]
            return true
        }
        if let previous = frames.last, !previous.isReset,
           previous.signature == frame.signature {
            frames[frames.count - 1] = frame
            return true
        }
        guard frames.count < capacity else { clear(); return false }
        frames.append(frame)
        return true
    }

    mutating func popFirst() -> String? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst().text
    }

    mutating func clear() { frames.removeAll(keepingCapacity: true) }

    private static func parse(_ text: String) -> Frame? {
        guard text.utf8.count < 8192, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any],
              Set(values.keys).isSubset(of: allowedKeys) else { return nil }
        if values.isEmpty { return Frame(text: "{}", signature: 0, isReset: true) }

        var sanitized: [String: Any] = [:]
        var signature: UInt32 = 0
        for (index, key) in ["a", "t", "b"].enumerated() {
            var value = 0.0
            if let supplied = values[key] {
                guard let number = supplied as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                value = number.doubleValue
                guard value.isFinite, value <= 1, value >= (key == "a" ? -1 : 0) else { return nil }
            }
            sanitized[key] = value
            // Pedal contact/release is an edge even when the value itself is analog.
            if index > 0 && value > 0 { signature |= UInt32(1) << (buttonKeys.count + index - 1) }
        }
        for (index, key) in buttonKeys.enumerated() {
            var pressed = false
            if let supplied = values[key] {
                guard let number = supplied as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                pressed = number.boolValue
            }
            sanitized[key] = pressed
            if pressed { signature |= UInt32(1) << index }
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
              let output = String(data: encoded, encoding: .utf8) else { return nil }
        return Frame(text: output, signature: signature, isReset: false)
    }
}
