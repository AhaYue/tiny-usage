import Security
import XCTest
@testable import TinyUsageCore

final class KeychainAccessTests: XCTestCase {
    private func interactionAllowed() -> Bool {
        var allowed: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        return allowed.boolValue
    }

    func testSilentOperationDisablesLegacyKeychainDialogsAndRestoresSetting() {
        let before = interactionAllowed()
        var called = false
        let status = KeychainAccess.perform {
            called = true
            XCTAssertFalse(self.interactionAllowed())
            return errSecSuccess
        }
        XCTAssertTrue(called)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(interactionAllowed(), before)
    }

    func testDeniedCacheOperationStaysSilentAndRestoresSetting() {
        let before = interactionAllowed()
        let status = KeychainAccess.perform {
            XCTAssertFalse(self.interactionAllowed())
            return errSecInteractionNotAllowed
        }
        XCTAssertEqual(status, errSecInteractionNotAllowed)
        XCTAssertEqual(interactionAllowed(), before)
    }

    func testExplicitAuthorizationPreservesOriginalInteractionSetting() {
        let before = interactionAllowed()
        let status = KeychainAccess.perform(interactive: true) {
            XCTAssertEqual(self.interactionAllowed(), before)
            return errSecSuccess
        }
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(interactionAllowed(), before)
    }

    private func withNewUserSession(_ body: (String) -> Void) {
        let old = ProcessInfo.processInfo.environment["TINY_USAGE_NEW_USER_SESSION"]
        let session = UUID().uuidString
        setenv("TINY_USAGE_NEW_USER_SESSION", session, 1)
        defer {
            if let old { setenv("TINY_USAGE_NEW_USER_SESSION", old, 1) }
            else { unsetenv("TINY_USAGE_NEW_USER_SESSION") }
        }
        body(session)
    }

    func testNewUserDoesNotReuseAnExistingSilentGrant() {
        withNewUserSession { session in
            var readCalled = false
            let status = KeychainAccess.perform(credentialService: session) {
                readCalled = true
                return errSecSuccess
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
            XCTAssertFalse(readCalled)
        }
    }

    func testNewUserMayReuseOnlyAServiceAuthorizedInThisProcess() {
        withNewUserSession { session in
            XCTAssertEqual(KeychainAccess.perform(interactive: true, credentialService: session) {
                errSecSuccess
            }, errSecSuccess)
            var readCalled = false
            XCTAssertEqual(KeychainAccess.perform(credentialService: session) {
                readCalled = true
                return errSecSuccess
            }, errSecSuccess)
            XCTAssertTrue(readCalled)
            XCTAssertEqual(KeychainAccess.perform(credentialService: session + "-other") {
                XCTFail("Another service has not been authorized")
                return errSecSuccess
            }, errSecInteractionNotAllowed)
        }
    }

    func testRefusalDoesNotEnableSilentReadsInNewUserSession() {
        withNewUserSession { session in
            XCTAssertEqual(KeychainAccess.perform(interactive: true, credentialService: session) {
                errSecUserCanceled
            }, errSecUserCanceled)
            XCTAssertEqual(KeychainAccess.perform(credentialService: session) {
                XCTFail("A refusal must not become a grant")
                return errSecSuccess
            }, errSecInteractionNotAllowed)
        }
    }

    func testNewUserTokenMirrorHasItsOwnNamespace() {
        let normal = LiveUsageDataSource.claudeTokenCacheService
        withNewUserSession { session in
            XCTAssertEqual(LiveUsageDataSource.claudeTokenCacheService, "TinyUsage-claude-oauth-newuser-\(session)")
            XCTAssertNotEqual(LiveUsageDataSource.claudeTokenCacheService, normal)
        }
        XCTAssertEqual(LiveUsageDataSource.claudeTokenCacheService, normal)
    }
}
