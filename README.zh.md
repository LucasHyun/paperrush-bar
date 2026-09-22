<div align="center">

<img src="Resources/AppIcon.iconset/icon_256x256.png" width="120" alt="PaperRush Bar">

# PaperRush Bar

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
| **菜单栏倒计时** | 以 `ICLR D-5` 的形式显示最近的投稿截止；沙漏中的沙量表示 30 天内剩余的时间，并从 D-7 起由黄 → 橙 → 红渐变，跨过午夜时会落下一粒沙，进入 D-3 后沙会自行流动，越接近截止越快，D-1 起还会不安地轻轻晃动（遵循“减弱动态效果”设置） |
| **每日自动更新** | 每 30 分钟检查一次，数据超过 6 小时即重新下载，休眠唤醒后也会刷新 |
| **离线可用** | 最近一次数据缓存在 Application Support，应用内置快照供首次启动使用 |
| **D-7 / D-3 / D-1 提醒** | 当天上午 9:00 发送系统通知 —— 关闭 / 仅收藏 / 全部 |
| **收藏** | 加 ★ 的会议置顶，也可让菜单栏与通知只关注收藏项 |
| **点击打开官网** | 点击任意一行即可打开该会议官方网站 |
| **补充会议** | 18 个上游未收录 + 7 个只收录一半的会议，每周从各自 CFP 重新读取更新，也可添加你自己的会议 |
| **登录时自动启动** | 通过 `SMAppService` 一键开关 |
| **三种语言** | English · 한국어 · 中文，齿轮菜单中即时切换（默认跟随系统语言） |

## 安装

最快的方式 —— 任何装有 Python 的 Mac（会向这些会议投稿的人，机器上一定有）：

```bash
pip install paperrush-bar && paperrush-bar install      # 或：uvx paperrush-bar install
```

它会下载发布包、校验 SHA-256，并把 `PaperRushBar.app` 放进 `/Applications`。
之后用 `paperrush-bar upgrade` 升级 —— 有新版本时应用自己也会提示。
Homebrew 用户：`brew tap LucasHyun/tap && brew install --cask paperrush-bar`。

从源码构建，需要 Xcode 命令行工具（`xcode-select --install`）：

```bash
git clone https://github.com/LucasHyun/paperrush-bar.git
cd paperrush-bar
./build.sh && ./install.sh
```

没有 Xcode 工程也不用包管理器 —— `build.sh` 只调用一次 `swiftc` 并自行组装 `.app`。
需要 **macOS 13 (Ventura) 及以上**。卸载用 `./uninstall.sh` 或 `paperrush-bar uninstall`。
各发布渠道的配置见 [`packaging/`](packaging/README.md)。

> 构建会做 ad-hoc 签名（`codesign --sign -`），通知和登录项依赖它。
> 由于没有 Developer ID 签名，macOS 首次启动时可能要求确认。

## 实现说明

```
Sources/
├─ Models.swift    会议与截止模型、日期解析、分类
├─ Store.swift     下载、缓存、收藏、通知调度、登录项
├─ L10n.swift      应用内翻译（en/ko/zh）与本地化日期格式
├─ MenuView.swift  下拉界面：搜索、筛选、列表、设置
├─ HourglassIcon.swift  运行时绘制的菜单栏图标，沙量 = 剩余时间
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

**补充层**（列表中标记 `补充`）包含上游没有的 18 个会议 —— WWW、WSDM、ICDM、CIKM、ECML PKDD、
SIGIR、RecSys、COLM、UAI、ACM MM、AAMAS、ECAI，以及 NAACL、INTERSPEECH、ICRA、WACV、AAAI、3DV 的下一届 ——
外加 7 个补丁，补上上游只收录了一半的部分：KDD 第二轮、ICASSP 2027 的完整日程，以及 ACL、EACL、COLING
的 ARR commitment 截止（这才是这些会议真正卡的日期）。若下一届 CFP 尚未公布，日期由上一轮推断得出并标记
`预估` —— 绝不会当作已确认的日期展示。

它会自动保持最新。`scripts/update_extras.py` 每周在 Actions 中运行（周一 06:30 UTC，紧接上游任务之后）：
重新读取每条截止的 `sourceUrl`，用 **Gemini 2.5 Flash** 提取日程，只提交能够验证的结果。CFP 一旦公布，
`预估` 会自动变成确认日期。应用通过网络读取已发布的 `Resources/extras.json`，因此**无需重新构建**即可生效，
应用内置的副本只作为离线回退。

未经验证的内容不会进入：模型给出的日期只有在 (1) 其 `sourceUrl` 属于实际抓取过的页面，且 (2) 该日期确实
出现在该页面正文中时才会被采纳；验证失败则保留原值。模型也无法把自己的推断从 `预估` 提升为已确认。
配置只需一个密钥：*Settings → Secrets and variables → Actions* 中的 `GEMINI_API_KEY`。
未设置时仅该任务失败，其余功能照常。

```bash
export GEMINI_API_KEY=...
python scripts/update_extras.py --dry-run          # 只看会改动什么
python scripts/update_extras.py -c www,sigir       # 仅指定会议
```

**补丁**：带 `"mode": "patch"` 且 `id` 与上游相同的条目不会替换该会议，而是**只补上上游缺少的截止**。
KDD 每年有两轮投稿，而上游只收录了 Cycle 1，因此 `kdd-2027` 被补上了 Cycle 2。一旦上游发布了同一个
节点，补丁条目会自动退出（按类型 + 日期匹配；若是推断日期，相差 45 天以内即视为同一节点）。

**你的会议**：齿轮菜单 → *已补充的会议*，会创建并在访达中打开
`~/Library/Application Support/PaperRushBar/extras.json`。schema 完全相同，每次刷新都会重新读取，
保存后点一下 ↻ 即可生效。

若截止日期有误，或缺少的会议对所有人都有价值，请到上游
[awsaf49/paperrush](https://github.com/awsaf49/paperrush) 修正。贡献草稿已放在
[`upstream/`](upstream/)。想改用自己的 fork，修改 `Store.sourceURL` 即可。

## 许可证

[MIT](LICENSE)。会议数据的权利归 paperrush 项目及其贡献者所有。
