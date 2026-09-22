import Foundation

// MARK: - Language preference

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ko, zh

    var id: String { rawValue }

    /// Shown in the language picker, always in its own language.
    var nativeName: String {
        switch self {
        case .system: return L10n.t("lang.system")
        case .en: return "English"
        case .ko: return "한국어"
        case .zh: return "中文"
        }
    }
}

enum Lang: String {
    case en, ko, zh

    var localeIdentifier: String {
        switch self {
        case .en: return "en_US"
        case .ko: return "ko_KR"
        case .zh: return "zh_CN"
        }
    }
}

// MARK: - Tiny in-app localization

enum L10n {
    private(set) static var current: Lang = .en

    static func apply(_ preference: AppLanguage) {
        current = resolve(preference)
        DateHelper.locale = Locale(identifier: current.localeIdentifier)
    }

    static func resolve(_ preference: AppLanguage) -> Lang {
        switch preference {
        case .en: return .en
        case .ko: return .ko
        case .zh: return .zh
        case .system:
            for code in Locale.preferredLanguages {
                let lower = code.lowercased()
                if lower.hasPrefix("ko") { return .ko }
                if lower.hasPrefix("zh") { return .zh }
                if lower.hasPrefix("en") { return .en }
            }
            return .en
        }
    }

    static func t(_ key: String) -> String {
        guard let row = table[key] else { return key }
        return row[current.rawValue] ?? row["en"] ?? key
    }

    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    /// Deadline labels come from the data in English. The frequent ones get a
    /// translation; anything else is shown untouched, which is what researchers
    /// see on the conference site anyway.
    static func deadlineLabel(_ raw: String) -> String {
        if current == .en { return raw }
        return deadlineLabels[raw]?[current.rawValue] ?? raw
    }

    static func categoryLabel(_ key: String) -> String {
        let mapped = "category.\(key)"
        let value = t(mapped)
        return value == mapped ? key.uppercased() : value
    }

    // MARK: UI strings

