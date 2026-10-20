import Foundation

enum MemoryLevel: Sendable, Equatable {
    case normal, caution, danger
}

/// 메모리 위험의 원인 지표 (배너 제목에 쓴다)
enum DangerCause: Sendable, Equatable {
    case swap
    case availableMemory
}

enum RowDot: Sendable, Equatable {
    case ok, warn, danger
}

/// 상태 판정 순수 함수 모음.
enum Judgement {
    /// 위험: 스왑 > 위험 기준 또는 사용 가능 < 기준 / 주의: 스왑 > 주의 기준
    static func memoryLevel(swapBytes: UInt64, availablePercent: Double, settings: Settings) -> MemoryLevel {
        if dangerCause(swapBytes: swapBytes, availablePercent: availablePercent, settings: settings) != nil { return .danger }
        if Double(swapBytes) > settings.swapCautionBytes { return .caution }
        return .normal
    }

    /// 위험이 아니면 nil. 둘 다 넘으면 스왑을 원인으로 본다.
    static func dangerCause(swapBytes: UInt64, availablePercent: Double, settings: Settings) -> DangerCause? {
        if Double(swapBytes) > settings.swapDangerBytes { return .swap }
        if availablePercent < settings.availableDangerPercent { return .availableMemory }
        return nil
    }

    /// 어떤 앱(그룹)이든 CPU ≥ 기준이면 CPU 주의
    static func isCPUCaution(groups: [AppGroup], settings: Settings) -> Bool {
        groups.contains { $0.cpuPercent >= settings.appCPUCautionPercent }
    }

    /// 행 상태 점. 원인 순위 = 메모리 footprint 큰 순 (표시 정렬과 무관).
    /// 위험: 1위 코랄, 2·3위 노랑 / 주의: 1~3위 노랑 / CPU ≥ 기준 앱은 메모리 상태와 무관하게 노랑(코랄이 우선) / 나머지 초록
    static func rowDots(groups: [AppGroup], level: MemoryLevel, settings: Settings) -> [String: RowDot] {
        let ranked = groups.enumerated()
            .sorted { ($0.element.footprint, $1.offset) > ($1.element.footprint, $0.offset) }
            .map(\.element)
        var dots: [String: RowDot] = [:]
        for (index, group) in ranked.enumerated() {
            let rank = index + 1
            if level == .danger, rank == 1 {
                dots[group.id] = .danger
            } else if (level == .danger && rank <= 3) || (level == .caution && rank <= 3)
                        || group.cpuPercent >= settings.appCPUCautionPercent {
                dots[group.id] = .warn
            } else {
                dots[group.id] = .ok
            }
        }
        return dots
    }

    /// 배너·알림 제목의 원인 문구: "스왑 12.7 GB" / "사용 가능 18%"
    static func causeTitle(cause: DangerCause, swapBytes: UInt64, availablePercent: Double) -> String {
        switch cause {
        case .swap: "스왑 \(Format.gb(swapBytes))"
        case .availableMemory: "사용 가능 \(Format.wholePercent(availablePercent))"
        }
    }

    /// 배너 본문. 스왑: "경고 기준 8 GB를 4분째 넘고 있어요." / 사용 가능: "경고 기준 20%보다 4분째 적어요." + 가장 큰 원인.
    static func bannerBody(cause: DangerCause, settings: Settings, minutes: Int, top: (name: String, footprint: UInt64)?) -> String {
        var text: String
        switch cause {
        case .swap: text = "경고 기준 \(Format.thresholdGB(settings.swapDangerGB))를 \(minutes)분째 넘고 있어요."
        case .availableMemory: text = "경고 기준 \(Format.wholePercent(settings.availableDangerPercent))보다 \(minutes)분째 적어요."
        }
        if let top { text += " 가장 큰 원인은 \(top.name)(\(Format.memory(top.footprint)))예요." }
        return text
    }

    /// 배너 "N분째". 막 시작해도 최소 1분으로 표기한다.
    static func dangerMinutes(since: Date, now: Date) -> Int {
        max(1, Int(now.timeIntervalSince(since)) / 60)
    }

    /// 스왑 그래프 y 최대(GB). 위험 기준 × 2 면 위험선이 절반, 주의선(4GB)이 1/4 지점.
    /// 값이 그보다 커지면 위로 잘리지 않게 관측 최대 × 1.1 까지 늘린다.
    static func swapYMaxGB(dangerGB: Double, observedMaxGB: Double) -> Double {
        max(dangerGB * 2, observedMaxGB * 1.1)
    }
}

/// 한국어 조사
enum Korean {
    /// 목적격 조사. 마지막 글자가 받침 있는 한글이면 "을", 그 외(받침 없는 한글·영문·숫자·기호)는 "를".
    static func objectParticle(for name: String) -> String {
        guard let last = name.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return "를" }
        return (last.value - 0xAC00) % 28 == 0 ? "를" : "을"
    }
}

/// 숫자 표시 (1024 기준 값에 "GB" 라벨 — 활성 상태 보기와 같다)
enum Format {
    static func gb(_ bytes: UInt64) -> String { gb(Double(bytes)) }
    static func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / Settings.bytesPerGB) }

    /// 1 GB 이상은 "20.7 GB", 미만은 "980 MB"
    static func memory(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= Settings.bytesPerGB { return gb(value) }
        return String(format: "%.0f MB", value / 1_048_576)
    }

    /// 입력칸 표시: 4 → "4", 4.5 → "4.5"
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(value)
    }

    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    static func wholePercent(_ value: Double) -> String { String(format: "%.0f%%", value) }
    /// 기준값 표기: 4 → "4 GB", 4.5 → "4.5 GB"
    static func thresholdGB(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }
}
