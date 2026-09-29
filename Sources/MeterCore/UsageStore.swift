import Foundation
import Observation

/// Identifies one window across the whole menu.
public struct BucketKey: Hashable, Sendable {
    public let account: Account
    public let bucketID: String

    public var provider: ProviderID { account.provider }

    public init(account: Account, bucketID: String) {
        self.account = account
        self.bucketID = bucketID
    }

    /// The default account's window.
    public init(provider: ProviderID, bucketID: String) {
        self.init(account: Account(provider), bucketID: bucketID)
    }
}

/// The window closest to its limit, but only once something is close enough for that to
/// matter. Emphasising a row while everything sits at 5% would be noise, so below the
/// threshold the answer is "nothing is urgent" rather than "this one is least fine".
///
/// The menu and the CLI both ask here. Each used to carry its own copy, and they broke ties
/// differently - the menu by declaration order, the CLI by the order on screen - so two
/// windows at the same percentage could be bold in one and plain in the other.
public enum TightestLimit {
    public static let threshold = 0.8

    /// Ties go to the window listed first, so the bold row is the first of the equals the
    /// reader comes to.
    public static func find(in snapshots: [UsageSnapshot]) -> BucketKey? {
        var tightest: (key: BucketKey, fraction: Double)?
        for snapshot in snapshots {
            for bucket in snapshot.buckets {
                guard let fraction = bucket.fractionUsed, fraction >= threshold else { continue }
                if tightest == nil || fraction > tightest!.fraction {
                    tightest = (BucketKey(account: snapshot.accountID, bucketID: bucket.id), fraction)
                }
            }
        }
        return tightest?.key
    }
}

/// Menu bar state: which providers are on, their latest snapshots, and the value that
/// drives the gauge.
///
/// Invariant: `snapshots` only ever holds providers that are currently enabled. The
/// gauge reads every snapshot it can see, so a snapshot left behind by a provider the
/// user switched off would keep driving it.
@MainActor
@Observable
public final class UsageStore {
    public private(set) var snapshots: [Account: UsageSnapshot] = [:]
    public private(set) var isRefreshing = false
    /// When usable data last arrived, not when a refresh was last attempted.
    public private(set) var lastRefresh: Date?
    public private(set) var enabledAccounts: Set<Account>
    /// Every account on the machine, switched on or off.
    public private(set) var accounts: [Account]
    /// Cached so the menu does not read the key file from inside a SwiftUI body.
    public private(set) var storedKeyProviders: Set<ProviderID>
    /// The order the menu draws accounts in; the user rearranges it by dragging cards.
    public private(set) var order: [Account]
    /// Cached so the menu does not probe the machine from inside a SwiftUI body.
    public private(set) var credentialStatus: [ProviderID: CredentialStatus] = [:]
    public var refreshInterval: TimeInterval = 300
    /// Set while a card is being dragged. The drag moves cards without saving, so nothing may
    /// replace the order or the account list under it until the drag ends.
    public var isReordering = false

    /// Identifies the most recently started fetch per provider, so a slow batch cannot
    /// land on top of a newer single refresh that has already answered.
    private var latestFetch: [Account: Int] = [:]
    private var fetchCounter = 0
    private var refreshTask: Task<Void, Never>?
    private let settings: MeterSettings
    private let refreshOnEnable: Bool
    private let service: UsageService
    private let secrets: SecretStore

    public convenience init(
        defaults: UserDefaults = UserDefaults(suiteName: MeterSettings.suiteName) ?? .standard,
        refreshOnEnable: Bool = true
    ) {
        self.init(
            settings: MeterSettings(defaults: defaults),
            service: UsageService(),
            refreshOnEnable: refreshOnEnable
        )
    }

    init(
        settings: MeterSettings,
        service: UsageService,
        refreshOnEnable: Bool = true,
        secrets: SecretStore = .default
    ) {
        self.settings = settings
        self.service = service
        self.secrets = secrets
        self.refreshOnEnable = refreshOnEnable
        settings.migrateIfNeeded()
        let accounts = Account.all(in: secrets)
        self.accounts = accounts
        self.enabledAccounts = Set(settings.enabledAccounts(accounts))
        self.storedKeyProviders = Self.providersWithStoredKeys(secrets)
        self.order = settings.order(of: accounts)
        self.credentialStatus = Dictionary(uniqueKeysWithValues: CredentialDoctor.diagnose().map { ($0.provider, $0) })
    }

    func enabled(_ provider: ProviderID) -> Bool {
        enabled(Account(provider))
    }

    public func enabled(_ account: Account) -> Bool {
        enabledAccounts.contains(account)
    }