    private static let table: [String: [String: String]] = [
        "app.name": ["en": "PaperRush Bar", "ko": "PaperRush Bar", "zh": "PaperRush Bar"],
        "app.next": ["en": "Next · %@ %@", "ko": "다음 마감 · %@ %@", "zh": "下一个截止 · %@ %@"],
        "app.noDeadline": ["en": "No upcoming deadlines",
                           "ko": "예정된 마감이 없습니다",
                           "zh": "暂无即将到来的截止日期"],

        "action.refresh": ["en": "Refresh now", "ko": "지금 새로고침", "zh": "立即刷新"],
        "action.quit": ["en": "Quit", "ko": "종료", "zh": "退出"],
        "action.openSource": ["en": "Open data source (paperrush)",
                              "ko": "데이터 출처 열기 (paperrush)",
                              "zh": "打开数据来源 (paperrush)"],
        "action.openExtras": ["en": "Added conferences (%@) - open my extras.json",
                              "ko": "추가된 학회 (%@개) - 내 extras.json 열기",
                              "zh": "已补充的会议 (%@) - 打开我的 extras.json"],

        "settings.launchAtLogin": ["en": "Launch at login",
                                   "ko": "로그인 시 자동 실행",
                                   "zh": "登录时自动启动"],
        "settings.notifications": ["en": "Notifications", "ko": "알림", "zh": "通知"],
        "settings.menubarFavorites": ["en": "Menu bar: favorites only",
                                      "ko": "메뉴바: 즐겨찾기만",
                                      "zh": "菜单栏：仅收藏"],
        "settings.menubarSubmission": ["en": "Menu bar: submission deadlines only",
                                       "ko": "메뉴바: 제출 마감만",
                                       "zh": "菜单栏：仅投稿截止"],
        "settings.language": ["en": "Language", "ko": "언어", "zh": "语言"],
        "settings.urgencyAnimation": ["en": "Sand flows when a deadline is near",
                                      "ko": "마감 임박 시 모래 흐르기",
                                      "zh": "临近截止时流沙"],

        "lang.system": ["en": "System", "ko": "시스템 설정", "zh": "跟随系统"],

        "notify.off": ["en": "Off", "ko": "끄기", "zh": "关闭"],
        "notify.favorites": ["en": "Favorites only", "ko": "즐겨찾기만", "zh": "仅收藏"],
        "notify.all": ["en": "All conferences", "ko": "전체 학회", "zh": "全部会议"],

        "search.placeholder": ["en": "Search conferences", "ko": "학회 검색", "zh": "搜索会议"],
        "filter.favorites": ["en": "Favorites", "ko": "즐겨찾기", "zh": "收藏"],
        "filter.submissionOnly": ["en": "Submissions", "ko": "제출만", "zh": "仅投稿"],

        "category.all": ["en": "All", "ko": "전체", "zh": "全部"],
        "category.cv": ["en": "CV", "ko": "CV", "zh": "CV"],
        "category.ml": ["en": "ML", "ko": "ML", "zh": "ML"],
        "category.nlp": ["en": "NLP", "ko": "NLP", "zh": "NLP"],
        "category.speech": ["en": "Speech", "ko": "음성", "zh": "语音"],
        "category.robotics": ["en": "Robotics", "ko": "로보틱스", "zh": "机器人"],
        "category.other": ["en": "Other", "ko": "기타", "zh": "其他"],

        "list.empty": ["en": "Nothing matches these filters",
                       "ko": "조건에 맞는 마감이 없습니다",
                       "zh": "没有符合条件的截止日期"],

        "badge.estimated": ["en": "Est.", "ko": "예상", "zh": "预估"],
        "badge.extra": ["en": "Added", "ko": "추가", "zh": "补充"],
        "dday.today": ["en": "D-DAY", "ko": "D-DAY", "zh": "D-DAY"],

        "footer.never": ["en": "Not synced yet", "ko": "아직 동기화하지 않았습니다", "zh": "尚未同步"],
        "footer.data": ["en": "Data %@", "ko": "데이터 %@", "zh": "数据 %@"],
        "footer.synced": ["en": "Synced %@", "ko": "동기화 %@", "zh": "已同步 %@"],

        "error.parse": ["en": "Could not read the data format",
                        "ko": "데이터 형식을 해석할 수 없습니다",
                        "zh": "无法解析数据格式"],
        "error.decode": ["en": "Could not decode the data",
                         "ko": "데이터를 디코딩하지 못했습니다",
                         "zh": "数据解码失败"],
        "error.loginItem": ["en": "Could not change the login item: %@",
                            "ko": "로그인 항목 설정 실패: %@",
                            "zh": "无法设置登录项：%@"]
    ]

    // MARK: Frequent deadline labels

