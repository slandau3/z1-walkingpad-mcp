import CoreBluetooth
import Foundation

public enum Z1Error: Error, Equatable, LocalizedError {
    case notFound
    case notConnected
    case unlockTimeout
    case vendorTimeout
    case controlPointTimeout
    case controlRefused(op: UInt8, result: UInt8)
    case speedOutOfRange(Double)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Z1 treadmill not found (is it on and not connected to another app?)"
        case .notConnected:
            "not connected/unlocked — call connect() first"
        case .unlockTimeout:
            "unlock timed out — pad did not answer the supplement handshake"
        case .vendorTimeout:
            "vendor frame response timed out"
        case .controlPointTimeout:
            "control point indication timed out"
        case .controlRefused(let op, let result):
            "control point refused op \(String(format: "%02x", op)): \(Self.cpResultName(result))"
        case .speedOutOfRange(let kmh):
            "speed \(kmh) out of range"
        }
    }

    static func cpResultName(_ result: UInt8) -> String {
        switch result {
        case 1: "success"
        case 2: "op not supported"
        case 3: "invalid parameter"
        case 4: "failed"
        case 5: "control not permitted"
        default: "code \(result)"
        }
    }
}

public struct SessionSummary: Sendable, Equatable {
    public var durationS: Int
    public var distanceM: Int
    public var steps: Int
    public var avgSpeedKmh: Double
    public var caloriesKcal: Double
    public var weightKgUsed: Double

    public init(durationS: Int, distanceM: Int, steps: Int, avgSpeedKmh: Double, caloriesKcal: Double, weightKgUsed: Double) {
        self.durationS = durationS
        self.distanceM = distanceM
        self.steps = steps
        self.avgSpeedKmh = avgSpeedKmh
        self.caloriesKcal = caloriesKcal
        self.weightKgUsed = weightKgUsed
    }
}

