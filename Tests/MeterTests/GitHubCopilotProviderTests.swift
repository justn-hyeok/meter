import Foundation
import Testing
@testable import MeterCore

/// As community documentation describes `GET /copilot_internal/user`.
private let copilotJSON = #"""
{
  "copilot_plan": "individual_pro",
  "quota_reset_date": "2026-11-01",
  "quota_snapshots": {
    "premium_interactions": {
      "entitlement": 300,
      "remaining": 71,
      "percent_remaining": 23.7,
      "unlimited": false,
      "overage_count": 0,
      "overage_permitted": false
    },
    "chat": {
      "entitlement": 5000,
      "remaining": 4200,
      "percent_remaining": 84,
      "unlimited": false
    },
    "completions": {
      "unlimited": true
    }
  }
}
"""#

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

@Test func copilotReadsEveryLimitedQuotaAsCounts() throws {
    let snapshot = try GitHubCopilotUsageParser.parse(Data(copilotJSON.utf8))

    #expect(snapshot.provider == .githubCopilot)
    #expect(snapshot.state == .live)
    // Unlimited quotas are skipped, and the rest keep the order Copilot's own clients use.
    #expect(snapshot.buckets.map(\.id) == ["premium_interactions", "chat"])

    let premium = try #require(snapshot.buckets.first)
    #expect(premium.label == "Premium requests")
    #expect(premium.used == 229)
    #expect(premium.limit == 300)
    #expect(premium.remaining == 71)
    #expect(premium.unit == .credits)
    // Counts, so the gauge comes from used over limit rather than a reported percentage.
    #expect(abs((premium.percentageUsed ?? 0) - 229.0 / 300 * 100) < 0.001)
    #expect(premium.resetAt == utcCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))

    #expect(snapshot.buckets.last?.label == "Chat")
    #expect(snapshot.buckets.last?.used == 800)
}

@Test func copilotReadsAResetDateThatCarriesATime() throws {
    let json = #"{"quota_reset_date":"2026-11-01T06:00:00.000Z","quota_snapshots":{"chat":{"entitlement":10,"remaining":4,"unlimited":false}}}"#
    let snapshot = try GitHubCopilotUsageParser.parse(Data(json.utf8))
    #expect(snapshot.buckets.first?.resetAt == utcCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 6)))
}

@Test func copilotSaysAnAllUnlimitedPlanIsUnlimited() throws {
    let json = #"{"quota_snapshots":{"chat":{"unlimited":true},"completions":{"unlimited":true}}}"#
    let snapshot = try GitHubCopilotUsageParser.parse(Data(json.utf8))
    #expect(snapshot.state == .unavailable)
    #expect(snapshot.message == "Unlimited plan")
    #expect(snapshot.buckets.isEmpty)
}

@Test func copilotRejectsAResponseWithNoQuotaToReport() {
    // Without the field there is nothing to show and no honest placeholder to invent.
    #expect(throws: URLError.self) { try GitHubCopilotUsageParser.parse(Data("{}".utf8)) }
    // A zero entitlement is not a quota either: 0 of 0 would read as a full bar.
    let zero = #"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"unlimited":false}}}"#
    #expect(throws: URLError.self) { try GitHubCopilotUsageParser.parse(Data(zero.utf8)) }
    #expect(throws: URLError.self) { try GitHubCopilotUsageParser.parse(Data("[]".utf8)) }
}

@Test func copilotTokenComesFromTheEnvironmentBeforeTheCLI() {
    let environment = GitHubCopilotCredential(environment: ["GH_TOKEN": "env-gh", "GITHUB_TOKEN": "env-github"], readCLIToken: { "cli-token" })
    #expect(environment.token() == "env-gh")
    #expect(environment.sourceDescription == "environment GH_TOKEN")

    let secondary = GitHubCopilotCredential(environment: ["GITHUB_TOKEN": "env-github"], readCLIToken: { "cli-token" })
    #expect(secondary.token() == "env-github")
    #expect(secondary.sourceDescription == "environment GITHUB_TOKEN")

    // Empty is unset, the way a shell exports it.
    let empty = GitHubCopilotCredential(environment: ["GH_TOKEN": ""], readCLIToken: { "cli-token" })
    #expect(empty.token() == "cli-token")

    let cli = GitHubCopilotCredential(environment: [:], readCLIToken: { "cli-token" })
    #expect(cli.token() == "cli-token")
    #expect(cli.sourceDescription == "gh auth")
}

@Test func copilotSendsTheHeadersGitHubsAPIChecks() throws {
    let credential = GitHubCopilotCredential(environment: ["GH_TOKEN": "gho_abc"], readCLIToken: { nil })
    #expect(try credential.authHeaders() == [
        "Authorization": "token gho_abc",
        "Accept": "application/json",
        "Editor-Version": "vscode/1.99.0",
        "User-Agent": "Meter",
    ])
}

@Test func copilotWithoutATokenAsksForGHSignIn() {
    let credential = GitHubCopilotCredential(environment: [:], readCLIToken: { nil })
    #expect(throws: CredentialError.signInRequired("github.com (or run 'gh auth login')")) {
        try credential.authHeaders()
    }
}

@Test func doctorReportsCopilotThroughTheGitHubCLI() {
    let store = SecretStore.forTests
    func machine(environment: [String: String] = [:], gh: Bool = false) -> DiagnosticEnvironment {
        DiagnosticEnvironment(
            environment: environment,
            secrets: store,
            fileExists: { gh && $0.lastPathComponent == "gh" }
        )
    }

    let withGH = CredentialDoctor.diagnose([.githubCopilot], in: machine(gh: true))[0]
    #expect(withGH.availability == .ready)
    #expect(withGH.source == "gh auth")
    // `gh auth token` is never run here: the token is read on the first fetch.
    #expect(withGH.detail.contains("gh found"))

    let bare = CredentialDoctor.diagnose([.githubCopilot], in: machine())[0]
    #expect(bare.availability == .missing)
    #expect(bare.detail == "install the GitHub CLI and run gh auth login")

    // A token only this shell can see leaves the app with nothing.
    let environmentOnly = CredentialDoctor.diagnose(
        [.githubCopilot], in: machine(environment: ["GITHUB_TOKEN": "gho_x"])
    )[0]
    #expect(environmentOnly.availability == .missing)
    #expect(environmentOnly.detail.contains("GITHUB_TOKEN is set in this shell only"))
}