    func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        setEnabled(enabled, for: Account(provider))
    }

    public func setEnabled(_ enabled: Bool, for account: Account) {
        let wasEnabled = enabledAccounts.contains(account)
        guard enabled != wasEnabled else { return }
        if enabled {
            enabledAccounts.insert(account)
        } else {
            enabledAccounts.remove(account)
            // Drop the data with the toggle, so the gauge stops counting it.
            snapshots[account] = nil
        }
        settings.setEnabled(enabled, for: account)
        if enabled && refreshOnEnable { Task { await refresh(account) } }
    }

    public func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(self.refreshInterval))
            }
        }
    }

    /// `interactive` is true only when the user is looking: opening the menu or pressing
    /// Refresh. A background refresh never raises a keychain dialog.
    public func refreshAll(interactive: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Not the order: this also runs on the five-minute timer, which can land mid-drag.
        reloadSettings(includingOrder: false)

        let selected = order.filter(enabled)
        let tokens = Dictionary(uniqueKeysWithValues: selected.map { ($0, beginFetch($0)) })
        let results = await Keychain.$allowInteraction.withValue(interactive) {
            await service.fetch(selected)
        }
        for snapshot in results { merge(snapshot, token: tokens[snapshot.accountID]) }

        // A refresh that produced nothing usable must not advertise itself as the last
        // update; the menu would otherwise show a fresh time above stale figures.
        if results.contains(where: { $0.state == .live }) { lastRefresh = .now }
    }

    /// Moves `provider` into `target`'s place: after it when moving down the list, before it
    /// when moving up - which is where a dragged card lands when it passes over another.
    ///
    /// A drag passes `persist: false` and saves only on the drop, so a drag abandoned with
    /// Esc or released outside the menu can put the old order back without having written
    /// every card it passed over along the way.
    public func move(_ account: Account, to target: Account, persist: Bool = true) {
        guard account != target,
              let from = order.firstIndex(of: account),
              let to = order.firstIndex(of: target) else { return }
        var moved = order
        moved.remove(at: from)
        moved.insert(account, at: to)
        order = moved
        if persist { settings.saveOrder(moved) }
    }

    func move(_ provider: ProviderID, to target: ProviderID, persist: Bool = true) {
        move(Account(provider), to: Account(target), persist: persist)
    }

    /// Takes up what the CLI or another copy of Meter changed while this one was running.
    ///
    /// All of it used to be read once at launch: after `meter disable codex` the menu kept
    /// Codex checked and kept polling it, after `meter set-key` the key field stayed up,
    /// and the next drag wrote the launch-time order back over an order saved elsewhere.
    public func reloadSettings(includingOrder: Bool) {
        // An account added or removed mid-drag waits for the drag to end: taking it up would
        // replace the order the drag is moving through, and Esc could no longer restore it.
        let accountsNow = isReordering ? accounts : Account.all(in: secrets)
        let accountsChanged = accountsNow != accounts
        if accountsChanged { accounts = accountsNow }
        let enabledNow = Set(settings.enabledAccounts(accountsNow))
        if enabledNow != enabledAccounts {
            // Keep the invariant: only enabled accounts have snapshots. That covers an
            // account whose key was removed, which is no longer in the list at all.
            for account in enabledAccounts.subtracting(enabledNow) { snapshots[account] = nil }
            enabledAccounts = enabledNow
        }
        let keys = Self.providersWithStoredKeys(secrets)
        if keys != storedKeyProviders { storedKeyProviders = keys }
        let status = Dictionary(uniqueKeysWithValues: CredentialDoctor.diagnose().map { ($0.provider, $0) })
        if status != credentialStatus { credentialStatus = status }
        // A new or removed account changes which cards exist, so it is taken up even when
        // the order otherwise waits for the menu to open.
        if (includingOrder && !isReordering) || accountsChanged {
            let saved = settings.order(of: accountsNow)
            if saved != order { order = saved }
        }
    }

    /// Saves the order on screen, ending a drag that moved cards with `persist: false`.
    public func saveOrder() {
        settings.saveOrder(order)
    }

    /// Puts back an order taken before a drag that was then abandoned.
    public func restoreOrder(_ previous: [Account]) {
        guard previous.count == order.count, Set(previous) == Set(order) else { return }
        order = previous
    }

    // MARK: - Provider keys

    public func hasStoredKey(for provider: ProviderID) -> Bool {
        storedKeyProviders.contains(provider)
    }

    /// Whether the menu should offer somewhere to type a key.
    ///
    /// Only for providers Meter is handed a credential for, and only while that provider
    /// is not working: Command Code is already authenticated by its own CLI's login, so
    /// asking for a key there was noise, and a key that turns out to be wrong brings the
    /// field back rather than stranding the user with no way to correct it.
    public func needsKey(_ provider: ProviderID) -> Bool {
        guard provider.acceptsStoredKey else { return false }
        if credentialStatus[provider]?.isUsable != true { return true }
        return snapshots[Account(provider)]?.state == .unavailable
    }

    /// Only the default account has a key field; named accounts are added with the CLI.
    public func needsKey(_ account: Account) -> Bool {
        account.name == nil && needsKey(account.provider)
    }

    /// Stores a key the user typed into the menu, then refreshes that provider.
    ///
    /// Throwing rather than swallowing: the directory can be unwritable, and a Save that
    /// silently did nothing while clearing the field left the user retyping forever.
    public func storeKey(_ value: String, for provider: ProviderID) throws {
        try secrets.setSecret(value, for: provider)
        storedKeyProviders = Self.providersWithStoredKeys(secrets)
        credentialStatus = Dictionary(uniqueKeysWithValues: CredentialDoctor.diagnose().map { ($0.provider, $0) })
        Task { await refresh(Account(provider)) }
    }

    /// Test seam: the emphasis rule is worth pinning without standing up a fake provider.
    func replaceSnapshotForTesting(_ snapshot: UsageSnapshot) {
        snapshots[snapshot.accountID] = snapshot
    }

    private static func providersWithStoredKeys(_ secrets: SecretStore) -> Set<ProviderID> {
        Set(ProviderID.allCases.filter { $0.acceptsStoredKey && secrets.hasSecret(for: $0) })
    }

    public func refresh(_ account: Account, interactive: Bool = false) async {
        guard enabled(account) else { return }
        let token = beginFetch(account)
        let snapshot = await Keychain.$allowInteraction.withValue(interactive) {
            await service.fetch(account)
        }
        merge(snapshot, token: token)
    }

    func refresh(_ provider: ProviderID, interactive: Bool = false) async {
        await refresh(Account(provider), interactive: interactive)
    }

    /// Called when the menu opens. Retries anything the background refresh could not read
    /// without a dialog, which is where the keychain prompt now appears.
    public func menuOpened() async {
        // The order is reloaded only here, where no drag can be under way: a drag moves
        // cards without saving, and reloading in the middle of one would undo its moves.
        reloadSettings(includingOrder: true)
        let stale = order.filter { enabled($0) && snapshots[$0]?.state != .live }
        // Default accounts one at a time, since each may raise a keychain dialog and two at
        // once would stack them. Named accounts read only the key file and never ask, so they
        // go together, alongside: in turn, offline, each waited out its own timeout.
        async let named: Void = withTaskGroup(of: Void.self) { group in
            for account in stale where account.name != nil {
                group.addTask { await self.refresh(account, interactive: false) }
            }
        }
        for account in stale where account.name == nil {
            await refresh(account, interactive: true)
        }
        await named
    }

    private func beginFetch(_ account: Account) -> Int {
        fetchCounter += 1
        latestFetch[account] = fetchCounter
        return fetchCounter
    }

    /// Follows the order on screen, so a tie goes to the card nearer the top.
    public var tightestLimit: BucketKey? {
        TightestLimit.find(in: order.compactMap { snapshots[$0] })
    }

    /// Every enabled provider answered and none produced data. `highestUsage` is nil for
    /// this and for "nothing enabled" alike, and the menu drew both as a zero-percent
    /// needle - a total credential failure looked like a healthy, idle account.
    public var isAllUnavailable: Bool {
        !enabledAccounts.isEmpty && enabledAccounts.allSatisfy { snapshots[$0]?.buckets.isEmpty ?? false }
    }

    public var highestUsage: Double? {
        snapshots.values.flatMap(\.buckets).compactMap(\.fractionUsed).max()
    }

    private func merge(_ incoming: UsageSnapshot, token: Int?) {
        // Both callers suspend for up to fifteen seconds. In that window the user can switch
        // the provider off, or a newer fetch can answer first; neither result belongs here.
        let account = incoming.accountID
        guard enabled(account), let token, latestFetch[account] == token else { return }

        if incoming.state == .unavailable,
           let previous = snapshots[account],
           previous.state != .unavailable,
           !previous.buckets.isEmpty {
            snapshots[account] = UsageSnapshot(
                provider: previous.provider,
                buckets: previous.buckets,
                fetchedAt: previous.fetchedAt,
                source: previous.source,
                state: .stale,
                message: incoming.message
            ).for(account)
        } else {
            snapshots[account] = incoming
        }
    }
}
