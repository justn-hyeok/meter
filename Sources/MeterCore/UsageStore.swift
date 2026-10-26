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

    /// `provider[#name]|bucket`, as settings store it.
    public var rawValue: String { "\(account.rawValue)|\(bucketID)" }

    public init?(rawValue: String) {
        guard let bar = rawValue.lastIndex(of: "|"),
              let account = Account(rawValue: String(rawValue[..<bar])) else { return nil }
        self.init(account: account, bucketID: String(rawValue[rawValue.index(after: bar)...]))
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
    /// Where a window counts as all but used up: red in the menu, and a second alert.
    public static let critical = 0.95

    /// Ties go to the window listed first, so the bold row is the first of the equals the
    /// reader comes to.
    /// A muted window is one the user said not to warn about: it never counts as tightest.
    public static func find(in snapshots: [UsageSnapshot], muted: Set<BucketKey> = []) -> BucketKey? {
        var tightest: (key: BucketKey, fraction: Double)?
        for snapshot in snapshots {
            for bucket in snapshot.buckets {
                guard let fraction = bucket.fractionUsed, fraction >= threshold,
                      !muted.contains(BucketKey(account: snapshot.accountID, bucketID: bucket.id)) else { continue }
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
    /// Windows the user said not to warn about: no colour, no alert, not in the gauge.
    public private(set) var muted: Set<BucketKey>
    /// Each account's tile size; one not listed is 2×2.
    /// Switched-off accounts whose "+" chip is put away.
    public private(set) var hiddenSuggestions: Set<Account>
    /// Custom OpenAI-compatible providers, by account name.
    public private(set) var customProviders: [String: CustomProviderConfig]
    public var menuWidth: MenuWidth { didSet { settings.menuWidth = menuWidth } }
    public var menuHeight: MenuHeight { didSet { settings.menuHeight = menuHeight } }
    /// Saved in settings; changing it restarts the background loop so the new interval
    /// applies now rather than after the current wait.
    public var refreshInterval: TimeInterval {
        didSet {
            guard refreshInterval != oldValue else { return }
            settings.refreshInterval = refreshInterval
            // The loop reads the interval each time it sleeps, so mid-refresh nothing needs
            // restarting; cancelling then would cancel the requests and mark every tile stale.
            if refreshTask != nil, !isRefreshing { start() }
        }
    }
    /// Called after every refresh lands, for work that follows the figures, such as alerts.
    public var onUpdate: (@MainActor () -> Void)?
    /// Set while a card is being dragged. The drag moves cards without saving, so nothing may
    /// replace the order or the account list under it until the drag ends.
    public var isReordering = false

    /// Identifies the most recently started fetch per provider, so a slow batch cannot
    /// land on top of a newer single refresh that has already answered.
    private var latestFetch: [Account: Int] = [:]
    private var latestFetchStartedAt: [Account: Date] = [:]
    private var snapshotFetchStartedAt: [Account: Date] = [:]
    private var fetchCounter = 0
    private var refreshTask: Task<Void, Never>?
    private let settings: MeterSettings
    private let refreshOnEnable: Bool
    private let service: UsageService
    private let secrets: SecretStore
    private let cache: UsageCache?

    public convenience init(
        defaults: UserDefaults = UserDefaults(suiteName: MeterSettings.suiteName) ?? .standard,
        refreshOnEnable: Bool = true
    ) {
        self.init(
            settings: MeterSettings(defaults: defaults),
            service: UsageService(),
            refreshOnEnable: refreshOnEnable,
            cache: .default
        )
    }

    init(
        settings: MeterSettings,
        service: UsageService,
        refreshOnEnable: Bool = true,
        secrets: SecretStore = .default,
        cache: UsageCache? = nil
    ) {
        self.settings = settings
        self.service = service
        self.secrets = secrets
        self.cache = cache
        self.refreshOnEnable = refreshOnEnable
        settings.migrateIfNeeded()
        let accounts = Account.all(in: secrets)
        self.accounts = accounts
        self.enabledAccounts = Set(settings.enabledAccounts(accounts))
        self.storedKeyProviders = Self.providersWithStoredKeys(secrets)
        self.order = settings.order(of: accounts)
        self.muted = settings.mutedWindows
        self.refreshInterval = settings.refreshInterval
        self.hiddenSuggestions = settings.hiddenSuggestions
        self.customProviders = settings.customProviders
        self.menuWidth = settings.menuWidth
        self.menuHeight = settings.menuHeight
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
            snapshotFetchStartedAt[account] = nil
        }
        settings.setEnabled(enabled, for: account)
        // Switched on from the menu, so someone is looking: a keychain dialog is welcome.
        if enabled && refreshOnEnable { Task { await refresh(account, interactive: true) } }
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
        let startedAt = Date.now
        let results = await Keychain.$allowInteraction.withValue(interactive) {
            await service.fetch(selected)
        }
        for snapshot in results { merge(snapshot, token: tokens[snapshot.accountID]) }
        try? cache?.save(selected.compactMap { snapshots[$0] }, startedAt: startedAt)

        // A refresh that produced nothing usable must not advertise itself as the last
        // update; the menu would otherwise show a fresh time above stale figures.
        defer { onUpdate?() }
        if results.contains(where: { incoming in
            incoming.state == .live && snapshots[incoming.accountID]?.state == .live
                && snapshots[incoming.accountID]?.fetchedAt == incoming.fetchedAt
        }) { lastRefresh = .now }
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

    /// Puts two accounts in each other's place and leaves every other one where it was.
    public func swap(_ account: Account, with other: Account, persist: Bool = true) {
        guard account != other,
              let first = order.firstIndex(of: account),
              let second = order.firstIndex(of: other) else { return }
        var swapped = order
        swapped.swapAt(first, second)
        order = swapped
        if persist { settings.saveOrder(swapped) }
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
            for account in enabledAccounts.subtracting(enabledNow) {
                snapshots[account] = nil
                snapshotFetchStartedAt[account] = nil
            }
            enabledAccounts = enabledNow
        }
        let keys = Self.providersWithStoredKeys(secrets)
        if keys != storedKeyProviders { storedKeyProviders = keys }
        let mutedNow = settings.mutedWindows
        if mutedNow != muted { muted = mutedNow }
        let hiddenNow = settings.hiddenSuggestions
        if hiddenNow != hiddenSuggestions { hiddenSuggestions = hiddenNow }
        let customNow = settings.customProviders
        if customNow != customProviders { customProviders = customNow }
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
        try cache?.invalidate(Account(provider))
        snapshots[Account(provider)] = nil
        snapshotFetchStartedAt[Account(provider)] = nil
        latestFetch[Account(provider)] = nil
        storedKeyProviders = Self.providersWithStoredKeys(secrets)
        credentialStatus = Dictionary(uniqueKeysWithValues: CredentialDoctor.diagnose().map { ($0.provider, $0) })
        Task { await refresh(Account(provider)) }
    }

    /// Removes the key typed for a provider's default account, so it falls back to whatever
    /// the machine has, or asks again.
    public func clearKey(for provider: ProviderID) throws {
        try secrets.setSecret(nil, for: provider)
        // The key is gone whatever happens next, so the screen says so first.
        snapshots[Account(provider)] = nil
        snapshotFetchStartedAt[Account(provider)] = nil
        storedKeyProviders = Self.providersWithStoredKeys(secrets)
        credentialStatus = Dictionary(uniqueKeysWithValues: CredentialDoctor.diagnose().map { ($0.provider, $0) })
        try? cache?.invalidate(Account(provider))
        Task { await refresh(Account(provider), interactive: true) }
    }

    /// Adds a named account with its key, switched on, the way `meter set-key --name` does.
    public func addAccount(_ provider: ProviderID, name: String, key: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.acceptsNamedAccounts else { throw AccountError.namesNotSupported(provider) }
        guard Account.isValid(name: name) else { throw AccountError.invalidName(name) }
        guard !key.isEmpty else { throw AccountError.emptyKey }
        let account = Account(provider, name: name)
        // From the key file, not the list loaded earlier: `meter set-key --name` may have
        // added one since, and checking a stale list overwrote its key without a word.
        let named = secrets.namedAccounts().filter { $0.provider == provider }
        guard !named.contains(account) else { throw AccountError.exists(account) }
        let defaults = provider.hasDefaultAccount ? 1 : 0
        guard named.count + defaults < provider.accountLimit else { throw AccountError.full(provider) }
        try secrets.setSecret(key, for: account)
        try? cache?.invalidate(account)
        settings.forget(account)
        reloadSettings(includingOrder: true)
        Task { await refresh(account, interactive: true) }
    }

    /// Removes a named account and its key; a default account cannot be removed, only hidden.
    public func removeAccount(_ account: Account) throws {
        guard account.name != nil else { throw AccountError.cannotRemoveDefault(account.provider) }
        try secrets.setSecret(nil, for: account)
        settings.forget(account)
        try? cache?.invalidate(account)
        if account.provider == .custom, let name = account.name {
            customProviders[name] = nil
            settings.customProviders = customProviders
        }
        snapshots[account] = nil
        snapshotFetchStartedAt[account] = nil
        reloadSettings(includingOrder: true)
    }

    /// A store showing `snapshots` and nothing else: no refresh, no keychain, no files of the
    /// user's. For the state gallery and previews.
    public static func preview(_ snapshots: [UsageSnapshot], namedAccounts: [Account] = []) -> UsageStore {
        let suite = "com.justn.meter.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let directory = FileManager.default.temporaryDirectory.appending(path: "MeterPreview-\(UUID().uuidString)")
        let secrets = SecretStore(fileURL: directory.appending(path: "credentials.json"))
        for account in namedAccounts where account.name != nil { try? secrets.setSecret("preview", for: account) }
        let settings = MeterSettings(defaults: defaults)
        for snapshot in snapshots { settings.setEnabled(true, for: snapshot.accountID) }
        let store = UsageStore(settings: settings, service: UsageService(providers: [:]), refreshOnEnable: false, secrets: secrets)
        for snapshot in snapshots { store.snapshots[snapshot.accountID] = snapshot }
        return store
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
        let startedAt = Date.now
        let snapshot = await Keychain.$allowInteraction.withValue(interactive) {
            await service.fetch(account)
        }
        merge(snapshot, token: token)
        if let stored = snapshots[account] { try? cache?.save([stored], startedAt: startedAt) }
        onUpdate?()
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
        if let invalidatedAt = cache?.invalidatedAt(for: account),
           snapshots[account] != nil,
           snapshotFetchStartedAt[account].map({ $0 <= invalidatedAt }) ?? true {
            snapshots[account] = nil
            snapshotFetchStartedAt[account] = nil
        }
        fetchCounter += 1
        latestFetch[account] = fetchCounter
        latestFetchStartedAt[account] = .now
        return fetchCounter
    }

    /// Follows the order on screen, so a tie goes to the card nearer the top.
    public var tightestLimit: BucketKey? {
        TightestLimit.find(in: order.compactMap { snapshots[$0] }, muted: muted)
    }

    public func isMuted(_ key: BucketKey) -> Bool { muted.contains(key) }

    /// Puts a switched-off account's "+" chip away, or brings it back.
    public func setSuggestionHidden(_ hidden: Bool, for account: Account) {
        if hidden { hiddenSuggestions.insert(account) } else { hiddenSuggestions.remove(account) }
        settings.hiddenSuggestions = hiddenSuggestions
    }

    /// Adds a custom OpenAI-compatible provider: a named `custom` account with its key, plus
    /// where its API lives.
    public func addCustomProvider(name: String, baseURL: String, key: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: baseURL), url.scheme == "https" || url.scheme == "http", url.host != nil else {
            throw AccountError.invalidBaseURL(baseURL)
        }
        try addAccount(.custom, name: name, key: key)
        customProviders[name] = CustomProviderConfig(baseURL: baseURL)
        settings.customProviders = customProviders
    }

    public func setMuted(_ isMuted: Bool, _ key: BucketKey) {
        if isMuted { muted.insert(key) } else { muted.remove(key) }
        settings.mutedWindows = muted
    }

    /// Every enabled provider answered and none produced data. `highestUsage` is nil for
    /// this and for "nothing enabled" alike, and the menu drew both as a zero-percent
    /// needle - a total credential failure looked like a healthy, idle account.
    public var isAllUnavailable: Bool {
        !enabledAccounts.isEmpty && enabledAccounts.allSatisfy { snapshots[$0]?.buckets.isEmpty ?? false }
    }

    public var highestUsage: Double? {
        snapshots.values.flatMap { snapshot in
            snapshot.buckets.filter { !muted.contains(BucketKey(account: snapshot.accountID, bucketID: $0.id)) }
        }
        .compactMap(\.fractionUsed).max()
    }

    private func merge(_ incoming: UsageSnapshot, token: Int?) {
        // Both callers suspend for up to fifteen seconds. In that window the user can switch
        // the provider off, or a newer fetch can answer first; neither result belongs here.
        let account = incoming.accountID
        guard enabled(account), let token, latestFetch[account] == token else { return }
        if let invalidatedAt = cache?.invalidatedAt(for: account),
           let startedAt = latestFetchStartedAt[account], startedAt <= invalidatedAt {
            snapshots[account] = nil
            snapshotFetchStartedAt[account] = nil
            return
        }

        if incoming.state == .unavailable,
           let previous = snapshots[account] ?? cache?.read()[account],
           previous.state != .unavailable,
           !previous.buckets.isEmpty {
            snapshots[account] = UsageSnapshot(
                provider: previous.provider,
                buckets: previous.buckets,
                fetchedAt: previous.fetchedAt,
                source: previous.source,
                state: .stale,
                message: incoming.message,
                issue: incoming.issue
            ).for(account)
        } else {
            snapshots[account] = incoming
            snapshotFetchStartedAt[account] = latestFetchStartedAt[account]
        }
    }
}

public enum AccountError: LocalizedError, Equatable {
    case namesNotSupported(ProviderID)
    case invalidName(String)
    case emptyKey
    case exists(Account)
    case full(ProviderID)
    case cannotRemoveDefault(ProviderID)
    case invalidBaseURL(String)

    public var errorDescription: String? {
        switch self {
        case .namesNotSupported(let provider): "\(provider.title) holds one account: the one its own app or CLI is signed in to."
        case .invalidName: "Use up to 20 letters, digits, '-', '_' or '.', not starting with '-'."
        case .emptyKey: "Paste the account's API key."
        case .exists(let account): "\(account.title) already exists."
        case .full(let provider):
            provider.hasDefaultAccount
                ? "\(provider.title) already has \(provider.accountLimit) accounts: the default and \(provider.accountLimit - 1) named ones."
                : "There are already \(provider.accountLimit) custom providers."
        case .cannotRemoveDefault(let provider): "The default \(provider.title) account can be hidden, not removed."
        case .invalidBaseURL(let value): "'\(value)' is not an http(s) address, such as https://api.example.com/v1."
        }
    }
}
