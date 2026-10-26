import Foundation

@main struct ControlInputBufferSmoke {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
    }

    private static func decode(_ text: String?) -> [String: Any] {
        guard let text = text, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("FAIL: expected a valid queued frame")
        }
        return value
    }

    static func main() {
        var queue = ControlInputBuffer()
        // Holding throttle while tapping shift must preserve both edges before send completes.
        check(queue.enqueue(#"{"a":0.1,"t":1,"gu":false}"#), "first throttle frame")
        check(queue.enqueue(#"{"a":0.2,"t":1,"gu":true}"#), "shift press")
        check(queue.enqueue(#"{"a":0.3,"t":1,"gu":false}"#), "shift release")
        check(queue.enqueue(#"{"a":0.4,"t":1,"gu":true}"#), "second shift press")
        check(queue.enqueue(#"{"a":0.5,"t":1,"gu":false}"#), "second shift release")
        check(queue.count == 5, "rapid press/release edges retained")
        for expected in [false, true, false, true, false] {
            let frame = decode(queue.popFirst())
            check(frame["gu"] as? Bool == expected, "FIFO button state")
            check((frame["t"] as? NSNumber)?.doubleValue == 1, "held throttle preserved")
        }
        check(queue.popFirst() == nil, "queue drains")

        for index in 0..<100 {
            check(queue.enqueue("{\"a\":\(Double(index) / 100),\"t\":0.5}"), "100 Hz axis update")
        }
        check(queue.count == 1, "axis updates coalesce to latest")
        check((decode(queue.popFirst())["a"] as? NSNumber)?.doubleValue == 0.99, "latest axis survives")

        check(queue.enqueue(#"{"t":0,"b":0}"#), "zero pedal frame")
        check(queue.enqueue(#"{"t":0.2,"b":0}"#), "throttle contact")
        check(queue.enqueue(#"{"t":0.9,"b":0}"#), "throttle travel")
        check(queue.enqueue(#"{"t":0,"b":0}"#), "throttle release")
        check(queue.enqueue(#"{"t":0,"b":0.3}"#), "brake contact")
        check(queue.enqueue(#"{"t":0,"b":0}"#), "brake release")
        check(queue.count == 5, "pedal contact/release retained, travel coalesced")
        queue.clear()

        check(queue.enqueue(#"{"gu":true,"t":1}"#), "queued held controls")
        check(queue.enqueue(" \n { } \n "), "explicit neutral reset")
        check(queue.count == 1, "reset discards unsent control history")
        check(queue.enqueue(#"{"a":0.5}"#), "movement after reset")
        check(queue.count == 2, "new axes cannot replace the reset frame")
        check(queue.popFirst() == "{}", "reset is transmitted first")
        _ = queue.popFirst()

        check(queue.enqueue(#"{"ra":true}"#), "pre-disconnect frame")
        queue.clear()
        check(queue.count == 0 && queue.popFirst() == nil, "disconnect clears pending input")
        check(queue.enqueue(#"{"a":0.1}"#), "fresh reconnect frame")
        check(decode(queue.popFirst())["ra"] as? Bool == false, "old held key does not return")

        let malformed = ["[]", "null", "{", #"{"command":"run"}"#, #"{"a":true}"#,
                         #"{"a":"0"}"#, #"{"gu":1}"#, #"{"gu":"false"}"#,
                         #"{"a":null}"#, #"{"a":1.01}"#, #"{"t":-0.1}"#,
                         #"{"b":1.1}"#, #"{"a":1e999}"#, String(repeating: " ", count: 8192)]
        for input in malformed {
            check(queue.enqueue(#"{"gu":true}"#), "seed before invalid input")
            check(!queue.enqueue(input), "reject malformed or unknown input")
            check(queue.count == 0, "invalid input clears stale queue")
        }
        var bounded = ControlInputBuffer(capacity: 4)
        for pressed in [true, false, true, false] {
            check(bounded.enqueue("{\"gu\":\(pressed)}"), "within edge capacity")
        }
        check(!bounded.enqueue(#"{"gu":true}"#), "overflow requests disconnect")
        check(bounded.count == 0, "overflow does not replay backlog")

        print("PASS: control FIFO edges, held-throttle shifting, latest axes, pedal contact/release, neutral reset, reconnect clear, strict validation and bounded backlog")
    }
}
