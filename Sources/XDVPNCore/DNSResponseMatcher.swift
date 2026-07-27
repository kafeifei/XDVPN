public enum DNSResponseMatcher {
    public static func matches(query: [UInt8], response: [UInt8]) -> Bool {
        guard query.count >= 12, response.count >= 12,
              query[0] == response[0], query[1] == response[1],
              query[2] & 0x80 == 0, response[2] & 0x80 != 0,
              query[2] & 0x78 == response[2] & 0x78,
              let queryQuestions = questions(in: query),
              let responseQuestions = questions(in: response),
              !queryQuestions.isEmpty else {
            return false
        }
        return queryQuestions == responseQuestions
    }

    private struct Question: Equatable {
        let labels: [[UInt8]]
        let type: UInt16
        let dnsClass: UInt16
    }

    private static func questions(in packet: [UInt8]) -> [Question]? {
        let count = Int(readUInt16(packet, at: 4))
        guard count > 0, count <= 64 else { return nil }
        var offset = 12
        var result: [Question] = []
        for _ in 0..<count {
            guard let (labels, nextOffset) = name(in: packet, at: offset),
                  nextOffset + 4 <= packet.count else {
                return nil
            }
            result.append(Question(
                labels: labels,
                type: readUInt16(packet, at: nextOffset),
                dnsClass: readUInt16(packet, at: nextOffset + 2)
            ))
            offset = nextOffset + 4
        }
        return result
    }

    private static func name(in packet: [UInt8], at offset: Int) -> ([[UInt8]], Int)? {
        var labels: [[UInt8]] = []
        var cursor = offset
        var nextOffset: Int?
        var visitedPointers = Set<Int>()

        while cursor < packet.count, labels.count <= 127 {
            let length = Int(packet[cursor])
            if length == 0 {
                return (labels, nextOffset ?? cursor + 1)
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < packet.count else { return nil }
                let pointer = ((length & 0x3F) << 8) | Int(packet[cursor + 1])
                guard pointer < packet.count, visitedPointers.insert(pointer).inserted else {
                    return nil
                }
                nextOffset = nextOffset ?? cursor + 2
                cursor = pointer
                continue
            }
            guard length & 0xC0 == 0, length <= 63,
                  cursor + 1 + length <= packet.count else {
                return nil
            }
            let label = packet[(cursor + 1)..<(cursor + 1 + length)].map(asciiLowercased)
            labels.append(label)
            cursor += length + 1
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}
