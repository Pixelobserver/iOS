import Foundation
import PromiseKit
import Shared
import UIKit

class ApplicationBackgroundTaskRunner: HomeAssistantBackgroundTaskRunner {
    private let beginTask: (String, @escaping () -> Void) -> UIBackgroundTaskIdentifier
    private let endTask: (UIBackgroundTaskIdentifier) -> Void
    private let remainingTime: () -> TimeInterval

    init(
        beginTask: @escaping (String, @escaping () -> Void) -> UIBackgroundTaskIdentifier = { name, expirationHandler in
            UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
        },
        endTask: @escaping (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) },
        remainingTime: @escaping () -> TimeInterval = { UIApplication.shared.backgroundTimeRemaining }
    ) {
        self.beginTask = beginTask
        self.endTask = endTask
        self.remainingTime = remainingTime
    }

    public func callAsFunction<PromiseValue>(
        withName name: String,
        requiringAssertion: Bool,
        wrapping: (TimeInterval?) -> Promise<PromiseValue>
    ) -> Promise<PromiseValue> {
        HomeAssistantBackgroundTask.execute(
            withName: name,
            beginBackgroundTask: { name, expirationHandler in
                let identifier = self.beginTask(name, expirationHandler)
                let rawRemaining = Thread.isMainThread ? self.remainingTime() : nil
                let remaining = rawRemaining.flatMap { $0 < 100 ? $0 : nil }
                return (identifier == .invalid ? nil : identifier, remaining)
            }, endBackgroundTask: endTask,
            requiresAssertion: requiringAssertion,
            wrapping: wrapping
        )
    }
}