    private static let deadlineLabels: [String: [String: String]] = [
        "Paper Submission": ["ko": "논문 제출", "zh": "论文提交"],
        "Paper Submission Deadline": ["ko": "논문 제출 마감", "zh": "论文提交截止"],
        "Full Paper Submission": ["ko": "본논문 제출", "zh": "全文提交"],
        "Full Paper Submission Deadline": ["ko": "본논문 제출 마감", "zh": "全文提交截止"],
        "Final Paper Submission": ["ko": "최종 논문 제출", "zh": "最终论文提交"],
        "Abstract Submission": ["ko": "초록 제출", "zh": "摘要提交"],
        "Abstract Submission Deadline": ["ko": "초록 제출 마감", "zh": "摘要提交截止"],
        "One-Page Abstract Submission": ["ko": "1페이지 초록 제출", "zh": "一页摘要提交"],
        "Paper Registration Deadline": ["ko": "논문 등록 마감", "zh": "论文注册截止"],
        "Paper Enrollment": ["ko": "논문 등록", "zh": "论文登记"],
        "Supplementary Material": ["ko": "보충 자료", "zh": "补充材料"],
        "Supplementary Material Submission": ["ko": "보충 자료 제출", "zh": "补充材料提交"],
        "Supplementary Materials Deadline": ["ko": "보충 자료 마감", "zh": "补充材料截止"],
        "Supplementary Submission": ["ko": "보충 자료 제출", "zh": "补充材料提交"],
        "Author Notification": ["ko": "저자 통보", "zh": "作者通知"],
        "Acceptance Notification": ["ko": "채택 통보", "zh": "录用通知"],
        "Paper Acceptance Notification": ["ko": "논문 채택 통보", "zh": "论文录用通知"],
        "Notification": ["ko": "통보", "zh": "通知"],
        "Notification of Decision": ["ko": "심사 결과 통보", "zh": "决定通知"],
        "Final Notification": ["ko": "최종 통보", "zh": "最终通知"],
        "Preliminary Notification": ["ko": "1차 통보", "zh": "初步通知"],
        "Author Rebuttal Period": ["ko": "저자 반론 기간", "zh": "作者申辩期"],
        "Author Rebuttal Period Start": ["ko": "저자 반론 기간 시작", "zh": "作者申辩期开始"],
        "Author Rebuttal Period End": ["ko": "저자 반론 기간 종료", "zh": "作者申辩期结束"],
        "Author Rebuttal Period Starts": ["ko": "저자 반론 기간 시작", "zh": "作者申辩期开始"],
        "Author Rebuttal Period Ends": ["ko": "저자 반론 기간 종료", "zh": "作者申辩期结束"],
        "Rebuttal and Revision Submission": ["ko": "반론·수정본 제출", "zh": "申辩与修改提交"],
        "Reviews Released": ["ko": "리뷰 공개", "zh": "评审意见公布"],
        "Initial Reviews Released": ["ko": "1차 리뷰 공개", "zh": "初审意见公布"],
        "Camera-Ready Deadline": ["ko": "카메라레디 마감", "zh": "终稿截止"],
        "Camera Ready Deadline": ["ko": "카메라레디 마감", "zh": "终稿截止"],
        "Camera-Ready Submission": ["ko": "카메라레디 제출", "zh": "终稿提交"],
        "Camera-Ready Paper Deadline": ["ko": "카메라레디 논문 마감", "zh": "终稿论文截止"],
        "Main Conference": ["ko": "본 학회", "zh": "主会议"],
        "Workshop Submission Deadline": ["ko": "워크숍 제출 마감", "zh": "研讨会投稿截止"],
        "Workshop Proposal Deadline": ["ko": "워크숍 제안 마감", "zh": "研讨会提案截止"],
        "Workshop Notification": ["ko": "워크숍 통보", "zh": "研讨会通知"],
        "Workshop Acceptance Notification": ["ko": "워크숍 채택 통보", "zh": "研讨会录用通知"],
        "Tutorial Submission": ["ko": "튜토리얼 제출", "zh": "教程提交"],
        "Tutorial Notification": ["ko": "튜토리얼 통보", "zh": "教程通知"],
        "Early Registration Deadline": ["ko": "사전 등록 마감", "zh": "早鸟注册截止"],
        "Conference Registration Deadline": ["ko": "학회 등록 마감", "zh": "会议注册截止"],
        "Registration Open": ["ko": "등록 시작", "zh": "注册开放"],
        "Submission Site Opens": ["ko": "제출 사이트 오픈", "zh": "投稿系统开放"],
        "Paper Submission Site Opens": ["ko": "논문 제출 사이트 오픈", "zh": "论文投稿系统开放"],
        "Paper Submission Opens": ["ko": "논문 제출 시작", "zh": "论文投稿开放"],
        "ARR Paper Submission": ["ko": "ARR 논문 제출", "zh": "ARR 论文提交"],
        "Video Supplement Submission": ["ko": "비디오 보충자료 제출", "zh": "视频补充材料提交"]
    ]
}
