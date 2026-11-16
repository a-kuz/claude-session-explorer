import Foundation
import Security
import ServiceManagement

/// launchd runs an SMAppService agent only while the bundle's code signature
/// matches the one recorded at registration. The app is signed ad hoc, so every
/// build has a new signature and the old registration fails with "Launch
/// Constraint Violation". After an update the enabled agents are registered
/// again with the current signature.
enum AgentSignature {
    private static let key = "agents.registeredCDHash"

    /// `services`: the agents that should be registered.
    static func reregisterIfRebuilt(_ services: [SMAppService]) {
        guard let current = cdhash() else { return }
        let d = UserDefaults.standard
        guard d.string(forKey: key) != current else { return }
        // An immediate register after unregister races the removal and the
        // item stays invalid; a pause between the two lets it settle.
        DispatchQueue.global(qos: .utility).async {
            for s in services { try? s.unregister() }
            Thread.sleep(forTimeInterval: 2)
            var ok = true
            for s in services {
                do { try s.register() } catch {
                    ok = false
                    NSLog("AgentSignature: register failed: \(error)")
                }
            }
            if ok { d.set(current, forKey: key) }
        }
    }

    private static func cdhash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
