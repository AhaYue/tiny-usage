import Foundation
import Security

/// Login-keychain ACL dialogs are not governed by LAContext alone. Suppress legacy
/// keychain UI as well, including reads and writes of our own items after a rebuild.
/// The switch is process-wide, so every keychain operation shares this lock; explicit
/// authorization must not overlap a silent refresh's temporary UI setting.
enum KeychainAccess {
    private static let lock = NSLock()
    // All accesses occur while holding lock.
    nonisolated(unsafe) private static var authorizedServices: Set<String> = []

    static var newUserSessionID: String? {
        let value = ProcessInfo.processInfo.environment["TINY_USAGE_NEW_USER_SESSION"]
        return value?.isEmpty == false ? value : nil
    }

    static func perform(interactive: Bool = false, credentialService: String? = nil,
                        _ operation: () -> OSStatus) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        // A temporary home alone does not isolate data-protection keychain items. In a
        // new-user session, ignore inherited grants until this process obtains explicit
        // authorization for that service. Attribute-only queries carry no credentialService.
        if newUserSessionID != nil, let service = credentialService, !interactive,
           !authorizedServices.contains(service) {
            return errSecInteractionNotAllowed
        }
        if interactive {
            let status = operation()
            if status == errSecSuccess, let service = credentialService { authorizedServices.insert(service) }
            return status
        }

        // Deprecated since 10.10 with no replacement: SecItem's own "no UI" options don't cover
        // the login keychain's ACL dialog, so these two calls stay until Apple offers one.
        var previouslyAllowed: DarwinBoolean = false
        let readStatus = SecKeychainGetUserInteractionAllowed(&previouslyAllowed)
        guard readStatus == errSecSuccess else { return readStatus }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { return disableStatus }
        defer { SecKeychainSetUserInteractionAllowed(previouslyAllowed.boolValue) }
        return operation()
    }
}
