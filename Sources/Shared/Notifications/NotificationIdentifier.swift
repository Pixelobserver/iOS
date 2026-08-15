import Foundation

public enum NotificationIdentifier: String {
    case automationAppIntentRun
    case scriptAppIntentRun
    case sceneAppIntentRun
    case intentToggleFailed
    case intentActivateFailed
    case intentPressFailed
    case serverUnreachable

    // Beacon diagnostics
    case beaconDetectedLocally
    case beaconExitedLocally
    case beaconEventDelivered
    case beaconEventQueued

    // Debug
    case debug
}
