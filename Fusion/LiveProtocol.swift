import Foundation
import zlib

enum LiveProtocol {
    static let limit = 4 * 1024 * 1024
    struct Event { let operation: Int; let data: JSON }
    static func packet(_ operation: Int, _ body: String) -> Data {
        let payload = Data(body.utf8); var result = Data()
        for (value, bytes) in [(payload.count + 16,4),(16,2),(1,2),(operation,4),(1,4)] {
            for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        result.append(payload); return result
    }
    static func decode(_ data: Data) throws -> [Event] {
        var budget = limit, events = [Event]()
        try walk(data, depth: 0, budget: &budget, events: &events); return events
    }
    private static func walk(_ data: Data, depth: Int, budget: inout Int, events: inout [Event]) throws {
        guard depth <= 3, data.count <= budget else { throw FusionError("弹幕数据超出上限") }
        budget -= data.count; let bytes = Array(data); var offset = 0
        func read(_ at: Int, _ n: Int) -> Int { bytes[at..<(at+n)].reduce(0) { ($0 << 8) | Int($1) } }
        while offset < bytes.count {
            guard bytes.count - offset >= 16 else { throw FusionError("弹幕包头不完整") }
            let size = read(offset,4), head = read(offset+4,2), version = read(offset+6,2), op = read(offset+8,4)
            guard size >= 16, head >= 16, head <= size, size <= bytes.count - offset, events.count < 1000 else { throw FusionError("弹幕包长度无效") }
            let payload = Array(bytes[(offset+head)..<(offset+size)]); offset += size
            if version == 2 {
                guard budget > 0 else { throw FusionError("弹幕解压超限") }
                var output = [UInt8](repeating: 0, count: budget), length = uLongf(budget)
                let code = payload.withUnsafeBufferPointer { input in output.withUnsafeMutableBufferPointer { buffer in uncompress(buffer.baseAddress, &length, input.baseAddress, uLong(payload.count)) } }
                guard code == Z_OK else { throw FusionError("弹幕解压失败") }
                try walk(Data(output.prefix(Int(length))), depth: depth + 1, budget: &budget, events: &events)
            } else if version == 3 { throw FusionError("服务器未使用约定的 zlib 消息格式") }
            else if op == 5 || op == 8 {
                if let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? JSON { events.append(Event(operation: op, data: json)) }
            } else if op == 3 { events.append(Event(operation: op, data: [:])) }
        }
    }
}

