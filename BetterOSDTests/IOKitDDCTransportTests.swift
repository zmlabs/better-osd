@testable import BetterOSD
import Testing

@MainActor
struct IOKitDDCTransportTests {
    @Test
    func sendsGetVCPRequestBeforeReadingLuminance() {
        var events: [String] = []
        var requests: [[UInt8]] = []
        let result = IOKitDDCTransport.readLuminance(
            writeRequest: { requests.append($0); events.append("write"); return true },
            readReply: { events.append("read"); return Self.reply() },
            waitForReply: { events.append("wait") }
        )
        #expect(requests == [[0x82, 0x01, 0x10, 0xfd]])
        #expect(events == ["write", "wait", "read"])
        #expect(result?.current == 50)
        #expect(result?.max == 100)
    }

    @Test
    func failedRequestDoesNotWaitOrRead() {
        var didWait = false
        var didRead = false
        let result = IOKitDDCTransport.readLuminance(
            writeRequest: { _ in false },
            readReply: { didRead = true; return Self.reply() },
            waitForReply: { didWait = true }
        )
        #expect(result == nil)
        #expect(!didWait)
        #expect(!didRead)
    }

    @Test
    func failedReadReturnsNilAfterSendingRequest() {
        var didWrite = false
        let result = IOKitDDCTransport.readLuminance(
            writeRequest: { _ in didWrite = true; return true },
            readReply: { nil },
            waitForReply: {}
        )
        #expect(didWrite)
        #expect(result == nil)
    }

    @Test
    func rejectsCorruptOrUnrelatedReplies() {
        let valid = Self.reply()
        var replies = [Array(valid.prefix(10)), [UInt8](repeating: 0, count: 12)]
        for index in [0, 1, 2, 3, 4, 10] {
            var corrupt = valid
            corrupt[index] ^= 1
            replies.append(corrupt)
        }
        replies += [Self.reply(max: 0), Self.reply(max: 1001), Self.reply(current: 101)]
        for reply in replies {
            #expect(IOKitDDCTransport.readLuminance(
                writeRequest: { _ in true },
                readReply: { reply },
                waitForReply: {}
            ) == nil)
        }
    }

    private static func reply(current: UInt16 = 50, max: UInt16 = 100) -> [UInt8] {
        var reply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, UInt8(max >> 8), UInt8(max & 0xff), UInt8(current >> 8), UInt8(current & 0xff), 0, 0]
        reply[10] = reply.prefix(10).reduce(UInt8(0x50), ^)
        return reply
    }
}
