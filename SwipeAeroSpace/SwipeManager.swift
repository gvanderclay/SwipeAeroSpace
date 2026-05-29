import Cocoa
import Foundation
import Socket
import SwiftUI
import os

enum Direction {
    case next
    case prev

    var value: String {
        switch self {
        case .next:
            "next"
        case .prev:
            "prev"
        }
    }
}

enum GestureState {
    case began
    case changed
    case ended
    case cancelled
}

enum SwipeAxis {
    case undecided
    case horizontal
    case vertical
}

enum SwipeError: Error {
    case SocketError(String)
    case CommandFail(String)
    case Unknown(String)
}

public struct ClientRequest: Codable, Sendable {
    public let command: String
    public let args: [String]
    public let stdin: String
    public let windowId: UInt32?
    public let workspace: String?

    public init(
        args: [String],
        stdin: String,
        windowId: UInt32?,
        workspace: String?
    ) {
        self.command = ""
        self.args = args
        self.stdin = stdin
        self.windowId = windowId
        self.workspace = workspace
    }
}

public struct ServerAnswer: Codable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let serverVersionAndHash: String

    public init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        serverVersionAndHash: String
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.serverVersionAndHash = serverVersionAndHash
    }
}

class SocketInfo: ObservableObject {
    @Published var socketConnected: Bool = false
}

extension Result {
    public var isSuccess: Bool {
        switch self {
        case .success: true
        case .failure: false
        }
    }
}

class SwipeManager {
    // user settings
    @AppStorage(SettingKey.threshold) private var swipeThreshold: Double = SettingDefaults.threshold
    private var internalThreshold: Float { Float(swipeThreshold) * 0.05 }
    @AppStorage(SettingKey.wrap) private var wrapWorkspace: Bool = SettingDefaults.wrap
    @AppStorage(SettingKey.natural) private var naturalSwipe: Bool = SettingDefaults.natural
    @AppStorage(SettingKey.skipEmpty) private var skipEmpty: Bool = SettingDefaults.skipEmpty
    @AppStorage(SettingKey.fingers) private var fingers: String = SettingDefaults.fingers
    @AppStorage(SettingKey.multiSwipe) private var multiSwipeEnabled: Bool = SettingDefaults.multiSwipe
    @AppStorage(SettingKey.maxSteps) private var maxSteps: Int = SettingDefaults.maxSteps
    @AppStorage(SettingKey.swipeUpOverview) private var swipeUpOverviewEnabled: Bool = SettingDefaults.swipeUpOverview
    @AppStorage(SettingKey.swipeUpFingers) private var swipeUpFingers: String = SettingDefaults.swipeUpFingers

    var socketInfo = SocketInfo()

    private var eventTap: CFMachPort? = nil
    private var runLoopSource: CFRunLoopSource? = nil
    private var accDisX: Float = 0
    private var accDisY: Float = 0
    private var swipeUpFired: Bool = false
    private var firedPosition: Int = 0
    private var prevTouchPositions: [String: NSPoint] = [:]
    private var state: GestureState = .ended
    private var swipeAxis: SwipeAxis = .undecided
    private var activeFingerCount: Int = 0
    private var gestureFocusDone: Bool = false
    private var pendingSwipeWork: DispatchWorkItem? = nil
    private var cachedNonEmptyWorkspaces: String? = nil
    private var socket: Socket? = nil
    private var reconnecting: Bool = false
    private var reconnectWorkItem: DispatchWorkItem? = nil
    private var reconnectGeneration: Int = 0
    private var isStopping: Bool = false
    private let initialReconnectDelay: TimeInterval = 1
    private let maxReconnectDelay: TimeInterval = 30
    private let workQueue = DispatchQueue(label: "swipe.workspace", qos: .userInteractive)
    private let workQueueKey = DispatchSpecificKey<Void>()
    private let overlayController = OverlayPanelController()

