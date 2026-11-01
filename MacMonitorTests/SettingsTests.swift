import Foundation
import Testing
@testable import MacMonitor

struct SettingsTests {
    private func defaults() -> UserDefaults {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func explainDefaultsOffAndClaude() {
        let s = Settings.load(from: defaults())
        #expect(!s.aiExplainEnabled)
        #expect(s.aiExplainProviderID == "claude")
        #expect(!s.aiExplainActive)
    }

    @Test func explainActiveRequiresVerdictEnabledButKeepsStoredValue() {
        var s = Settings()
        s.aiExplainEnabled = true
        #expect(!s.aiExplainActive)
        s.aiVerdictEnabled = true
        #expect(s.aiExplainActive)
        s.aiVerdictEnabled = false
        #expect(!s.aiExplainActive)
        #expect(s.aiExplainEnabled)
    }

    @Test func explainRoundTrip() {
        let d = defaults()
        var s = Settings()
        s.aiExplainEnabled = true
        s.aiExplainProviderID = "openai"
        s.save(to: d)
        let loaded = Settings.load(from: d)
        #expect(loaded.aiExplainEnabled)
        #expect(loaded.aiExplainProviderID == "openai")
    }
}