/// Async BLE client for the KingSmith WalkingPad Z1.
///
/// Protocol recap (see docs/protocol.md): the pad ignores every FTMS control
/// point command and suppresses all notifications until the supplement-channel
/// unlock frame lands. Order:
///
/// 1. subscribe supplement notify characteristic
/// 2. send unlock frame (write WITHOUT response)
/// 3. await 71 80 -> send SYS_INFO -> SETTING_GET
/// 4. FTMS works from here on: request control -> start/stop/set speed
///
/// Mirrors `client.py`.
public actor Z1Treadmill {

    public enum Phase: String, Sendable {
        case disconnected
        case scanning
        case connecting
        case ready
        case error
    }

    /// Snapshot of everything the UI needs. Speed is the live belt speed;
    /// distance/elapsed/steps are deltas since the last `start()` (pad
    /// counters persist across BLE connections).
    public struct Status: Sendable, Equatable {
        public var phase: Phase = .disconnected
        public var deviceName: String?
        public var beltRunning = false
        public var speedKmh = 0.0
        public var distanceM = 0
        public var elapsedS = 0
        public var steps = 0
        public var caloriesKcal = 0.0
        public var minSpeedKmh = 1.6
        public var maxSpeedKmh = 6.4
        public var hasTelemetry = false
        public var properties: [Int: Int] = [:]
        public var errorMessage: String?

        public init() {}
    }

    public private(set) var status = Status()
    public nonisolated let statusUpdates: AsyncStream<Status>
    private let statusYield: AsyncStream<Status>.Continuation

    private let transport = BLETransport()
    private var notifyPump: Task<Void, Never>?

    private var telemetry = Z1Protocol.TreadmillData()
    // The pad is the master of counters: time/distance/steps are shown
    // exactly as the pad reports them (it resets them on Stop and on its
    // own schedule). Calories are computed client-side but follow the same
    // lifecycle — the tracker resets whenever the pad's counters do.
    //
    // Opt-out: when persistStats is on, regressions fold into statOffsets
    // (and the calorie tracker keeps going), so stats accumulate across
    // sessions until clearStats() is called.
    private var calorieTracker = CalorieTracker()
    private var statOffsets = (elapsed: 0, distance: 0, steps: 0)
    public private(set) var persistStats = false
    private var strideLearner = StrideLearner()
    private var correctedSteps = 0.0

    /// Live step count: relay the pad's counter so the UI updates on every
    /// telemetry step delta, even when integer-meter distance is unchanged.
    public var stepsDisplay: Int {
        displayStat(telemetry.steps, statOffsets.steps)
    }

    /// Session step count: use the learned distance estimate after calibration.
    private var correctedStepsDisplay: Int {
        strideLearner.calibrated
            ? Int(correctedSteps.rounded())
            : stepsDisplay
    }
    private var calorieStateRestored = false
    private var lastTargetSpeed: Double?
    private var hasControl = false
    private var unlocked = false
    private var expectingDisconnect = false
    private var lastVendorWrite: ContinuousClock.Instant?
    private var lastControlWrite: ContinuousClock.Instant?

    struct Frame: Sendable {
        var cmd0: UInt8
        var cmd1: UInt8
        var data: Data
    }

    private struct Waiter<T: Sendable> {
        let id: UUID
        let cont: CheckedContinuation<T, Error>
        var timeout: Task<Void, Never>?
    }

    private typealias VendorWaiter = (waiter: Waiter<Frame>, pred: @Sendable (Frame) -> Bool)
    private var vendorWaiters: [VendorWaiter] = []
    private var cpWaiters: [Waiter<Data>] = []

    public init(weightKg: Double = Z1Metrics.defaultWeightKg) {
        var cont: AsyncStream<Status>.Continuation!
        statusUpdates = AsyncStream { cont = $0 }
        statusYield = cont
        calorieTracker = CalorieTracker(weightKg: weightKg)
    }

    private var pumpStarted = false

    /// Deferred out of `init`: actor initializers can't capture `self` in
    /// escaping closures. Called at the top of `connect()`.
    private func ensurePumpStarted() {
        guard !pumpStarted else { return }
        pumpStarted = true
        transport.onDisconnect = { [weak self] in
            guard let self else { return }
            Task { await self.handleTransportDisconnect() }
        }
        notifyPump = Task { [weak self] in
            guard let self else { return }
            for await (uuidString, data) in self.transport.notifications {
                await self.handleNotification(uuidString, data)
            }
        }
    }

    public var deviceName: String? { status.deviceName }

    /// Estimated calories for the current session (since last `start()`).
    public var caloriesKcal: Double { calorieTracker.totalKcal }

    public func setWeight(_ kg: Double) {
        guard kg > 0 else { return }
        calorieTracker.weightKg = kg
        emitStatus()
    }

    // MARK: - connection

    public func connect() async throws {
        guard status.phase == .disconnected || status.phase == .error else { return }
        ensurePumpStarted()
        mutate {
            $0.phase = .scanning
            $0.errorMessage = nil
            $0.hasTelemetry = false
        }
        do {
            try await transport.waitPoweredOn()
            let name = try await transport.scan(
                namePrefix: Z1Constants.deviceNamePrefix,
                timeout: Z1Constants.scanTimeout
            )
            mutate { $0.phase = .connecting; $0.deviceName = name }
            try await transport.connect(timeout: Z1Constants.connectTimeout)
            try await transport.discoverProfile(
                services: [Z1Constants.fitnessMachineService, Z1Constants.supplementService],
                characteristics: [
                    Z1Constants.charSupportedSpeedRange,
                    Z1Constants.charTreadmillData,
                    Z1Constants.charFitnessMachineStatus,
                    Z1Constants.charControlPoint,
                    Z1Constants.charSupplementNotify,
                    Z1Constants.charSupplementWrite,
                ]
            )

            // 1. supplement notify FIRST — before any vendor write
            try await transport.setNotify(Z1Constants.charSupplementNotify, enable: true)
            // telemetry (informational; stays silent pre-unlock)
            try? await transport.setNotify(Z1Constants.charTreadmillData, enable: true)
            try? await transport.setNotify(Z1Constants.charFitnessMachineStatus, enable: true)

            // 2. unlock — write without response; success arrives as 71 80
            unlocked = false
            _ = try await vendorRoundtrip(
                Z1Protocol.unlockFrame(deviceName: name),
                pred: { $0.cmd0 == Z1Constants.vopUnlock && $0.cmd1 == 0x80 },
                timeout: Z1Constants.unlockTimeout
            )
            unlocked = true

            // 3. extension init (best-effort: pad still works if these time out)
            _ = try? await vendorRoundtrip(
                Z1Protocol.sysInfoFrame(unixTime: UInt32(Date().timeIntervalSince1970)),
                pred: { $0.cmd0 == Z1Constants.vopUnlock && $0.cmd1 == 0x81 }
            )
            if let reply = try? await vendorRoundtrip(
                Z1Protocol.settingGetFrame(),
                pred: { $0.cmd0 == Z1Constants.vopProperty && $0.cmd1 == 0x80 }
            ) {
                let props = Z1Protocol.parsePropertyRecords(reply.data)
                mutate { $0.properties = props }
            }

            // FTMS statics + control point indications
            if let range = try? await transport.read(Z1Constants.charSupportedSpeedRange), range.count >= 4 {
                let lo = Int(range[range.startIndex]) | (Int(range[range.startIndex + 1]) << 8)
                let hi = Int(range[range.startIndex + 2]) | (Int(range[range.startIndex + 3]) << 8)
                mutate {
                    $0.minSpeedKmh = Double(lo) / 100
                    $0.maxSpeedKmh = Double(hi) / 100
                }
            }
            try await transport.setNotify(Z1Constants.charControlPoint, enable: true)

            mutate { $0.phase = .ready }
        } catch {
            unlocked = false
            await transport.disconnect()
            mutate {
                $0.phase = .error
                $0.errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    public func disconnect() async {
        if hasControl, unlocked {
            _ = try? await stop()
        }
        expectingDisconnect = true
        await transport.disconnect()
        resetConnectionState()
        mutate { $0.phase = .disconnected }
    }

    private func handleTransportDisconnect() {
        if expectingDisconnect {
            expectingDisconnect = false
            return
        }
        resetConnectionState()
        failAllWaiters(Z1Error.notConnected)
        mutate {
            $0.phase = .disconnected
            $0.errorMessage = "Connection lost"
        }
    }

    private func resetConnectionState() {
        unlocked = false
        hasControl = false
        lastTargetSpeed = nil
        telemetry = Z1Protocol.TreadmillData()
        calorieStateRestored = false
        mutate { $0.beltRunning = false }
    }

    // MARK: - public control API

    public func start() async throws {
        try requireReady()
        try await ensureControl()
        // the pad refuses START (result 4) when the belt is already moving —
        // e.g. started by the physical remote. Nothing to do in that case.
        if (telemetry.speedKmh ?? 0) <= 0 {
            try await controlCommand(Data([Z1Constants.opStartOrResume]), tunnelOp: 0x07)
        }
        lastTargetSpeed = nil // belt restarts at minimum speed
        mutate { $0.beltRunning = true }
    }

    @discardableResult
    public func stop() async throws -> SessionSummary {
        try requireReady()
        try await ensureControl()
        // summary first: the pad resets its counters when Stop lands
        let summary = sessionSummary()
        try await controlCommand(
            Data([Z1Constants.opStopOrPause, Z1Constants.stopParamStop]), tunnelOp: 0x08, tunnelParams: Data([0x01])
        )
        mutate { $0.beltRunning = false }
        return summary
    }

    public func pause() async throws {
        try requireReady()
        try await ensureControl()
        try await controlCommand(
            Data([Z1Constants.opStopOrPause, Z1Constants.stopParamPause]), tunnelOp: 0x08, tunnelParams: Data([0x02])
        )
        mutate { $0.beltRunning = false }
    }

    public func setSpeed(_ kmh: Double) async throws {
        try requireReady()
        guard kmh >= status.minSpeedKmh, kmh <= status.maxSpeedKmh else {
            throw Z1Error.speedOutOfRange(kmh)
        }
        try await ensureControl()
        let value = UInt16((kmh * 100).rounded())
        let params = Data([UInt8(value & 0xFF), UInt8(value >> 8)])
        try await controlCommand(Data([Z1Constants.opSetTargetSpeed]) + params, tunnelOp: 0x02, tunnelParams: params)
        lastTargetSpeed = kmh
    }

    /// Nudge speed up; returns the new target.
    @discardableResult
    public func speedUp(deltaKmh: Double = 0.1) async throws -> Double {
        try await nudgeSpeed(deltaKmh)
    }

    /// Nudge speed down; returns the new target.
    @discardableResult
    public func speedDown(deltaKmh: Double = 0.1) async throws -> Double {
        try await nudgeSpeed(-deltaKmh)
    }

    private func nudgeSpeed(_ delta: Double) async throws -> Double {
        // prefer the last commanded target: telemetry lags ~1s, so rapid
        // successive nudges would otherwise re-read the stale speed
        let current = lastTargetSpeed ?? telemetry.speedKmh ?? status.minSpeedKmh
        var target = ((current + delta) * 10).rounded() / 10 // pad steps are 0.1 km/h
        if target == current {
            // a display-unit step (e.g. 0.1 mph ≈ 0.16 km/h) can round back to
            // the current speed — force at least one 0.1 km/h pad step
            target = ((current + (delta >= 0 ? 0.1 : -0.1)) * 10).rounded() / 10
        }
        target = max(status.minSpeedKmh, min(status.maxSpeedKmh, target))
        try await setSpeed(target)
        return target
    }

    /// Sync the pad's own LED display units. Per the docs/protocol.md property
    /// table, property 1 is "units / screen language" and bit 1 (0x0002)
    /// selects miles vs km; all other bits are preserved from the cached
    /// SETTING_GET dump (default 0 if absent).
    public func setDisplayUnits(imperial: Bool) async throws {
        try requireReady()
        let current = status.properties[1] ?? 0
        let value = Z1Units.displayUnitsValue(current: current, imperial: imperial)
        _ = try await vendorRoundtrip(
            Z1Protocol.propertyWriteFrame(propID: 1, value: UInt16(value)),
            pred: { $0.cmd0 == Z1Constants.vopProperty && $0.cmd1 == 0x81 && $0.data.first == 1 }
        )
        mutate { $0.properties[1] = value }
    }

    /// Soft power-off: stop the belt (if running) and switch the pad to
    /// standby mode. Property 10 mode index 2 = sleep, per the
    /// docs/protocol.md property table (bits 5–7 hold the mode; preserved).
    /// Verified on hardware: 0x0200 (manual) <-> 0x0240 (sleep).
    public func sleep() async throws {
        try requireReady()
        if status.beltRunning {
            _ = try await stop()
        }
        let current = status.properties[10] ?? 0
        let value = (current & ~0xE0) | (2 << 5)
        _ = try await vendorRoundtrip(
            Z1Protocol.propertyWriteFrame(propID: 10, value: UInt16(value)),
            pred: { $0.cmd0 == Z1Constants.vopProperty && $0.cmd1 == 0x81 && $0.data.first == 10 }
        )
        mutate { $0.properties[10] = value }
    }

    /// Current session metrics: the pad's own counters plus our kcal.
    /// With persistStats on, totals accumulate across sessions since the
    /// last clearStats().
    public func sessionSummary() -> SessionSummary {
        let durationS = displayStat(telemetry.elapsedS, statOffsets.elapsed)
        let distanceM = displayStat(telemetry.distanceM, statOffsets.distance)
        let avg: Double = (durationS > 0 && distanceM > 0)
            ? (Double(distanceM) / Double(durationS) * 3.6 * 100).rounded() / 100
            : 0
        return SessionSummary(
            durationS: durationS,
            distanceM: distanceM,
            steps: correctedStepsDisplay,
            avgSpeedKmh: avg,
            caloriesKcal: (calorieTracker.totalKcal * 10).rounded() / 10,
            weightKgUsed: calorieTracker.weightKg
        )
    }

    // MARK: - stats persistence

    public func setPersistStats(_ on: Bool) {
        persistStats = on
        if !on {
            // back to pad-as-master: drop the accumulated offsets
            statOffsets = (elapsed: 0, distance: 0, steps: 0)
        }
        emitStatus()
    }

    /// Zero all accumulated stats (offsets + calorie estimate) and the
    /// on-disk calorie state, so nothing restores old totals later.
    public func clearStats() {
        statOffsets = (elapsed: 0, distance: 0, steps: 0)
        calorieTracker.reset()
        correctedSteps = 0
        UserDefaults.standard.removeObject(forKey: Self.calorieStateKey)
        persistCalorieState()
        emitStatus()
    }

    private func displayStat(_ cur: Int?, _ offset: Int) -> Int {
        persistStats ? max(0, (cur ?? 0) + offset) : (cur ?? 0)
    }

    // MARK: - telemetry

    private func handleNotification(_ uuidString: String, _ data: Data) {
        switch uuidString {
        case Z1Constants.charSupplementNotify.uuidString:
            guard let parsed = Z1Protocol.parseFrame(data) else { return }
            let frame = Frame(cmd0: parsed.cmd0, cmd1: parsed.cmd1, data: parsed.data)
            var matched: [Int] = []
            for (i, w) in vendorWaiters.enumerated() where w.pred(frame) {
                matched.append(i)
            }
            for i in matched.reversed() {
                let w = vendorWaiters.remove(at: i)
                w.waiter.timeout?.cancel()
                w.waiter.cont.resume(returning: frame)
            }
        case Z1Constants.charControlPoint.uuidString:
            if !cpWaiters.isEmpty {
                let w = cpWaiters.removeFirst()
                w.timeout?.cancel()
                w.cont.resume(returning: data)
            }
        case Z1Constants.charTreadmillData.uuidString:
            handleTelemetry(data)
        case Z1Constants.charFitnessMachineStatus.uuidString:
            // belt-state events from the pad itself (the master): works even
            // when no treadmill-data frames flow (e.g. belt fully stopped)
            guard let op = data.first else { return }
            switch op {
            case 4: mutate { $0.beltRunning = true } // started
            case 1, 2: mutate { $0.beltRunning = false } // safety-key / user stop or pause
            default: break
            }
        default:
            break
        }
    }

    private func handleTelemetry(_ data: Data) {
        let prev = telemetry
        telemetry = Z1Protocol.parseTreadmillData(data)
        // pad counter reset (Stop finalizes the pad session, or the pad's
        // own timer). Default: the pad is the master — stats follow it down.
        // With persistStats on: fold the final values into the offsets and
        // keep accumulating instead.
        let regressed: Bool = {
            guard let prevElapsed = prev.elapsedS, let curElapsed = telemetry.elapsedS else { return false }
            return curElapsed < prevElapsed
        }()
        if regressed {
            if persistStats {
                statOffsets.elapsed += prev.elapsedS ?? 0
                statOffsets.distance += prev.distanceM ?? 0
                statOffsets.steps += prev.steps ?? 0
            } else {
                calorieTracker.reset()
                correctedSteps = 0
            }
        } else {
            // step estimation: trust the pad's count at >= 3 km/h (and learn
            // the personal stride curve from it); below that, derive steps
            // from the exact belt distance and the learned stride
            let dDist = Double((telemetry.distanceM ?? 0) - (prev.distanceM ?? 0))
            let dSteps = Double((telemetry.steps ?? 0) - (prev.steps ?? 0))
            let speed = telemetry.speedKmh ?? 0
            if speed >= StrideLearner.trustSpeedKmh {
                if dDist > 0, dSteps > 0 {
                    strideLearner.learn(distanceM: dDist, steps: dSteps, speedKmh: speed)
                }
                if dSteps > 0 {
                    // Keep every trusted raw step delta, even when the pad's
                    // integer-meter distance has not advanced in this frame.
                    correctedSteps += dSteps
                } else if dDist > 0, let stride = strideLearner.stride(for: speed) {
                    correctedSteps += dDist / stride
                }
            } else if dDist > 0 {
                if let stride = strideLearner.stride(for: speed) {
                    correctedSteps += dDist / stride
                } else {
                    correctedSteps += max(dSteps, 0)
                }
            }
        }
        if !calorieStateRestored {
            calorieStateRestored = true
            restoreCalorieState()
        }
        // credit calorie burn for the interval just elapsed, while moving
        if let prevElapsed = prev.elapsedS,
           let curElapsed = telemetry.elapsedS,
           let prevSpeed = prev.speedKmh, prevSpeed > 0
        {
            calorieTracker.addSample(speedKmh: prevSpeed, elapsedS: Double(curElapsed - prevElapsed))
        }
        persistCalorieState()
        emitStatus()
    }

    // MARK: - calorie state persistence
    //
    // Calorie integration is client-side; the pad's own counters (elapsed,
    // distance) survive reconnects, so we persist the kcal total keyed
    // against them and restore on the next connection.

    private static let calorieStateKey = "z1.calorieState"

    private func persistCalorieState() {
        UserDefaults.standard.set(
            [
                "totalKcal": calorieTracker.totalKcal,
                "correctedSteps": correctedSteps,
                "elapsedS": telemetry.elapsedS ?? 0,
                "distanceM": telemetry.distanceM ?? 0,
            ],
            forKey: Self.calorieStateKey
        )
    }

    private func restoreCalorieState() {
        guard let state = UserDefaults.standard.dictionary(forKey: Self.calorieStateKey),
              let curElapsed = telemetry.elapsedS
        else { return }
        let savedElapsed = state["elapsedS"] as? Int ?? 0
        guard curElapsed >= savedElapsed else { return } // pad counters reset (power cycle) — fresh
        calorieTracker.totalKcal = state["totalKcal"] as? Double ?? 0
        correctedSteps = state["correctedSteps"] as? Double ?? 0
        // credit the gap while we were disconnected, if the belt kept moving
        let gapS = curElapsed - savedElapsed
        let gapD = (telemetry.distanceM ?? 0) - (state["distanceM"] as? Int ?? 0)
        if gapS > 0, gapD > 0 {
            let avgKmh = Double(gapD) / Double(gapS) * 3.6
            calorieTracker.addSample(speedKmh: avgKmh, elapsedS: Double(gapS))
            if let stride = strideLearner.stride(for: avgKmh) {
                correctedSteps += Double(gapD) / stride
            }
        }
    }

    private func emitStatus() {
        var s = status
        s.speedKmh = telemetry.speedKmh ?? 0
        // belt state is derived from the pad (the master): it may have been
        // started/stopped by the physical remote between our commands
        s.beltRunning = (telemetry.speedKmh ?? 0) > 0
        s.distanceM = displayStat(telemetry.distanceM, statOffsets.distance)
        s.elapsedS = displayStat(telemetry.elapsedS, statOffsets.elapsed)
        s.steps = stepsDisplay
        s.caloriesKcal = calorieTracker.totalKcal
        s.hasTelemetry = true
        status = s
        statusYield.yield(s)
    }

    private func mutate(_ body: (inout Status) -> Void) {
        body(&status)
        statusYield.yield(status)
    }

    // MARK: - vendor channel

    @discardableResult
    private func vendorRoundtrip(
        _ frame: Data,
        pred: @escaping @Sendable (Frame) -> Bool,
        timeout: TimeInterval = Z1Constants.vendorResponseTimeout
    ) async throws -> Frame {
        let id = UUID()
        return try await withCheckedThrowingContinuation { cont in
            var waiter = Waiter<Frame>(id: id, cont: cont)
            waiter.timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                await self.timeoutVendorWaiter(id)
            }
            vendorWaiters.append((waiter, pred))
            Task {
                do {
                    await paceVendor()
                    try await transport.write(Z1Constants.charSupplementWrite, frame, withResponse: false)
                } catch {
                    failVendorWaiter(id, error)
                }
            }
        }
    }

    private func timeoutVendorWaiter(_ id: UUID) {
        guard let i = vendorWaiters.firstIndex(where: { $0.waiter.id == id }) else { return }
        let w = vendorWaiters.remove(at: i)
        w.waiter.cont.resume(throwing: Z1Error.vendorTimeout)
    }

    private func failVendorWaiter(_ id: UUID, _ error: Error) {
        guard let i = vendorWaiters.firstIndex(where: { $0.waiter.id == id }) else { return }
        let w = vendorWaiters.remove(at: i)
        w.waiter.timeout?.cancel()
        w.waiter.cont.resume(throwing: error)
    }

    // MARK: - FTMS control point

    private func cpCommand(_ cmd: Data) async throws -> Data {
        let id = UUID()
        let resp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var waiter = Waiter<Data>(id: id, cont: cont)
            waiter.timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Z1Constants.vendorResponseTimeout))
                guard !Task.isCancelled, let self else { return }
                await self.timeoutCPWaiter(id)
            }
            cpWaiters.append(waiter)
            Task {
                do {
                    await paceControl()
                    try await transport.write(Z1Constants.charControlPoint, cmd, withResponse: true)
                } catch {
                    failCPWaiter(id, error)
                }
            }
        }
        // indication: 80 <request-op> <result> [params...]
        if resp.count >= 3, resp[resp.startIndex] == 0x80 {
            let result = resp[resp.startIndex + 2]
            guard result == 1 else {
                if result == 5 { hasControl = false } // re-request control next time
                throw Z1Error.controlRefused(op: resp[resp.startIndex + 1], result: result)
            }
        }
        return resp
    }

    /// 0x77 vendor control tunnel — fallback when the control point refuses
    /// (the pad sometimes transiently answers result 4 after a session; the
    /// tunnel is the documented alternate path, see docs/protocol.md).
    private func vendorControl(_ op: UInt8, params: Data = Data()) async throws {
        let reply = try await vendorRoundtrip(
            Z1Protocol.buildFrame(cmd0: 0x77, cmd1: 0x01, data: Data([op]) + params),
            pred: { $0.cmd0 == 0x77 && $0.cmd1 == 0x81 && $0.data.first == op }
        )
        let status = reply.data.count >= 2 ? reply.data[reply.data.startIndex + 1] : 0xFF
        guard status == 0 || status == 0x81 else {
            throw Z1Error.controlRefused(op: op, result: status)
        }
    }

    /// Send a control command, retrying once after a transient refusal
    /// (result 4), then falling back to the 0x77 vendor tunnel.
    private func controlCommand(_ cpBytes: Data, tunnelOp: UInt8, tunnelParams: Data = Data()) async throws {
        do {
            _ = try await cpCommand(cpBytes)
        } catch Z1Error.controlRefused(_, 4) {
            try await Task.sleep(for: .seconds(3))
            do {
                _ = try await cpCommand(cpBytes)
            } catch Z1Error.controlRefused(_, 4) {
                try await vendorControl(tunnelOp, params: tunnelParams)
            }
        }
    }

    private func timeoutCPWaiter(_ id: UUID) {
        guard let i = cpWaiters.firstIndex(where: { $0.id == id }) else { return }
        let w = cpWaiters.remove(at: i)
        w.cont.resume(throwing: Z1Error.controlPointTimeout)
    }

    private func failCPWaiter(_ id: UUID, _ error: Error) {
        guard let i = cpWaiters.firstIndex(where: { $0.id == id }) else { return }
        let w = cpWaiters.remove(at: i)
        w.timeout?.cancel()
        w.cont.resume(throwing: error)
    }

    private func ensureControl() async throws {
        if !hasControl {
            _ = try await cpCommand(Data([Z1Constants.opRequestControl]))
            hasControl = true
        }
    }

    private func failAllWaiters(_ error: Error) {
        let vendors = vendorWaiters
        vendorWaiters.removeAll()
        for w in vendors {
            w.waiter.timeout?.cancel()
            w.waiter.cont.resume(throwing: error)
        }
        let cps = cpWaiters
        cpWaiters.removeAll()
        for w in cps {
            w.timeout?.cancel()
            w.cont.resume(throwing: error)
        }
    }

    // MARK: - helpers

    private func requireReady() throws {
        guard status.phase == .ready, unlocked else { throw Z1Error.notConnected }
    }

    private func paceVendor() async {
        if let last = lastVendorWrite {
            let remaining = Z1Constants.vendorMinInterval - (ContinuousClock.now - last)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
        lastVendorWrite = ContinuousClock.now
    }

    private func paceControl() async {
        if let last = lastControlWrite {
            let remaining = Z1Constants.controlMinInterval - (ContinuousClock.now - last)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
        lastControlWrite = ContinuousClock.now
    }
}
