import Foundation

/// Copilot's premium-request quota, read from the route the Copilot extensions call.
/// GitHub documents none of it; the shape below is community-maintained, so every field is
/// read defensively and a missing quota is an error rather than a made-up figure.
struct GitHubCopilotUsageProvider: UsageProvider {
    let id = ProviderID.githubCopilot
    private let credential: any CredentialSource

    init(credential: any CredentialSource = GitHubCopilotCredential()) {
        self.credential = credential
    }

    func fetch() async -> UsageSnapshot {
        do {
            let data = try await AuthenticatedRequest.json(
                "https://api.github.com/copilot_internal/user",
                credential: credential,
                signInAt: GitHubCopilotCredential.signInHint
            )
            return try GitHubCopilotUsageParser.parse(data)
        } catch {
            return .unavailable(id, "GitHub Copilot unavailable", error: error)
        }
    }
}

enum GitHubCopilotUsageParser {
    /// The order the Copilot clients themselves show the three quotas in.
    private static let knownIDs = ["premium_interactions", "chat", "completions"]

    static func parse(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = root["quota_snapshots"] as? [String: Any], !snapshots.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        let resetAt = resetDate(root["quota_reset_date"])
        var buckets: [UsageBucket] = []
        var unlimited = 0

        for id in orderedIDs(Array(snapshots.keys)) {
            guard let snapshot = snapshots[id] as? [String: Any] else { continue }
            if snapshot["unlimited"] as? Bool == true {
                unlimited += 1
                continue
            }
            guard let entitlement = numericValue(snapshot["entitlement"]), entitlement > 0,
                  let remaining = numericValue(snapshot["remaining"]) else { continue }
            // Counts, not percentages: the response's percent_remaining is rounded to one
            // decimal, while used and limit give the gauge the exact ratio.
            buckets.append(.init(
                id: id,
                label: label(id),
                used: max(0, entitlement - remaining),
                limit: entitlement,
                remaining: remaining,
                resetAt: resetAt,
                unit: .credits
            ))
        }

        // An unlimited plan has no figures to show, and an empty tile would read as broken.
        guard !buckets.isEmpty else {
            guard unlimited > 0, unlimited == snapshots.count else { throw URLError(.cannotParseResponse) }
            return .unavailable(.githubCopilot, "Unlimited plan")
        }
        return .init(
            provider: .githubCopilot,
            buckets: buckets,
            fetchedAt: now,
            source: "GitHub Copilot quota",
            state: .live,
            message: nil
        )
    }

    private static func orderedIDs(_ keys: [String]) -> [String] {
        knownIDs.filter(keys.contains) + keys.filter { !knownIDs.contains($0) }.sorted()
    }

    private static func label(_ id: String) -> String {
        switch id {
        case "premium_interactions": "Premium requests"
        case "chat": "Chat"
        case "completions": "Completions"
        default: id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `quota_reset_date` is a day, not an instant: "2026-11-01" means midnight UTC when the
    /// quota turns over. ISO 8601 is accepted too, in case it ever carries a time.
    private static func resetDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
