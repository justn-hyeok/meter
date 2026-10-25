import Foundation
import Testing
@testable import MeterCore

private func snapshot(_ account: Account, _ buckets: [(id: String, label: String)]) -> UsageSnapshot {
    UsageSnapshot(
        provider: account.provider,
        buckets: buckets.map {
            UsageBucket(id: $0.id, label: $0.label, used: 10, limit: 100, remaining: 90, resetAt: nil, unit: .percent)
        },
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: "test",
        state: .live,
        message: nil
    ).for(account)
}

@Test func mutedWindowsTakeTheirLabelsFromTheLatestSnapshots() {
    let account = Account(.claude)
    let key = BucketKey(account: account, bucketID: "five_hour")
    let windows = MutedWindow.all([key], in: [account: snapshot(account, [(id: "five_hour", label: "5-hour")])])

    #expect(windows.count == 1)
    #expect(windows.first?.key == key)
    #expect(windows.first?.accountTitle == "Claude")
    #expect(windows.first?.label == "5-hour")
}

@Test func aMutedWindowWithNoSnapshotStaysListedByItsID() {
    let key = BucketKey(provider: .deepSeek, bucketID: "balance")
    let windows = MutedWindow.all([key], in: [:])

    #expect(windows.map(\.accountTitle) == ["DeepSeek API"])
    #expect(windows.map(\.label) == ["balance"])
}

@Test func aMutedWindowWhoseSnapshotNoLongerHasItFallsBackToItsID() {
    let account = Account(.openRouter)
    let key = BucketKey(account: account, bucketID: "gone")
    let windows = MutedWindow.all([key], in: [account: snapshot(account, [(id: "other", label: "Other")])])

    #expect(windows.map(\.label) == ["gone"])
}

@Test func mutedWindowsAreOrderedByAccountAndThenWindowName() {
    let claude = Account(.claude)
    let codex = Account(.codex)
    let muted: Set<BucketKey> = [
        BucketKey(account: claude, bucketID: "weekly"),
        BucketKey(account: claude, bucketID: "daily"),
        BucketKey(account: codex, bucketID: "five_hour"),
    ]
    let snapshots = [
        claude: snapshot(claude, [(id: "daily", label: "Daily"), (id: "weekly", label: "Weekly")]),
        codex: snapshot(codex, [(id: "five_hour", label: "5-hour")]),
    ]

    let windows = MutedWindow.all(muted, in: snapshots)

    #expect(windows.map(\.accountTitle) == ["Claude", "Claude", "Codex"])
    #expect(windows.map(\.label) == ["Daily", "Weekly", "5-hour"])
}

@Test func aNamedAccountsTitleNamesItsProviderAndAccount() {
    let account = Account(.deepSeek, name: "work")
    let key = BucketKey(account: account, bucketID: "balance")
    let windows = MutedWindow.all([key], in: [:])

    #expect(windows.map(\.accountTitle) == ["DeepSeek API · work"])
}
