import Foundation

/// One window whose warnings are switched off, named the way the settings list shows it.
public struct MutedWindow: Identifiable, Sendable, Equatable {
    public let key: BucketKey
    public let accountTitle: String
    /// The window's label, or its id while the provider has not answered since it was muted.
    public let label: String

    public var id: BucketKey { key }
}

extension MutedWindow {
    /// Every muted window, ordered by account and then by window name.
    ///
    /// The labels come from the latest snapshots rather than the settings, because a label
    /// is the provider's word for the window and can change. A window with no snapshot keeps
    /// its id: muting it was deliberate, and hiding it would leave no way to undo.
    public static func all(_ muted: Set<BucketKey>, in snapshots: [Account: UsageSnapshot]) -> [MutedWindow] {
        muted
            .map { key in
                MutedWindow(
                    key: key,
                    accountTitle: key.account.title,
                    label: snapshots[key.account]?.buckets.first { $0.id == key.bucketID }?.label ?? key.bucketID
                )
            }
            // The id breaks ties between two windows a provider labelled the same, so the
            // list keeps one order between refreshes.
            .sorted { ($0.accountTitle, $0.label, $0.key.bucketID) < ($1.accountTitle, $1.label, $1.key.bucketID) }
    }
}
