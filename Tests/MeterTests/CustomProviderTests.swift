import Foundation
import Testing
@testable import MeterCore

private func response(_ status: Int, url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// The requests a provider sent, in order: the endpoint is part of what is being pinned.
private final class SentRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    var recorded: [URL] {
        lock.withLock { urls }
    }
}

@Test func recognisesAKnownAPIFromItsHost() {
    #expect(CustomProviderKind.detect(baseURL: "https://api.moonshot.ai/v1") == .moonshot)
    #expect(CustomProviderKind.detect(baseURL: "https://api.siliconflow.cn/v1") == .siliconFlow)
    #expect(CustomProviderKind.detect(baseURL: "https://api.deepseek.com") == .deepSeek)
    #expect(CustomProviderKind.detect(baseURL: "https://openrouter.ai/api/v1") == .openRouter)
    // The host is what names the service: the path a user types is their choice.
    #expect(CustomProviderKind.detect(baseURL: "https://api.example.com/v1") == .generic)
    #expect(CustomProviderKind.detect(baseURL: "not an address") == .generic)
    #expect(CustomProviderKind.detect(baseURL: "https://api.moonshot.ai/v1").hint
        == "✓ Recognised: Moonshot balance API. The tile will show your balance.")
    #expect(CustomProviderKind.detect(baseURL: "https://api.example.com").hint
        == "Unknown API: the tile will show whether the key works.")
}

@Test func readsAMoonshotBalance() throws {
    let data = Data(#"{"data":{"available_balance":42.1,"voucher_balance":0,"cash_balance":42.1}}"#.utf8)
    let snapshot = try CustomUsageParser.moonshot(data)

    let bucket = try #require(snapshot.buckets.first)
    #expect(snapshot.state == .live)
    #expect(snapshot.buckets.count == 1)
    #expect(bucket.id == "balance")
    #expect(bucket.label == "Balance")
    #expect(bucket.remaining == 42.1)
    // The API states no currency, so the figure is not guessed into dollars.
    #expect(bucket.unit == .credits)
}

@Test func readsASiliconFlowBalance() throws {
    let data = Data(#"{"data":{"balance":"12.3","totalBalance":"12.3","chargeBalance":"0"}}"#.utf8)
    let snapshot = try CustomUsageParser.siliconFlow(data)

    let bucket = try #require(snapshot.buckets.first)
    #expect(snapshot.state == .live)
    #expect(bucket.label == "Balance")
    #expect(bucket.remaining == 12.3)
    #expect(bucket.unit == .credits)
}

@Test func aWorkingKeyIsProvenByListingModels() throws {
    let data = Data(#"{"object":"list","data":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#.utf8)
    let snapshot = try CustomUsageParser.models(data)

    let bucket = try #require(snapshot.buckets.first)
    #expect(snapshot.state == .live)
    #expect(bucket.id == "key")
    #expect(bucket.label == "Key works")
    #expect(bucket.unit == .unknown)
    #expect(bucket.remaining == nil)
    #expect(snapshot.message == "3 models")
}

@Test func aMoonshotCustomProviderReadsItsBalanceRoute() async throws {
    let requests = SentRequests()
    let provider = CustomUsageProvider(
        store: .forTests,
        account: Account(.custom, name: "kimi"),
        baseURL: URL(string: "https://api.moonshot.ai/v1")!,
        send: { request in
            requests.record(request.url!)
            return (Data(#"{"data":{"available_balance":42.1}}"#.utf8), response(200, url: request.url!))
        }
    )

    let snapshot = await provider.fetch()
    #expect(requests.recorded.map(\.path) == ["/v1/users/me/balance"])
    #expect(snapshot.provider == .custom)
    #expect(snapshot.account == "kimi")
    #expect(snapshot.buckets.first?.remaining == 42.1)
}

@Test func aSecondDeepSeekKeyReadsTheDeepSeekBalanceRoute() async throws {
    let requests = SentRequests()
    let provider = CustomUsageProvider(
        store: .forTests,
        account: Account(.custom, name: "ds2"),
        baseURL: URL(string: "https://api.deepseek.com/v1")!,
        send: { request in
            requests.record(request.url!)
            let body = #"{"balance_infos":[{"currency":"USD","total_balance":"12.50"}]}"#
            return (Data(body.utf8), response(200, url: request.url!))
        }
    )

    let snapshot = await provider.fetch()
    // The same route the built-in provider reads, not the user's base URL plus a suffix.
    #expect(requests.recorded.map(\.absoluteString) == ["https://api.deepseek.com/user/balance"])
    #expect(snapshot.provider == .custom)
    #expect(snapshot.account == "ds2")
    #expect(snapshot.buckets.first?.remaining == 12.5)
}

@Test func anUnknownAPIAsksForTheModelsItServes() async throws {
    let requests = SentRequests()
    let provider = CustomUsageProvider(
        store: .forTests,
        account: Account(.custom, name: "acme"),
        baseURL: URL(string: "https://api.example.com/v1")!,
        send: { request in
            requests.record(request.url!)
            return (Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8), response(200, url: request.url!))
        }
    )

    let snapshot = await provider.fetch()
    #expect(requests.recorded.map(\.path) == ["/v1/models"])
    #expect(requests.recorded.first?.host() == "api.example.com")
    #expect(snapshot.buckets.first?.label == "Key works")
    #expect(snapshot.message == "2 models")
}

@Test func aRefusedKeyBecomesASignInProblem() async throws {
    let provider = CustomUsageProvider(
        store: .forTests,
        account: Account(.custom, name: "acme"),
        baseURL: URL(string: "https://api.example.com/v1")!,
        send: { request in (Data(), response(401, url: request.url!)) }
    )

    let snapshot = await provider.fetch()
    #expect(snapshot.state == .unavailable)
    #expect(snapshot.account == "acme")
    #expect(snapshot.issue == .signInRequired)
    #expect(snapshot.message?.contains("acme unavailable") == true)
    #expect(snapshot.message?.contains("sign in again at api.example.com") == true)
}

@MainActor
@Test func hiddenSuggestionsSurviveARestart() throws {
    let suite = "MeterTests.custom.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = UsageStore(
        settings: MeterSettings(defaults: defaults),
        service: UsageService(providers: [:]),
        refreshOnEnable: false,
        secrets: .forTests
    )
    let account = Account(.cursor)
    #expect(!store.hiddenSuggestions.contains(account))

    store.setSuggestionHidden(true, for: account)
    #expect(store.hiddenSuggestions == [account])

    // A second store, as after a relaunch, reads the same put-away chip back.
    let reopened = UsageStore(
        settings: MeterSettings(defaults: defaults),
        service: UsageService(providers: [:]),
        refreshOnEnable: false,
        secrets: .forTests
    )
    #expect(reopened.hiddenSuggestions == [account])

    reopened.setSuggestionHidden(false, for: account)
    #expect(MeterSettings(defaults: defaults).hiddenSuggestions.isEmpty)
}
