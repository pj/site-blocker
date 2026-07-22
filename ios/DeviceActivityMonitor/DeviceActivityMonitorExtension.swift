import DeviceActivity
import Foundation

/// Runs in the background when a rule's allow window opens/closes or an app budget is spent. Each
/// callback just re-derives the whole enforcement state from the shared rules + clock, so the
/// app-shields and content-blocker stay correct without the app being open.
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        MobileEnforcer.reevaluate()   // window opened → maybe allow
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        MobileEnforcer.reevaluate()   // window closed → re-block
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        // The rule's app budget is spent for today → mark it and re-block that rule's apps.
        if let ruleID = UUID(uuidString: activity.rawValue) {
            MobileEnforcer.markAppBudgetSpent(ruleID)
        }
        MobileEnforcer.reevaluate()
    }
}