    private var logger: Logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "Info"
    )

    init() {
        workQueue.setSpecific(key: workQueueKey, value: ())
    }

    deinit {
        stop()
    }

    private var isOnWorkQueue: Bool {
        DispatchQueue.getSpecific(key: workQueueKey) != nil
    }

    private func setSocketConnected(_ connected: Bool) {
        if Thread.isMainThread {
            socketInfo.socketConnected = connected
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.socketInfo.socketConnected = connected
            }
        }
    }

    private func handleConnectionFailure() {
        socket?.close()
        socket = nil
        setSocketConnected(false)
        startReconnectLoop()
    }

    private func startReconnectLoop() {
        guard !isStopping else { return }
        guard !reconnecting else { return }

        reconnecting = true
        reconnectGeneration += 1
        scheduleReconnect(after: initialReconnectDelay, generation: reconnectGeneration)
    }

    private func scheduleReconnect(after delay: TimeInterval, generation: Int) {
        guard !isStopping else {
            reconnecting = false
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.isStopping,
                self.reconnecting,
                self.reconnectGeneration == generation
            else {
                return
            }

            self.logger.info("Trying reconnect socket...")
            if self.connectSocketOnWorkQueue(reconnect: true) {
                return
            }

            let nextDelay = min(delay * 2, self.maxReconnectDelay)
            self.scheduleReconnect(after: nextDelay, generation: generation)
        }

        reconnectWorkItem = workItem
        workQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func stopReconnectLoop() {
        reconnectGeneration += 1
        reconnecting = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func runCommand(args: [String], stdin: String, retry: Bool = false)
        -> Result<String, SwipeError>
    {
        guard let socket = socket else {
            handleConnectionFailure()
            return .failure(.SocketError("No socket created"))
        }
        do {
            let request = try JSONEncoder().encode(
                ClientRequest(args: args, stdin: stdin, windowId: nil, workspace: nil)
            )
            try socket.write(from: request)
            let _ = try Socket.wait(
                for: [socket],
                timeout: 0,
                waitForever: true
            )
            var answer = Data()
            try socket.read(into: &answer)
            let result = try JSONDecoder().decode(
                ServerAnswer.self,
                from: answer
            )
            if result.exitCode != 0 {
                return .failure(.CommandFail(result.stderr))
            }
            return .success(result.stdout)

        } catch let error {
            guard let socketError = error as? Socket.Error else {
                return .failure(.Unknown(error.localizedDescription))
            }
            // if we encouter the socket error
            // try reconnect the socket and rerun the command only once.
            if retry {
                handleConnectionFailure()
                return .failure(.SocketError(socketError.localizedDescription))
            }
            logger.info("Trying reconnect socket...")
            if connectSocketOnWorkQueue(reconnect: true) {
                return runCommand(args: args, stdin: stdin, retry: true)
            }
            return .failure(.SocketError(socketError.localizedDescription))
        }
    }

    private func getNonEmptyWorkspaces() -> Result<String, SwipeError> {
        let args = [
            "list-workspaces", "--monitor", "focused", "--empty", "no",
        ]
        return runCommand(args: args, stdin: "")
    }

    func showWorkspaceOverview() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            // Phase 1: quick query (3 socket calls) — show immediately
            let (shellWorkspaces, originalWs, focusedMonitorId) = self.queryWorkspacesShell()
            let originalWsOpt: String? = originalWs.isEmpty ? nil : originalWs

            let makeCallbacks: () -> (
                onSelect: (String) -> Void,
                onPreview: (String) -> Void,
                onRevert: () -> Void
            ) = { [weak self] in
                (
                    onSelect: { wsName in
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", wsName], stdin: "")
                        }
                    },
                    onPreview: { wsName in
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", wsName], stdin: "")
                        }
                    },
                    onRevert: {
                        guard let originalWs = originalWsOpt else { return }
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", originalWs], stdin: "")
                        }
                    }
                )
            }

            let cb = makeCallbacks()
            DispatchQueue.main.async {
                self.overlayController.show(
                    workspaces: shellWorkspaces,
                    focusedMonitorId: focusedMonitorId,
                    onSelect: cb.onSelect,
                    onPreview: cb.onPreview,
                    onRevert: cb.onRevert
                )
            }

            // Phase 2: fetch window details and update each workspace as it arrives
            self.queryWindows(for: shellWorkspaces)
        }
    }

    /// Quick query: workspace names, monitors, focused state (4 socket calls)
    /// Returns (workspaces, focusedWorkspaceName, focusedMonitorId)
    private func queryWorkspacesShell() -> ([WorkspaceInfo], String, String?) {
        let focusedResult = runCommand(
            args: ["list-workspaces", "--focused"], stdin: ""
        )
        let focusedWs = (try? focusedResult.get())?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""

        // Get the monitor ID for the focused workspace
        let focusedMonitorResult = runCommand(
            args: ["list-workspaces", "--focused", "--format", "%{monitor-id}"],
            stdin: ""
        )
        let focusedMonitorId = (try? focusedMonitorResult.get())?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let monitorResult = runCommand(
            args: [
                "list-monitors", "--format", "%{monitor-id}|%{monitor-name}",
            ],
            stdin: ""
        )
        var monitorNames: [String: String] = [:]
        if let monitorOutput = try? monitorResult.get() {
            for line in monitorOutput.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                if parts.count == 2 {
                    monitorNames[String(parts[0])] = String(parts[1])
                }
            }
        }

        let allResult = runCommand(
            args: [
                "list-workspaces", "--monitor", "all", "--empty", "no",
                "--format", "%{workspace}|%{monitor-id}",
            ],
            stdin: ""
        )
        guard let allOutput = try? allResult.get() else { return ([], focusedWs, focusedMonitorId) }

        let workspaces: [WorkspaceInfo] = allOutput.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = String(parts[0])
            let monitorId = String(parts[1])
            return WorkspaceInfo(
                id: name,
                windows: [],
                isFocused: name == focusedWs,
                monitorId: monitorId,
                monitorName: monitorNames[monitorId] ?? "Monitor \(monitorId)"
            )
        }
        return (workspaces, focusedWs, focusedMonitorId)
    }

    /// Fetch window details for a list of workspaces (1 socket call per workspace)
    private func queryWindows(for workspaces: [WorkspaceInfo]) {
        for ws in workspaces {
            let winResult = runCommand(
                args: [
                    "list-windows", "--workspace", ws.id,
                    "--format", "%{app-name}|%{window-title}",
                ],
                stdin: ""
            )
            let windows: [WindowInfo]
            if let winOutput = try? winResult.get(),
                !winOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                windows = winOutput.split(separator: "\n").enumerated().map {
                    idx, line in
                    let parts = line.split(separator: "|", maxSplits: 1)
                    return WindowInfo(
                        id: "\(ws.id)-\(idx)",
                        appName: parts.first.map(String.init) ?? "Unknown",
                        windowTitle: parts.count > 1
                            ? String(parts[1]) : ""
                    )
                }
            } else {
                windows = []
            }
            let updatedWorkspace = WorkspaceInfo(
                id: ws.id,
                windows: windows,
                isFocused: ws.isFocused,
                monitorId: ws.monitorId,
                monitorName: ws.monitorName
            )
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard self.overlayController.isVisible else { return }
                self.overlayController.update(workspace: updatedWorkspace)
            }
        }
    }

    @discardableResult
    private func switchWorkspace(direction: Direction) -> Result<
        String, SwipeError
    > {

        var res = runCommand(
            args: ["list-workspaces", "--monitor", "mouse", "--visible"],
            stdin: ""
        )
        guard let mouse_on = try? res.get() else {
            return res
        }
        res = runCommand(args: ["workspace", mouse_on], stdin: "")
        guard (try? res.get()) != nil else {
            return res
        }

        var args = ["workspace", direction.value]
        if wrapWorkspace {
            args.append("--wrap-around")
        }
        var stdin = ""
        if skipEmpty {
            res = getNonEmptyWorkspaces()
            guard let ws = try? res.get() else {
                return res
            }
            stdin = ws
            if stdin != "" {
                // explicitly insert '--stdin'
                args.append("--stdin")
            }
        }
        return runCommand(args: args, stdin: stdin)
    }

    func nextWorkspace() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch self.switchWorkspace(direction: .next) {
            case .success: return
            case .failure(let err): self.logger.error("\(err.localizedDescription)")
            }
        }
    }

    func prevWorkspace() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch self.switchWorkspace(direction: .prev) {
            case .success: return
            case .failure(let err): self.logger.error("\(err.localizedDescription)")
            }
        }

    }

    func connectSocket(reconnect: Bool = false) {
        if isOnWorkQueue {
            _ = connectSocketOnWorkQueue(reconnect: reconnect)
            return
        }

        workQueue.async { [weak self] in
            _ = self?.connectSocketOnWorkQueue(reconnect: reconnect)
        }
    }

    @discardableResult
    private func connectSocketOnWorkQueue(reconnect: Bool = false) -> Bool {
        guard !isStopping else { return false }

        if socket != nil && !reconnect {
            logger.warning("socket is connected")
            return true
        }

        let socket_path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
        var newSocket: Socket?
        do {
            if reconnect {
                socket?.close()
                socket = nil
            }

            newSocket = try Socket.create(
                family: .unix,
                type: .stream,
                proto: .unix
            )
            try newSocket?.connect(to: socket_path)
            guard !isStopping else {
                newSocket?.close()
                return false
            }
            socket = newSocket
            stopReconnectLoop()
            setSocketConnected(true)
            logger.info("connect to socket \(socket_path)")
            return true
        } catch let error {
            newSocket?.close()
            socket = nil
            setSocketConnected(false)
            logger.error("Unexpected error: \(error.localizedDescription)")
            startReconnectLoop()
            return false
        }
    }

    func start() {
        if eventTap != nil {
            logger.warning("SwipeManager is already started")
            return
        }
        logger.info("SwipeManager start")
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: { proxy, type, cgEvent, me in
                let wrapper = Unmanaged<SwipeManager>.fromOpaque(me!)
                    .takeUnretainedValue()
                return wrapper.eventHandler(
                    proxy: proxy,
                    eventType: type,
                    cgEvent: cgEvent
                )
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if eventTap == nil {
            logger.error("SwipeManager couldn't create event tap")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            runLoopSource,
            CFRunLoopMode.commonModes
        )
        CGEvent.tapEnable(tap: eventTap!, enable: true)

        workQueue.async { [weak self] in
            self?.startConnectionState()
        }
    }

    /// Must be called from the main thread (menubar Quit / deinit). It uses
    /// `workQueue.sync` for connection teardown while `stopEventTap()` uses
    /// `DispatchQueue.main.sync`; calling this from `workQueue` would deadlock.
    func stop() {
        logger.info("stop the app")
        stopEventTap()

        if isOnWorkQueue {
            stopConnectionState()
        } else {
            workQueue.sync {
                stopConnectionState()
            }
        }
    }

    private func startConnectionState() {
        isStopping = false
        _ = connectSocketOnWorkQueue()
    }

    private func stopConnectionState() {
        isStopping = true
        stopReconnectLoop()

        socket?.close()
        socket = nil
        setSocketConnected(false)
    }

    private func stopEventTap() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { [self] in
                stopEventTap()
            }
            return
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                runLoopSource,
                CFRunLoopMode.commonModes
            )
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func eventHandler(
        proxy: CGEventTapProxy,
        eventType: CGEventType,
        cgEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType.rawValue == NSEvent.EventType.gesture.rawValue,
            let nsEvent = NSEvent(cgEvent: cgEvent)
        {
            touchEventHandler(nsEvent)
        } else if eventType == .tapDisabledByUserInput
            || eventType == .tapDisabledByTimeout
        {
            logger.info("SwipeManager tap disabled \(eventType.rawValue)")
            CGEvent.tapEnable(tap: eventTap!, enable: true)
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    private func touchEventHandler(_ nsEvent: NSEvent) {
        let touches = nsEvent.allTouches()

        // Sometimes there are empty touch events that we have to skip. There are no empty touch events if Mission Control or App Expose use 3-finger swipes though.
        if touches.isEmpty {
            return
        }
        let touchesCount =
            touches.allSatisfy({ $0.phase == .ended }) ? 0 : touches.count
        if touchesCount == 0 {
            stopGesture()
        } else {
            processTouches(touches: touches, count: touchesCount)
        }
    }

    private func stopGesture() {
        if state == .began {
            state = .ended
            if swipeAxis != .vertical {
                handleGesture()
            }
            clearEventState()
        }
    }

    private func processTouches(touches: Set<NSTouch>, count: Int) {
        let hFingerCount = FingerCount(rawValue: fingers)?.count ?? FingerCount.three.count
        let vFingerCount = FingerCount(rawValue: swipeUpFingers)?.count ?? FingerCount.three.count
        if state != .began && (count == hFingerCount || count == vFingerCount) {
            state = .began
            activeFingerCount = count
        }
        // Update finger count while axis is still undecided — touch count
        // can fluctuate as fingers land, so use the latest stable count
        if state == .began && swipeAxis == .undecided {
            activeFingerCount = count
        }
        if state == .began {
            let (disX, disY) = swipeDistance(touches: touches)
            accDisX += disX
            accDisY += disY

            // Lock axis once we have enough movement
            if swipeAxis == .undecided {
                let threshold = internalThreshold * 0.3
                if abs(accDisX) > threshold || abs(accDisY) > threshold {
                    swipeAxis =
                        abs(accDisY) > abs(accDisX) ? .vertical : .horizontal
                }
            }

            // Vertical swipes: only fire if finger count matches overview setting
            if swipeAxis == .vertical && swipeUpOverviewEnabled
                && activeFingerCount == vFingerCount
            {
                let threshold = internalThreshold * 0.5
                if !swipeUpFired && accDisY > threshold {
                    swipeUpFired = true
                    if !overlayController.isVisible {
                        showWorkspaceOverview()
                    }
                }
                // Mid-gesture: swipe back down dismisses when accDisY reverses
                if swipeUpFired && accDisY < threshold * 0.5 {
                    swipeUpFired = false
                    DispatchQueue.main.async { [weak self] in
                        self?.overlayController.dismiss()
                    }
                }
                // New gesture: swipe down dismisses if overlay is already open
                if !swipeUpFired && accDisY < -threshold
                    && overlayController.isVisible
                {
                    swipeUpFired = true
                    DispatchQueue.main.async { [weak self] in
                        self?.overlayController.dismiss()
                    }
                }
            }

            // Only fire horizontal workspace switches for horizontal swipes
            if swipeAxis == .horizontal && multiSwipeEnabled {
                let threshold = internalThreshold
                let rawPosition = Int(accDisX / threshold)
                let targetPosition = max(-maxSteps, min(maxSteps, rawPosition))
                let delta = targetPosition - firedPosition

                if delta != 0 {
                    let direction: Direction
                    if delta > 0 {
                        direction = naturalSwipe ? .prev : .next
                    } else {
                        direction = naturalSwipe ? .next : .prev
                    }
                    let stepsToFire = abs(delta)
                    firedPosition = targetPosition

                    // Cancel any pending work so we don't overshoot
                    pendingSwipeWork?.cancel()

                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }

                        // Focus the workspace under the cursor once per gesture
                        if !self.gestureFocusDone {
                            let res = self.runCommand(
                                args: ["list-workspaces", "--monitor", "mouse", "--visible"],
                                stdin: ""
                            )
                            if let mouseWs = try? res.get() {
                                _ = self.runCommand(args: ["workspace", mouseWs], stdin: "")
                            }
                            self.gestureFocusDone = true
                        }

                        let nonEmptyWorkspaces: String?
                        if self.skipEmpty {
                            if let cachedNonEmptyWorkspaces = self.cachedNonEmptyWorkspaces {
                                nonEmptyWorkspaces = cachedNonEmptyWorkspaces
                            } else {
                                let fetchedNonEmptyWorkspaces =
                                    (try? self.getNonEmptyWorkspaces().get())
                                self.cachedNonEmptyWorkspaces = fetchedNonEmptyWorkspaces
                                nonEmptyWorkspaces = fetchedNonEmptyWorkspaces
                            }
                        } else {
                            nonEmptyWorkspaces = nil
                        }

                        // Fire only the lean next/prev calls
                        for _ in 0..<stepsToFire {
                            var args = ["workspace", direction.value]
                            var stdin = ""
                            if self.wrapWorkspace {
                                args.append("--wrap-around")
                            }
                            if self.skipEmpty {
                                if let ws = nonEmptyWorkspaces, !ws.isEmpty {
                                    stdin = ws
                                    args.append("--stdin")
                                }
                            }
                            switch self.runCommand(args: args, stdin: stdin) {
                            case .success: continue
                            case .failure(let err):
                                self.logger.error("\(err.localizedDescription)")
                                return
                            }
                        }
                    }
                    pendingSwipeWork = workItem
                    workQueue.async(execute: workItem)
                }
            }
        }
    }

    private func clearEventState() {
        accDisX = 0
        accDisY = 0
        firedPosition = 0
        swipeUpFired = false
        swipeAxis = .undecided
        activeFingerCount = 0
        gestureFocusDone = false
        cachedNonEmptyWorkspaces = nil
        prevTouchPositions.removeAll()
    }

    private func handleGesture() {
        // If multi-swipe is enabled, switches already fired live during the gesture
        if multiSwipeEnabled {
            return
        }
        let threshold = internalThreshold
        if abs(accDisX) < threshold {
            return
        }
        let direction: Direction =
            if naturalSwipe {
                accDisX < 0 ? .next : .prev
            } else {
                accDisX < 0 ? .prev : .next
            }
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch self.switchWorkspace(direction: direction) {
            case .success: return
            case .failure(let err):
                self.logger.error("\(err.localizedDescription)")
            }
        }
    }

    private func swipeDistance(touches: Set<NSTouch>) -> (Float, Float) {
        var allRight = true
        var allLeft = true
        var allUp = true
        var allDown = true
        var sumDisX = Float(0)
        var sumDisY = Float(0)
        var activeTouches = 0
        for touch in touches {
            let (disX, disY) = touchDistance(touch)
            allRight = allRight && disX >= 0
            allLeft = allLeft && disX <= 0
            allUp = allUp && disY >= 0
            allDown = allDown && disY <= 0
            sumDisX += disX
            sumDisY += disY

            if touch.phase == .ended {
                prevTouchPositions.removeValue(forKey: "\(touch.identity)")
            } else {
                prevTouchPositions["\(touch.identity)"] =
                    touch.normalizedPosition
                activeTouches += 1
            }
        }

        // Average across fingers so threshold behaves consistently
        // regardless of finger count
        let count = max(activeTouches, 1)
        var resultX = sumDisX / Float(count)
        var resultY = sumDisY / Float(count)

        // All fingers should move in the same direction for each axis.
        if !allRight && !allLeft {
            resultX = 0
        }
        if !allUp && !allDown {
            resultY = 0
        }

        return (resultX, resultY)
    }

    private func touchDistance(_ touch: NSTouch) -> (Float, Float) {
        guard let prevPosition = prevTouchPositions["\(touch.identity)"] else {
            return (0, 0)
        }
        let position = touch.normalizedPosition
        return (
            Float(position.x - prevPosition.x),
            Float(position.y - prevPosition.y)
        )
    }
}
