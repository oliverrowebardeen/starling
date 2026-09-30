import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct DownFakeTests {
    @Test func scriptedDownServiceRecordsIntentsAndEmits() async throws {
        let service = ScriptedDownService()
        let intent = DownIntent(rules: .empty, level: .maybe, expiresAt: Timestamp(millisecondsSince1970: 0))
        try await service.setIntent(intent)
        await service.clearIntent()
        #expect(await service.intents == [intent])
        #expect(await service.cleared == 1)
        await service.handle(.peerAvailable(Fixtures.alice))
        #expect(await service.handled == [.peerAvailable(Fixtures.alice)])
        let match = DownMatch(peer: .random(), terms: .empty, bothDown: false)
        service.emit(.matched(match))
        for await event in service.events {
            #expect(event == .matched(match))
            break
        }
    }
}
