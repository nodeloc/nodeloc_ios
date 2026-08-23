# 01 · 产品概述与技术选型

## 1. 产品定位

NODELOC 是 nodeloc.com（Discourse 论坛 + 社区插件）的原生客户端。核心体验四块：

1. **信息流**（首页 latest + 节点页），三种阅读模式（紧凑/展开/卡片），全局共享一个模式选择。
2. **帖子阅读器**：服务端 HTML（cooked）解析为原生渲染的块级树（不是 WebView），支持嵌套回复树、折叠、点赞/打赏/书签/转发，以及投票、抽奖、红包三种插件交互。
3. **消息**：通知 + 私信 + **实时聊天**（MessageBus 长轮询 + 本地快照缓存，即时通讯手感）。
4. **账户体系**：帐密登录（含 TOTP/备用码二步验证）、网站 OAuth（User API Key）、分步注册（邮箱→用户名→密码→性别→兴趣节点）、游客模式全站可读。

## 2. 顶层导航

底部 5 Tab：**首页 / 节点 / 消息 / 搜索 / 我的**。
- 搜索是**真正的 Tab**（iOS 上用系统 searchable 集成，Android 对应方案见 06）。
- 全局左侧抽屉（汉堡菜单）：节点列表、最近访问、应用目录入口、设置。
- 帖子阅读器、发帖器、设置等以全屏层叠页呈现（iOS 是自绘 overlay 体系；Android 用 Navigation 目的地即可，见 06）。

## 3. 功能清单（与 iOS 对齐的验收基线）

| 域 | 功能 |
|----|------|
| 信息流 | latest 分页、下拉刷新（品牌 Lc 加载器）、骨架屏、三种行模式、未读点、断网空态+重试 |
| 节点 | 节点浏览（分组/分页）、节点详情（banner/简介/加入/通知级别）、节点内排序、域内搜索、创建节点 |
| 阅读器 | HTML→原生块渲染（段落/引用/代码/表格/折叠块/图片/视频/emoji/提及/onebox）、嵌套回复树+按作者折叠子树、楼层深链滚动、阅读进度上报（timings）、投票/抽奖/红包、打赏明细 |
| 撰写 | 发主题（选节点、标题、正文、媒体上传、GIF 搜索、红包/抽奖挂件）、回复（含 reply_to）、图片编辑（裁剪/涂鸦/文字）、视频裁剪与转 GIF |
| 消息 | 通知列表（分类文案统一）、私信会话（本质是 topic）、群组收件箱、聊天频道 + 讨论串、**聊天实时 + 磁盘快照秒开**、已读上报 |
| 搜索 | 全局搜索（全部/节点/帖子/用户/应用/媒体六个 scope，混合分组结果）、搜索历史、热门词 |
| 账户 | 帐密登录（+TOTP/备用码）、网站 OAuth、分步注册、忘记密码、游客模式（五处入口统一的登录按钮）、注册后待激活兴趣节点延迟加入 |
| 我的 | 资料卡（头像/资质 flair/头衔/徽章/统计）、活动 Tab（主题/帖子/赞/书签/能量）、编辑资料、关联账户、安全（改密/2FA 管理/会话管理） |
| 设置 | 界面偏好（颜色模式/文本大小→仅同步服务器/默认首页/阅读模式）、通知偏好、推送开关+分类过滤、隐私、邮件 |
| 推送 | **轮询式本地通知**（无 APNs/FCM 中继）：后台任务拉 notifications.json，水位线去重，分类可关，点击深链 |
| 浏览器 | 内置浏览器（悬浮镶边：底部 返回/前进/分享/刷新/外部打开 胶囊，上滑隐藏，域名胶囊带滚动进度背景，字号缩放菜单） |
| 看图 | 全屏查看器：翻页、双击/捏合缩放、平移、**下拉退出**（背景渐隐透出阅读器） |
| 应用目录 | discourse-apps 列表 + 详情 + webview 应用运行 |

## 4. 技术栈选型（建议）

| 层 | 选择 | 理由 |
|----|------|------|
| 语言 | Kotlin 2.x | — |
| UI | Jetpack Compose + Material 3（自定义主题覆盖为 Nocturne 令牌） | 对位 SwiftUI；LazyColumn 天然规避 iOS 版踩过的急切布局爆炸（见 07） |
| 架构 | MVVM：ViewModel + StateFlow / 单例 Repository | 对位 iOS 的 @Observable Store 体系 |
| 导航 | Navigation Compose（单 Activity） | 阅读器/设置等全屏页 = 目的地 |
| 网络 | OkHttp + Retrofit + kotlinx.serialization（`JsonNames`/snake_case 策略） | Cookie 管理必须用 OkHttp CookieJar（见 07 会话轮换） |
| 图片 | Coil 3（内存+磁盘缓存、按目标尺寸下采样、GIF 支持） | 对位 iOS 自研的 RemoteImage 双层缓存 |
| 本地存储 | DataStore(Preferences) + 文件系统 JSON 快照 | **禁止引入 Room/SQLite**——沿用无数据库决定 |
| 后台 | WorkManager（推送轮询）、前台协程（MessageBus 长轮询） | 对位 BGAppRefreshTask |
| 视频 | Media3 ExoPlayer | 信息流自动播放 + 全屏 |
| HTML 解析 | 自研轻量解析器（移植 iOS PostHTMLParser 的令牌化+块组装算法） | 见 04/07：**必须带嵌套深度熔断** |

## 5. 模块划分（Gradle）

```
app/                     组装、导航、DI
core/design/             主题令牌、组件库、品牌加载器
core/network/            Discourse 客户端、认证、MessageBus、错误映射
core/model/              DTO + 领域模型（与 iOS DiscourseModels 对齐）
core/htmlrender/         cooked HTML 解析器 + 块渲染 Composable
feature/feed/            首页 + 行组件（三模式）
feature/node/            节点浏览/详情/创建
feature/post/            阅读器 + 回复树 + 插件视图 + 撰写/回复
feature/chat/            消息中心（通知/私信/聊天 + 实时 + 快照缓存）
feature/search/          搜索
feature/profile/         我的 + 公开资料
feature/settings/        设置全家桶 + 推送设置
feature/auth/            登录/注册流程（含 2FA）
feature/media/           内置浏览器、图片查看器、图片编辑、视频裁剪
feature/apps/            应用目录
```
