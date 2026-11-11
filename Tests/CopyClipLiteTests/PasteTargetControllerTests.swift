import AppKit
import Foundation
import XCTest
@testable import CopyClipLite

@MainActor
private final class FakePasteTargetApplication: PasteTargetApplication {
    var pasteBundleIdentifier: String? = "com.example.Target"
    var pasteLocalizedName: String? = "Target"
    var pasteProcessIdentifier: pid_t = 42
    var pasteIsTerminated = false
    var pasteIsActive = false
    var activationResult = true
    var becomesActiveOnActivation = true

    func activateForPaste() -> Bool {
        if activationResult, becomesActiveOnActivation {
            pasteIsActive = true
        }
        return activationResult
    }
}

@MainActor
private final class PasteRuntimeState {
    var permissionGranted = true
    var hideCount = 0
    var restoreCount = 0
    var simulateCount = 0
    var simulatedProcessIdentifiers: [pid_t] = []
    var simulateResult = true
    var openSettingsCount = 0
}

@MainActor
private final class PasteTestClock {
    var now: UInt64 = 0
    var sleepDurations: [UInt64] = []
    var onSleep: ((UInt64) -> Void)?
    var suspendsSleeps = false
    let sleepSuspended = XCTestExpectation(description: "paste attempt suspended in sleep")
    private var suspendedSleeps: [CheckedContinuation<Void, Never>] = []

