import XCTest

extension XCTestCase {
    func isolatedDefaults() -> UserDefaults {
        let domain = "studio.refract.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        return defaults
    }
}
