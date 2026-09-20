<div align="center">

# PaperRush Bar ⏳

**把 AI 会议截止日期放进 macOS 菜单栏。**

`⏳ ICLR D-5` —— 不用开网页，随时看得到，而且始终是最新的。

[English](README.md) · [한국어](README.ko.md) · 中文

![platform](https://img.shields.io/badge/macOS-13%2B-black)
![language](https://img.shields.io/badge/Swift-5-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## 这是什么

一个约 1 MB 的原生菜单栏小程序，不用 Electron，也不依赖 Python。它在菜单栏常驻显示距离下一个
AI/ML 会议投稿截止还有几天，并在后台自动保持数据最新。

截止数据来自 [**awsaf49/paperrush**](https://github.com/awsaf49/paperrush)，该项目通过 GitHub Actions
自动更新数据集，因此本应用无需维护即可同步上游。

| | |
|---|---|
| **菜单栏倒计时** | 以 `ICLR D-5` 的形式显示最近的投稿截止，跨过午夜自动刷新 |
| **每日自动更新** | 每 30 分钟检查一次，数据超过 6 小时即重新下载，休眠唤醒后也会刷新 |
| **离线可用** | 最近一次数据缓存在 Application Support，应用内置快照供首次启动使用 |
| **D-7 / D-3 / D-1 提醒** | 当天上午 9:00 发送系统通知 —— 关闭 / 仅收藏 / 全部 |
| **收藏** | 加 ★ 的会议置顶，也可让菜单栏与通知只关注收藏项 |
| **点击打开官网** | 点击任意一行即可打开该会议官方网站 |
| **补充会议** | 内置 12 个上游尚未收录的会议并自动合并，也可在可编辑的文件中添加你自己的会议 |
| **登录时自动启动** | 通过 `SMAppService` 一键开关 |
| **三种语言** | English · 한국어 · 中文，齿轮菜单中即时切换（默认跟随系统语言） |

## 安装

```bash
git clone https://github.com/LucasHyun/paperrush-bar.git
cd paperrush-bar
./build.sh && ./install.sh
```

环境要求：**macOS 13 (Ventura) 及以上**，以及 Xcode 命令行工具
（若缺少 `swiftc`，先执行 `xcode-select --install`）。项目没有 Xcode 工程文件，也不用包管理器，
`build.sh` 只调用一次 `swiftc` 并自行组装 `.app`。

卸载执行 `./uninstall.sh`。

> 构建会做 ad-hoc 签名（`codesign --sign -`），通知和登录项依赖它。
> 由于没有 Developer ID 签名，macOS 首次启动时可能要求确认。

## 实现说明

```
Sources/
├─ Models.swift    会议与截止模型、日期解析、分类
├─ Store.swift     下载、缓存、收藏、通知调度、登录项
├─ L10n.swift      应用内翻译（en/ko/zh）与本地化日期格式
├─ MenuView.swift  下拉界面：搜索、筛选、列表、设置
└─ App.swift       MenuBarExtra 入口
Resources/conferences.json   首次启动用的离线快照
Info.plist                   LSUIElement = true（不显示 Dock 图标）
```

**解析 `js/data.js`。** 上游提供的是 JavaScript 文件而非 JSON：`const CONFERENCES_DATA = {…};`
之后还跟着 `CATEGORIES` 与 `module.exports`。`Store.extractJSONObject` 在跳过字符串字面量与转义的同时
统计花括号深度，精确截取出一个对象 —— 目前 31 个会议、225 条截止全部解析成功。

**日期。** 数据中有两种格式：带时区偏移的完整 ISO（`2026-09-25T23:59:00-12:00`，AoE 为 `-12:00`）
和仅日期（`2027-04-06`，按本地 23:59 处理）。D-day 按本地时区的日历天数计算，因此正好在午夜跳变。

**通知上限。** macOS 限制待发本地通知数量，所以应用只为最近的 20 个投稿截止 × 3 次提醒排期，
并在每次数据刷新后重新计算。

## 添加语言

所有文案集中在 `Sources/L10n.swift` 的一张表里。新增语言只需在 `AppLanguage` 和 `Lang` 中加一个 case，
指定 locale 标识符，然后补上对应列，其余代码无需改动 —— 欢迎提 PR。

## 会议数据

截止数据来自上游，并在其之上合并一层补充数据，这样上游缺少的会议不必等到 PR 合并才能看到：

```
内置 extras.json  <  你的 extras.json  <  上游 paperrush
```

`id` 相同时永远以上游为准，因此一旦 paperrush 收录了同一个会议，补充条目会自动退场 —— 不留重复，无需清理。

**内置**（`Resources/extras.json`，列表中标记 `补充`）：WWW、WSDM、ICDM、CIKM、ECML PKDD、SIGIR、
RecSys、COLM、UAI、ACM MM、AAMAS、ECAI。若下一届 CFP 尚未公布，日期由上一轮推断得出并标记 `预估` ——
绝不会当作已确认的日期展示。

**你的会议**：齿轮菜单 → *已补充的会议*，会创建并在访达中打开
`~/Library/Application Support/PaperRushBar/extras.json`。schema 完全相同，每次刷新都会重新读取，
保存后点一下 ↻ 即可生效。

若截止日期有误，或缺少的会议对所有人都有价值，请到上游
[awsaf49/paperrush](https://github.com/awsaf49/paperrush) 修正。上述 12 个会议的贡献草稿已放在
[`upstream/`](upstream/)。想改用自己的 fork，修改 `Store.sourceURL` 即可。

## 许可证

[MIT](LICENSE)。会议数据的权利归 paperrush 项目及其贡献者所有。