    var suspendedSleepCount: Int {
        suspendedSleeps.count
    }

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        sleepDurations.append(nanoseconds)
        let (next, overflow) = now.addingReportingOverflow(nanoseconds)
        now = overflow ? .max : next
        onSleep?(nanoseconds)
        if suspendsSleeps {
            await withCheckedContinuation { continuation in
                suspendedSleeps.append(continuation)
                sleepSuspended.fulfill()
            }
        } else {
            await Task.yield()
        }
        try Task.checkCancellation()
    }

    func resumeSuspendedSleeps() {
        let continuations = suspendedSleeps
        suspendedSleeps.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class PasteObservationState {
    private(set) var installCount = 0
    private(set) var cancelCount = 0
    private var handler: (@MainActor @Sendable (any PasteTargetApplication) -> Void)?

    func observe(
        _ handler: @escaping @MainActor @Sendable (any PasteTargetApplication) -> Void
    ) -> PasteTargetActivationObservation {
        installCount += 1
        self.handler = handler
        return PasteTargetActivationObservation { [weak self] in
            self?.cancelCount += 1
            self?.handler = nil
        }
    }

    func deliver(_ application: any PasteTargetApplication) {
        handler?(application)
    }
}

@MainActor
final class PasteTargetControllerTests: XCTestCase {
    nonisolated(unsafe) private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testActivationFailureRestoresApplicationAndShowsError() throws {
        let target = FakePasteTargetApplication()
        target.activationResult = false
        let state = PasteRuntimeState()
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()

        controller.paste(item, using: store)

        XCTAssertEqual(state.hideCount, 1)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertNotNil(controller.lastError)
        XCTAssertTrue(controller.lastError?.contains("still on your clipboard") == true)
        XCTAssertEqual(
            controller.attemptState,
            .failed(
                message: controller.lastError ?? "",
                clipWasCopied: true
            )
        )
    }

    func testSuccessfulPasteAttemptUsesVisibleTargetAndStaysHidden() async throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()

        XCTAssertEqual(controller.targetApplicationName, "Target")
        await pasteAndWaitForAttempt(item, using: store, on: controller)

        XCTAssertEqual(state.hideCount, 1)
        XCTAssertEqual(state.restoreCount, 0)
        XCTAssertEqual(state.simulateCount, 1)
        XCTAssertEqual(state.simulatedProcessIdentifiers, [target.pasteProcessIdentifier])
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.attemptState, .postAttempted(target: "Target"))
    }

    func testPermissionFailureDoesNotHideOrCopy() throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        state.permissionGranted = false
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()
        let initialCopyCount = item.copyCount

        controller.paste(item, using: store)

        XCTAssertEqual(state.hideCount, 0)
        XCTAssertEqual(state.restoreCount, 0)
        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertEqual(store.items.first?.copyCount, initialCopyCount)
        XCTAssertNotNil(controller.lastError)
        XCTAssertTrue(controller.lastError?.contains("Nothing was copied") == true)
    }

    func testGrantedPermissionClearsDecoratedPermissionFailureAndResetsAttempt() throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        state.permissionGranted = false
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()

        controller.paste(item, using: store)
        XCTAssertTrue(controller.lastError?.contains("Nothing was copied") == true)
        guard case .failed = controller.attemptState else {
            return XCTFail("Expected permission failure")
        }

        state.permissionGranted = true
        controller.refreshPermission()

        XCTAssertTrue(controller.isAccessibilityGranted)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.attemptState, .idle)
    }

    func testGrantedPermissionClearsFailureFromRevocationDuringAttempt() async throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        let clock = PasteTestClock()
        clock.onSleep = { _ in
            state.permissionGranted = false
        }
        let controller = makeController(target: target, state: state, clock: clock)
        let (store, item) = try makeStoreAndItem()

        await pasteAndWaitForAttempt(item, using: store, on: controller)

        XCTAssertFalse(controller.isAccessibilityGranted)
        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertTrue(controller.lastError?.contains("still on your clipboard") == true)

        state.permissionGranted = true
        controller.refreshPermission()

        XCTAssertTrue(controller.isAccessibilityGranted)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.attemptState, .idle)
    }

    func testActivationTimeoutRestoresUIAndReportsClipboardOutcome() async throws {
        let target = FakePasteTargetApplication()
        target.becomesActiveOnActivation = false
        let state = PasteRuntimeState()
        let clock = PasteTestClock()
        let controller = makeController(
            target: target,
            state: state,
            clock: clock,
            activationPollCount: 3,
            activationPollNanoseconds: 10,
            activationTimeoutNanoseconds: 25
        )
        let (store, item) = try makeStoreAndItem()

        await pasteAndWaitForAttempt(item, using: store, on: controller)

        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertEqual(clock.now, 25)
        XCTAssertEqual(clock.sleepDurations, [10, 10, 5])
        XCTAssertTrue(controller.lastError?.contains("still on your clipboard") == true)
    }

    func testTargetCanBecomeActiveNearInjectedDeadline() async throws {
        let target = FakePasteTargetApplication()
        target.becomesActiveOnActivation = false
        let state = PasteRuntimeState()
        let clock = PasteTestClock()
        clock.onSleep = { _ in
            if clock.now == 20 {
                target.pasteIsActive = true
            }
        }
        let controller = makeController(
            target: target,
            state: state,
            clock: clock,
            activationPollCount: 3,
            activationPollNanoseconds: 10,
            activationTimeoutNanoseconds: 30,
            stabilizationNanoseconds: 7
        )
        let (store, item) = try makeStoreAndItem()

        await pasteAndWaitForAttempt(item, using: store, on: controller)

        XCTAssertEqual(clock.sleepDurations, [10, 10, 7])
        XCTAssertEqual(state.simulateCount, 1)
        XCTAssertEqual(state.restoreCount, 0)
        XCTAssertEqual(controller.attemptState, .postAttempted(target: "Target"))
    }

    func testNewFailedRequestCancelsOlderPendingPasteWithoutOverwritingItsError() async throws {
        let target = FakePasteTargetApplication()
        target.becomesActiveOnActivation = false
        let state = PasteRuntimeState()
        let clock = PasteTestClock()
        clock.suspendsSleeps = true
        let controller = makeController(
            target: target,
            state: state,
            clock: clock,
            activationPollCount: 20
        )
        let (store, item) = try makeStoreAndItem()

        controller.paste(item, using: store)
        let olderAttempt = try XCTUnwrap(controller.pendingPasteTask)
        await fulfillment(of: [clock.sleepSuspended], timeout: 10)
        XCTAssertEqual(clock.suspendedSleepCount, 1)
        state.permissionGranted = false
        controller.paste(item, using: store)
        clock.resumeSuspendedSleeps()
        await olderAttempt.value

        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertTrue(controller.lastError?.contains("Nothing was copied") == true)
    }

    func testPasteEventFailureRestoresUIAndReportsCopiedClip() async throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        state.simulateResult = false
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()

        await pasteAndWaitForAttempt(item, using: store, on: controller)

        XCTAssertEqual(state.simulateCount, 1)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertTrue(controller.lastError?.contains("still on your clipboard") == true)
    }

    func testAccessibilitySettingsActivationDoesNotReplaceRememberedTarget() {
        let target = FakePasteTargetApplication()
        let settings = FakePasteTargetApplication()
        settings.pasteLocalizedName = "System Settings"
        settings.pasteBundleIdentifier = "com.apple.systempreferences"
        settings.pasteProcessIdentifier = 99
        let state = PasteRuntimeState()
        let controller = makeController(target: target, state: state)

        controller.openAccessibilitySettings()
        controller.handleActivation(settings)

        XCTAssertEqual(state.openSettingsCount, 1)
        XCTAssertEqual(controller.targetApplicationName, "Target")
    }

    func testInjectedActivationObservationDeliversApplicationsAndCancelsOnDeinit() {
        let initialTarget = FakePasteTargetApplication()
        let nextTarget = FakePasteTargetApplication()
        nextTarget.pasteLocalizedName = "Next Target"
        nextTarget.pasteProcessIdentifier = 77
        let settings = FakePasteTargetApplication()
        settings.pasteLocalizedName = "System Settings"
        settings.pasteBundleIdentifier = "com.apple.systempreferences"
        settings.pasteProcessIdentifier = 99
        let ownApplication = FakePasteTargetApplication()
        ownApplication.pasteBundleIdentifier = Bundle.main.bundleIdentifier
        ownApplication.pasteProcessIdentifier = 100
        let state = PasteRuntimeState()
        let observation = PasteObservationState()
        var runtime = makeRuntime(state: state, clock: PasteTestClock())
        runtime.frontmostApplication = { initialTarget }
        runtime.observeApplicationActivations = { handler in
            observation.observe(handler)
        }

        weak var weakController: PasteTargetController?
        var controller: PasteTargetController? = PasteTargetController(
            runtime: runtime,
            observeWorkspace: true
        )
        weakController = controller

        XCTAssertEqual(observation.installCount, 1)
        XCTAssertEqual(controller?.targetApplicationName, "Target")
        observation.deliver(nextTarget)
        XCTAssertEqual(controller?.targetApplicationName, "Next Target")

        controller?.openAccessibilitySettings()
        observation.deliver(settings)
        XCTAssertEqual(controller?.targetApplicationName, "Next Target")

        observation.deliver(ownApplication)
        observation.deliver(initialTarget)
        XCTAssertEqual(controller?.targetApplicationName, "Target")

        controller = nil
        XCTAssertNil(weakController)
        XCTAssertEqual(observation.cancelCount, 1)
    }

    private func makeController(
        target: FakePasteTargetApplication,
        state: PasteRuntimeState,
        clock: PasteTestClock? = nil,
        activationPollCount: Int = 1,
        activationPollNanoseconds: UInt64 = 1_000_000,
        activationTimeoutNanoseconds: UInt64? = nil,
        stabilizationNanoseconds: UInt64 = 0
    ) -> PasteTargetController {
        let clock = clock ?? PasteTestClock()
        return PasteTargetController(
            initialTarget: target,
            runtime: makeRuntime(state: state, clock: clock),
            observeWorkspace: false,
            activationPollCount: activationPollCount,
            activationPollNanoseconds: activationPollNanoseconds,
            activationTimeoutNanoseconds: activationTimeoutNanoseconds,
            stabilizationNanoseconds: stabilizationNanoseconds
        )
    }

    private func makeRuntime(
        state: PasteRuntimeState,
        clock: PasteTestClock
    ) -> PasteTargetRuntime {
        PasteTargetRuntime(
            isAccessibilityGranted: { state.permissionGranted },
            requestAccessibilityPermission: {},
            simulatePaste: { processIdentifier in
                state.simulateCount += 1
                state.simulatedProcessIdentifiers.append(processIdentifier)
                return state.simulateResult
            },
            openAccessibilitySettings: { state.openSettingsCount += 1 },
            hideApplication: { state.hideCount += 1 },
            restoreApplication: { state.restoreCount += 1 },
            monotonicNanoseconds: { clock.now },
            sleepNanoseconds: { try await clock.sleep(nanoseconds: $0) }
        )
    }

    private func pasteAndWaitForAttempt(
        _ item: ClipboardItem,
        using store: ClipboardStore,
        on controller: PasteTargetController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        controller.paste(item, using: store)
        await controller.pendingPasteTask?.value
        switch controller.attemptState {
        case .activating, .waitingForTarget, .posting:
            XCTFail(
                "Paste attempt did not settle: \(controller.attemptState)",
                file: file,
                line: line
            )
        case .idle, .preflighting, .postAttempted, .failed:
            break
        }
    }

    func testClipboardReplacementDuringActivationOrStabilizationAbortsPaste() async throws {
        for waitsForActivation in [true, false] {
            let target = FakePasteTargetApplication()
            target.becomesActiveOnActivation = !waitsForActivation
            let state = PasteRuntimeState()
            let clock = PasteTestClock()
            let board = StubStorePasteboard()
            let (store, item) = try makeStoreAndItem(pasteboard: board)
            clock.onSleep = { _ in
                board.clearContents()
                board.setString("newer unrelated copy", forType: .string)
            }
            let controller = makeController(target: target, state: state, clock: clock)

            await pasteAndWaitForAttempt(item, using: store, on: controller)

            XCTAssertEqual(state.simulateCount, 0)
            XCTAssertEqual(state.restoreCount, 1)
            XCTAssertEqual(board.string(forType: .string), "newer unrelated copy")
            XCTAssertTrue(controller.lastError?.contains("Nothing was pasted") == true)
            XCTAssertFalse(controller.lastError?.contains("still on your clipboard") == true)
        }
    }

    func testClipboardReplacementFromPostingObserverIsCheckedBeforeEvent() async throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        let controller = makeController(target: target, state: state)
        let board = StubStorePasteboard()
        let (store, item) = try makeStoreAndItem(pasteboard: board)
        let observation = controller.$attemptState.sink { attemptState in
            if case .posting = attemptState {
                board.clearContents()
                board.setString("observer replacement", forType: .string)
            }
        }
        defer { observation.cancel() }

        await pasteAndWaitForAttempt(item, using: store, on: controller)

        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertEqual(board.string(forType: .string), "observer replacement")
    }

    private func makeStoreAndItem(
        pasteboard: StubStorePasteboard = StubStorePasteboard()
    ) throws -> (ClipboardStore, ClipboardItem) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteTargetControllerTests-\(UUID().uuidString)")
        tempDirectories.append(directory)
        let storage = ClipboardStorage(appDirectory: directory)
        storage.save([ClipboardItem(text: "paste me")])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        return (store, try XCTUnwrap(store.items.first))
    }
}
