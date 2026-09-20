<div align="center">

# PaperRush Bar ⏳

**AI 학회 마감을 맥 메뉴바에서 바로.**

`⏳ ICLR D-5` — 브라우저를 열지 않아도 항상 최신 상태로 보입니다.

[English](README.md) · 한국어 · [中文](README.zh.md)

![platform](https://img.shields.io/badge/macOS-13%2B-black)
![language](https://img.shields.io/badge/Swift-5-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## 무엇을 하나요

Electron도 Python도 없는 약 1MB짜리 네이티브 메뉴바 앱입니다. 가장 가까운 AI/ML 학회 제출 마감까지
남은 날짜를 상단 바에 상시 표시하고, 백그라운드에서 스스로 최신 데이터를 받아옵니다.

마감 데이터는 [**awsaf49/paperrush**](https://github.com/awsaf49/paperrush)에서 가져옵니다.
그 레포가 GitHub Actions로 데이터셋을 갱신하므로, 이 앱은 별도 관리 없이 자동으로 따라갑니다.

| | |
|---|---|
| **메뉴바 D-day** | 가장 가까운 제출 마감을 `ICLR D-5` 형태로 표시, 자정이 지나면 자동으로 갱신 |
| **매일 자동 업데이트** | 30분마다 확인해 데이터가 6시간 지났으면 재다운로드, 절전에서 깨어날 때도 갱신 |
| **오프라인 대응** | 마지막 데이터는 Application Support에 캐시, 첫 실행용 스냅샷을 앱에 내장 |
| **D-7 / D-3 / D-1 알림** | 해당 날짜 오전 9시 네이티브 알림 — 끄기 / 즐겨찾기만 / 전체 |
| **즐겨찾기** | ★ 표시한 학회는 목록 상단에 고정, 메뉴바·알림도 즐겨찾기만으로 제한 가능 |
| **클릭 = 사이트 열기** | 행을 누르면 학회 공식 사이트가 열립니다 |
| **로그인 시 자동 실행** | `SMAppService` 토글 하나 |
| **3개 국어** | English · 한국어 · 中文, 톱니바퀴 메뉴에서 즉시 전환 (기본값은 시스템 언어) |

## 설치

```bash
git clone https://github.com/LucasHyun/paperrush-bar.git
cd paperrush-bar
./build.sh && ./install.sh
```

필요 조건: **macOS 13 (Ventura) 이상**, Xcode Command Line Tools
(`swiftc`가 없다면 `xcode-select --install` 한 번). Xcode 프로젝트도 패키지 매니저도 쓰지 않고,
`build.sh`가 `swiftc`를 한 번 호출해 `.app` 번들을 직접 조립합니다.

제거는 `./uninstall.sh`.

> 빌드는 ad-hoc 서명(`codesign --sign -`)을 합니다. 알림과 로그인 항목이 동작하려면 이 서명이 필요합니다.
> Developer ID 서명은 아니므로 첫 실행 시 macOS가 확인을 요구할 수 있습니다.

## 구조

```
Sources/
├─ Models.swift    학회·마감 모델, 날짜 파싱, 카테고리
├─ Store.swift     다운로드·캐시·즐겨찾기·알림 예약·로그인 항목
├─ L10n.swift      앱 내 번역(en/ko/zh) 및 언어별 날짜 형식
├─ MenuView.swift  드롭다운 UI: 검색, 필터, 목록, 설정
└─ App.swift       MenuBarExtra 진입점
Resources/conferences.json   최초 실행용 오프라인 스냅샷
Info.plist                   LSUIElement = true (Dock 아이콘 없음)
```

**`js/data.js` 파싱.** 원본은 JSON이 아니라 JS 파일이라 `const CONFERENCES_DATA = {…};` 뒤에
`CATEGORIES`와 `module.exports`가 이어집니다. `Store.extractJSONObject`가 문자열 리터럴과
이스케이프를 건너뛰며 중괄호 깊이를 세어 객체 하나만 잘라냅니다 — 현재 31개 학회 / 225개 마감 전부 파싱됩니다.

**날짜.** 두 형식이 섞여 있습니다. 오프셋이 붙은 ISO(`2026-09-25T23:59:00-12:00`, AoE는 `-12:00`)와
날짜만 있는 값(`2027-04-06`, 로컬 23:59로 취급). D-day는 로컬 시간대 기준 달력 일수 차이라 자정에 정확히 바뀝니다.

**알림 개수.** macOS의 대기 알림 한도 때문에 가장 임박한 제출 마감 20개 × 3회만 예약하고,
데이터가 갱신될 때마다 다시 계산합니다.

## 언어 추가하기

모든 문자열은 `Sources/L10n.swift` 안 표 하나에 있습니다. `AppLanguage`와 `Lang`에 case를 추가하고
로케일 식별자를 지정한 뒤 열을 채우면 끝입니다. 다른 코드는 손댈 필요가 없습니다 — PR 환영합니다.

## 학회 데이터

이 앱은 뷰어입니다. 마감이 틀렸거나 학회가 빠졌다면 원본인
[awsaf49/paperrush](https://github.com/awsaf49/paperrush)에 고치는 편이 모두에게 이득입니다.
본인 포크를 쓰고 싶다면 `Store.sourceURL`만 바꾸세요.

## 라이선스

[MIT](LICENSE). 학회 데이터의 권리는 paperrush 프로젝트와 기여자들에게 있습니다.
