//
//  ScramblingService.swift
//  Session state machine. Invariants:
//  - the snapshot is captured before the first setSystemTime of a start or resume;
//  - real time is restored before `stopped` or `paused` is written;
//  - `active` (with its snapshot) is written before the first setSystemTime, so a crash is recoverable.
//

import AppKit

final class ScramblingService {
    enum LaunchCheck: Equatable {
        case ready
        /// state.json says `active`: the app died mid-session and the clock may still be scrambled.
        case interruptedSession
        case corruptState
    }

    /// Starts a repeating timer and returns the closure that cancels it.
    typealias Scheduler = (_ interval: TimeInterval, _ tick: @escaping () -> Void) -> () -> Void

    private(set) var state: AppState
    private(set) var launchCheck: LaunchCheck
    private(set) var isTransitioning = false
    /// The last tick's work; tests await it.
    private(set) var tickTask: Task<Void, Never>?
    /// Errors from ticks and sleep-triggered pauses, which have no caller to throw to.
    var onError: ((Error) -> Void)?

    var isScrambling: Bool { cancelTimer != nil }

    private let helper: HelperClient
    private let repository: StateRepository
    private let clock: SessionClock
    private let calendar: Calendar
    private let schedule: Scheduler
    private let random: (ClosedRange<Double>) -> Double
    private var observers: [(AppState) -> Void] = []
    private var cancelTimer: (() -> Void)?
    private var lastScrambled: Double?

    init(
        helper: HelperClient,
        repository: StateRepository,
        clock: SessionClock = .system,
        calendar: Calendar = .current,
        schedule: @escaping Scheduler = ScramblingService.repeatingTimer,
        random: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
        sleepNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.helper = helper
        self.repository = repository
        self.clock = clock
        self.calendar = calendar
        self.schedule = schedule
        self.random = random
        switch repository.load() {
        case .missing:
            state = .initial
            launchCheck = .ready
            try? repository.save(.initial)
        case .corrupt:
            state = .initial
            launchCheck = .corruptState
        case .loaded(let saved):
            state = saved
            launchCheck = saved.sessionState == .active ? .interruptedSession : .ready
        }
        sleepNotifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForSleep() }
        }
    }

    func observe(_ observer: @escaping (AppState) -> Void) {
        observers.append(observer)
    }

    // MARK: Transitions

    func start() async throws {
        try await activate(from: .stopped)
    }

    func resume() async throws {
        try await activate(from: .paused)
    }

    func pause() async throws {
        try await deactivate(to: .paused)
    }

    func stop() async throws {
        if state.sessionState == .paused, !isTransitioning {
            // Paused already runs on real time with NTP on.
            return try persist(.stopped, nil)
        }
        try await deactivate(to: .stopped)
    }

    func updateInterval(_ minutes: Int) throws {
        try AppState.validateInterval(minutes)
        var next = state
        next.intervalMinutes = minutes
        try save(next)
        if isScrambling {
            stopTimer()
            startTimer()
        }
    }

    /// After a corrupt state.json: reset to defaults, then turn NTP back on so macOS corrects a clock
    /// a crashed session may have left scrambled.
    func freshStart() async throws {
        try save(.initial)
        launchCheck = .ready
        try await helper.enableNTPSync()
    }

    /// stopped/paused → active: disableNTPSync → snapshot → write active → scramble → timer.
    private func activate(from previous: SessionState) async throws {
        guard state.sessionState == previous, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        try await helper.disableNTPSync()
        // A fresh snapshot on resume too: the paused clock is real, and an older anchor may predate a reboot.
        let snapshot = clock.snapshot()
        do {
            try persist(.active, snapshot)
            try await scramble(snapshot)
        } catch {
            // Undo; if the undo fails too, stay `active` so Stop or the next launch restores the clock.
            if (try? await restoreRealTime(snapshot)) != nil {
                try? persist(previous, previous == .paused ? snapshot : nil)
            }
            throw error
        }
        startTimer()
    }

    /// active → paused/stopped: cancel timer → restore (snapshot + Δt) → enableNTPSync → write.
    private func deactivate(to target: SessionState) async throws {
        guard state.sessionState == .active, !isTransitioning, let snapshot = state.realTimeSnapshot else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        let wasScrambling = isScrambling
        stopTimer()
        do {
            try await restoreRealTime(snapshot)
        } catch {
            if wasScrambling { startTimer() }
            throw error
        }
        try persist(target, target == .paused ? snapshot : nil)
    }

    private func pauseForSleep() {
        guard state.sessionState == .active else { return }
        Task {
            do {
                try await pause()
            } catch {
                onError?(error)
            }
        }
    }

    // MARK: Clock

    private func restoreRealTime(_ snapshot: RealTimeSnapshot) async throws {
        // Without a usable anchor (other boot, hand-written file) NTP alone corrects the clock.
        if let realNow = clock.realNow(since: snapshot) {
            try await helper.restoreSystemTime(to: realNow)
        }
        try await helper.enableNTPSync()
    }

    private func scramble(_ snapshot: RealTimeSnapshot) async throws {
        let timestamp = randomTime(onDayOf: clock.realNow(since: snapshot) ?? clock.now())
        try await helper.setSystemTime(to: timestamp)
        lastScrambled = timestamp
    }

    /// A whole second between 00:00:00 and 23:59:59 of the local calendar day containing `realNow`,
    /// never equal to the previous scrambled value.
    func randomTime(onDayOf realNow: Double) -> Double {
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: realNow))
        // Next midnight, so 23- and 25-hour DST days keep their real length.
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let range = dayStart.timeIntervalSince1970...(nextDay.timeIntervalSince1970 - 1)
        var timestamp: Double
        repeat {
            timestamp = random(range).rounded(.down)
        } while timestamp == lastScrambled
        return timestamp
    }

    private func startTimer() {
        cancelTimer = schedule(TimeInterval(state.intervalMinutes * 60)) { [weak self] in
            guard let self else { return }
            tickTask = Task { await self.tick() }
        }
    }

    private func stopTimer() {
        cancelTimer?()
        cancelTimer = nil
    }

    private func tick() async {
        guard state.sessionState == .active, !isTransitioning, let snapshot = state.realTimeSnapshot else { return }
        do {
            try await scramble(snapshot)
        } catch {
            onError?(error)
        }
    }

    // MARK: Persistence

    private func persist(_ session: SessionState, _ snapshot: RealTimeSnapshot?) throws {
        var next = state
        next.sessionState = session
        next.realTimeSnapshot = snapshot
        try save(next)
    }

    private func save(_ next: AppState) throws {
        try repository.save(next)
        state = next
        observers.forEach { $0(next) }
    }

    nonisolated static func repeatingTimer(interval: TimeInterval, tick: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer.tolerance = 1  // SC-002 allows 5 s
        RunLoop.main.add(timer, forMode: .common)  // .common keeps it firing while the menu is open
        return { timer.invalidate() }
    }
}
