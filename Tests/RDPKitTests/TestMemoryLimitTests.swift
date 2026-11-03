import Foundation
import RDPKitTestMemoryLimit
import Testing

/// A test process whose memory passes its limit stops, saying why, rather than running the Mac
/// out of memory; that it does here also shows the watch is linked in and running.
@Test(.timeLimit(.minutes(1)))
func aTestProcessStopsOnceItsMemoryPassesItsLimit() async {
    let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        rdpkit_test_memory_limit_set(256 << 20)
        let byteCount = 1 << 30
        let memory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16_384)
        // Written, so that its pages count toward the footprint.
        for offset in stride(from: 0, to: byteCount, by: 16_384) {
            memory.storeBytes(of: 1, toByteOffset: offset, as: UInt8.self)
        }
        try? await Task.sleep(for: .seconds(30))
        memory.deallocate()
    }
    let message = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
    #expect(message.contains("RDPKit tests: this process uses"))
    #expect(message.contains("RDPKIT_TEST_MEMORY_LIMIT_GIB"))
}
