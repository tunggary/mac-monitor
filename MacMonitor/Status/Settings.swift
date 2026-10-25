import Foundation

/// 위험 기준 설정 (UserDefaults). 설정 창 UI 는 다음 단계 — 판정이 읽을 값만 먼저 둔다.
struct Settings: Sendable, Equatable {
    /// 스왑 GB 기준은 1024³(GiB) — 활성 상태 보기와 같은 단위.
    static let bytesPerGB = 1_073_741_824.0

    var swapCautionGB = 4.0
    var swapDangerGB = 8.0
    /// 사용 가능 메모리가 이 값(%)보다 적으면 위험
    var availableDangerPercent = 20.0
    /// 앱(그룹) 하나의 CPU 주의 기준 (코어 1개 = 100%)
    var appCPUCautionPercent = 300.0
    var spikeSeconds = 30.0
    /// 위험 지속 시 재알림 간격(분). 0 = 다시 안 함.
    var repeatIntervalMinutes = 10
    /// AI 판정 스위치 (기본 끔)
    var aiVerdictEnabled = false
    var aiVerdictEngineID = "jev"

    var swapCautionBytes: Double { swapCautionGB * Self.bytesPerGB }
    var swapDangerBytes: Double { swapDangerGB * Self.bytesPerGB }

    private enum Key {
        static let swapCaution = "settings.swapCautionGB"
        static let swapDanger = "settings.swapDangerGB"
        static let availableDanger = "settings.availableDangerPercent"
        static let appCPUCaution = "settings.appCPUCautionPercent"
        static let spikeSeconds = "settings.spikeSeconds"
        static let repeatInterval = "settings.repeatIntervalMinutes"
        static let aiVerdictEnabled = "settings.aiVerdictEnabled"
        static let aiVerdictEngineID = "settings.aiVerdictEngineID"
    }

    static func load(from defaults: UserDefaults = .standard) -> Settings {
        var settings = Settings()
        func double(_ key: String) -> Double? { defaults.object(forKey: key) as? Double }
        settings.swapCautionGB = double(Key.swapCaution) ?? settings.swapCautionGB
        settings.swapDangerGB = double(Key.swapDanger) ?? settings.swapDangerGB
        settings.availableDangerPercent = double(Key.availableDanger) ?? settings.availableDangerPercent
        settings.appCPUCautionPercent = double(Key.appCPUCaution) ?? settings.appCPUCautionPercent
        settings.spikeSeconds = double(Key.spikeSeconds) ?? settings.spikeSeconds
        settings.repeatIntervalMinutes = (defaults.object(forKey: Key.repeatInterval) as? Int) ?? settings.repeatIntervalMinutes
        settings.aiVerdictEnabled = (defaults.object(forKey: Key.aiVerdictEnabled) as? Bool) ?? settings.aiVerdictEnabled
        settings.aiVerdictEngineID = defaults.string(forKey: Key.aiVerdictEngineID) ?? settings.aiVerdictEngineID
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(swapCautionGB, forKey: Key.swapCaution)
        defaults.set(swapDangerGB, forKey: Key.swapDanger)
        defaults.set(availableDangerPercent, forKey: Key.availableDanger)
        defaults.set(appCPUCautionPercent, forKey: Key.appCPUCaution)
        defaults.set(spikeSeconds, forKey: Key.spikeSeconds)
        defaults.set(repeatIntervalMinutes, forKey: Key.repeatInterval)
        defaults.set(aiVerdictEnabled, forKey: Key.aiVerdictEnabled)
        defaults.set(aiVerdictEngineID, forKey: Key.aiVerdictEngineID)
    }
}
