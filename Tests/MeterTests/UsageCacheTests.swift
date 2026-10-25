import Foundation
import Testing
@testable import MeterCore

/// A newer build sharing the cache writes providers this build has never heard of.
@Test func aSnapshotFromANewerBuildDoesNotHideTheRestOrGetDropped() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeterCache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "usage-cache.json")
    let cache = UsageCache(fileURL: file)
    try cache.save([UsageSnapshot(provider: .codex,
        buckets: [.init(id: "week", label: "Weekly", used: 42, limit: 100,
                        remaining: 58, resetAt: nil, unit: .percent)],
        fetchedAt: .now, source: "test", state: .live, message: nil)])

    // Copy the Codex entry under a provider id this build does not know.
    var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var snapshots = try #require(document["snapshots"] as? [[String: Any]])
    var future = try #require(snapshots.first)
    future["provider"] = "from-the-future"
    snapshots.append(future)
    document["snapshots"] = snapshots
    try JSONSerialization.data(withJSONObject: document).write(to: file)

    #expect(cache.isReadable)
    #expect(cache.read()[Account(.codex)]?.buckets.first?.percentageUsed == 42)

    // Saving again keeps the entry it could not read.
    try cache.save([.unavailable(.claude, "no key")])
    let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let providers = (saved["snapshots"] as? [[String: Any]] ?? []).compactMap { $0["provider"] as? String }
    #expect(providers.sorted() == ["codex", "from-the-future"])
}
