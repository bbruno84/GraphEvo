import Foundation
import os
import Testing
@testable import GraphEvoRuntime

@Suite(.timeLimit(.minutes(1))) struct StoreInvalidationTests {
    @Test func newestHintIsBoundedAndHandleTerminationDoesNotStopAnotherOwner() async throws {
        let hub = StoreInvalidationHub(), owner = UUID(), otherOwner = UUID()
        let a = hub.subscribe(owner: owner), b = hub.subscribe(owner: otherOwner)
        var first = a.stream.makeAsyncIterator(), second = b.stream.makeAsyncIterator()
        #expect(await first.next()?.reason == .initial)
        #expect(await second.next()?.reason == .initial)
        for _ in 0..<1000 { hub.publish(.contextSave) }
        hub.publish(.storeChange)
        #expect(await first.next()?.reason == .storeChange)
        #expect(await second.next()?.reason == .storeChange)
        hub.finish(owner: owner)
        #expect(await first.next() == nil)
        #expect(hub.subscriberCount == 1)
        b.refresh()
        #expect(await second.next()?.reason == .refresh)
        hub.finish()
        #expect(await second.next() == nil)
        #expect(hub.subscriberCount == 0)
    }

    @Test func accountChangeRemainsVisibleThroughCoalescingRefreshAndNewSubscriptions() async throws {
        let hub = StoreInvalidationHub(), feed = hub.subscribe(owner: UUID())
        hub.publish(.accountChange)
        for _ in 0..<100 { hub.publish(.contextSave) }
        feed.refresh()
        var first = feed.stream.makeAsyncIterator()
        #expect(await first.next()?.reason == .accountChange)
        let next = hub.subscribe(owner: UUID())
        var second = next.stream.makeAsyncIterator()
        #expect(await second.next()?.reason == .accountChange)
        hub.finish()
    }

    @Test func stalePublicationCannotMaskAnAccountChangeAtConsumption() async throws {
        let accountChanged = OSAllocatedUnfairLock(initialState: false)
        let raw = AsyncStream<StoreInvalidation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sequence = StoreInvalidationSequence(raw: raw.stream, accountChanged: { accountChanged.withLock { $0 } })
        // Reproduce publication A taking its ordinary-hint snapshot before B changes account,
        // then yielding A after B's account hint. The raw newest buffer now holds the stale hint.
        accountChanged.withLock { $0 = true }
        raw.continuation.yield(StoreInvalidation(reason: .accountChange))
        raw.continuation.yield(StoreInvalidation(reason: .contextSave))
        var iterator = sequence.makeAsyncIterator()
        #expect(await iterator.next()?.reason == .accountChange)
        raw.continuation.finish()
    }

    @Test func consumerCancellationRemovesItsRegistration() async throws {
        let hub = StoreInvalidationHub(), ready = AsyncStream<Void>.makeStream()
        let feed = hub.subscribe(owner: UUID())
        let work = Task {
            for await _ in feed.stream { ready.continuation.yield(()) }
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        work.cancel(); await work.value
        #expect(hub.subscriberCount == 0)
        ready.continuation.finish(); hub.finish()
    }
}
