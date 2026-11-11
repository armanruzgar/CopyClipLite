import Combine
import XCTest

extension XCTestCase {
    /// Waits until `condition` holds, re-checking it after every change `object` announces.
    /// The timeout is only a safety net; the wait ends as soon as the change lands.
    @MainActor
    func waitForState<Object: ObservableObject>(
        of object: Object,
        _ description: String,
        timeout: TimeInterval = 10,
        until condition: @escaping @MainActor () -> Bool
    ) async where Object.ObjectWillChangePublisher == ObservableObjectPublisher {
        guard !condition() else { return }
        let satisfied = XCTestExpectation(description: description)
        satisfied.assertForOverFulfill = false
        let observation = object.objectWillChange.sink { _ in
            // objectWillChange fires before the mutation, so check once the current job finishes.
            Task { @MainActor in
                if condition() {
                    satisfied.fulfill()
                }
            }
        }
        await fulfillment(of: [satisfied], timeout: timeout)
        observation.cancel()
    }
}
