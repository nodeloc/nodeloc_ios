# NodeLoc iOS — 服务端需求：个人页聚合接口

需求方：iOS App（`com.nodeloc.app`）
实现位置：`discourse-mobile` 插件（沿用现有 `/mobile/*` 路由风格）
状态：**待后端实现**

---

## 1. 为什么要做

打开「我的」页面时，客户端目前**并发发起 5 个请求**（`ProfileStore.load()`），
切换 tab 时再加 1~2 个。全部串在同一个首屏上，慢的那一个决定了首屏时间。

现状（路径均已核实，取自 `Core/DiscourseAPI.swift`）：

| # | 现有接口 | 客户端方法 | 用途 | 来源 |
|---|---|---|---|---|
| 1 | `GET /u/{username}.json` | `client.user(_:)` | 头像、昵称、简介、位置、网站、注册时间、头衔、徽章 | Discourse 核心 |
| 2 | `GET /u/{username}/summary.json` | `client.userSummary(_:)` | 统计数字（发帖数、获赞数、访问天数等） | Discourse 核心 |
| 3 | `GET /node/recently-visited.json` | `client.recentlyVisitedNodes()` | 最近访问的节点 | discourse-community |
| 4 | `GET /u/{username}/points-scores.json?page=0` | `client.pointsTotal(username:)` | 能量总额 | discourse-points-service |
| 5 | `GET /u/{username}/upgrade-progress.json` | `client.upgradeProgress(username:)` | 升级进度 | discourse-upgrade-process |
| 6 | `GET /user_actions.json?username=&filter=&offset=0&limit=30` | `client.userActions(...)` | 默认 tab（主题 filter=4）第一页 | Discourse 核心 |
| 7 | `GET /u/{username}/points-history.json?page=0` | `client.pointsHistory(...)` | 「能量」tab 明细 | discourse-points-service |

> 说明：`DiscourseLocale.preload()` 和 `TitleStyleCatalog` 也在这个流程里，但它们
> **每个进程只请求一次**并缓存，不算每次打开的开销，本需求不涉及。

目标：**打开个人页只发 1 个请求**（第 1~6 项），第 7 项按需。

---

## 2. 接口定义

```
GET /mobile/profile.json?username={username}&activity_filter={int}
```

- `username`：可选。缺省 = 当前登录用户。
  **建议支持任意用户名**，因为 App 里「别人的主页」（`PublicProfileOverlay`）
  拉的是同一组数据，一个接口可以同时省掉那边的 4 个请求。
- `activity_filter`：可选，Discourse UserAction 类型码。缺省 `4`（主题）。
  取值：`1`=收到的赞、`3`=书签、`4`=主题、`5`=回复。
- 认证：**必须支持 User API Key**（`read` scope）。App 现在用的是 User API Key，
  不是 session cookie —— 和 `/mobile/feature_flags.json` 一样能通就行。
- 未登录（匿名）访问：返回公开字段，`points` / `upgrade` / `checkin` 允许为 `null`。

### 2.1 响应结构：**原样嵌套，不要重新造字段名**

这是本需求最重要的一条。请把每个 key 的值 = **对应旧接口响应体的原文**，
不要改字段名、不要扁平化、不要驼峰转下划线。

```json
{
  "version": 1,
  "user":     { /* 与 GET /u/{username}.json 完全一致的响应体 */ },
  "summary":  { /* 与 GET /u/{username}/summary.json 完全一致 */ },
  "nodes":    { /* 与 GET /node/recently-visited.json 完全一致 */ },
  "points":   { /* 与 GET /u/{username}/points-scores.json?page=0 完全一致 */ },
  "upgrade":  { /* 与 GET /u/{username}/upgrade-progress.json 完全一致 */ },
  "activity": { /* 与 GET /user_actions.json?... 完全一致 */ },
  "checkin":  { "checked_in_today": true, "next_available_at": "2026-09-10T00:00:00Z" },
  "generated_at": "2026-09-09T12:34:56Z"
}
```

**为什么必须原样嵌套**：客户端已有 5 个经过实战的 Codable 模型
（`UserResponse`、`UserSummaryResponse`、`SidebarCommunitiesResponse`、
`PointsScoresResponse`、`UpgradeProgressReport`、`UserActionsResponse`）。
原样嵌套的话，客户端只要加一层外壳就能复用它们，**不新增任何解析风险**；
换一套字段名则要重写全部模型。

这一点不是洁癖。本项目已经被同类问题咬过两次：
- `site.json` 里 `trust_levels` 一个字段类型不对，`try?` 把**整个响应**吞掉，
  结果每个帖子的节点名都变成空；
- Rails 枚举序列化成字符串而不是整数（`default_calendar`），
  导致 `current_user` 解析失败，用户看到「登录未完成」。

Swift 的 `Codable` 是全或无：**一个字段类型不符，整个响应就废掉**。所以字段名和
类型必须和现有接口逐字一致。

### 2.2 失败隔离（硬性要求）

任何一个子数据源出错（插件报错、超时、字段缺失），**不允许整体 500**。
出错的那个 key 返回 `null`，其余照常返回 200。

**为什么必须**：客户端现在每个调用都是独立的 `try?`，points 挂了个人页照样能看。
聚合之后如果变成一荣俱荣一损俱损，可用性是下降而不是上升。

建议在响应里带上降级信息，便于排查（可选）：

```json
"errors": { "points": "timeout" }
```

---

## 3. 缓存与条件请求

客户端会把整份响应存到本地磁盘，下次打开**先直接渲染缓存**，同时后台请求刷新
（stale-while-revalidate）。为此需要服务端配合：

1. **必须**返回 `ETag`（对响应体做 hash 即可）。
2. **必须**支持 `If-None-Match`，未变化时返回 `304 Not Modified` 且空 body。
3. 建议 `Cache-Control: private, max-age=0, must-revalidate`
   —— 这是私有数据，中间层不得缓存。

`304` 的收益很直接：绝大多数「打开个人页」其实什么都没变，一次 304 比五次
200 便宜得多。

---

## 4. 性能要求

- 目标 **P95 < 300ms**（服务端处理时间，不含网络）。
- **不得**为了聚合去遍历用户表或全站数据。

> 这条是有前情的：之前为了找「公开的自定义 feed」，有个实现去扫了 376 个用户，
> 在生产上跑了 **约 521 秒**。聚合接口是首屏接口，绝不能出现这类扫描。

- 注意 N+1：徽章、节点、能量明细都容易一条条查。
- 如果某个插件数据确实慢，宁可先返回 `null`（见 2.2）再让客户端单独补拉，
  也不要拖慢整个首屏。

---

## 5. 灰度与回退

`/mobile/feature_flags.json` 已经在用了，请在里面加一个开关：

```json
{ "profile_aggregate": true }
```

客户端行为：
- flag 为 `true` 且接口可用 → 走聚合接口；
- flag 缺失 / `false` / 接口 404 → **自动退回现在的 5 个并发请求**。

这样后端可以随时上线/回滚，不需要等 App 发版，老版本 App 也不受影响。
（App 会做 404 兜底，但请不要依赖它作为常规下线手段。）

---

## 6. 建议顺带解决的一个问题：签到状态

`checkin.checked_in_today` 在上面的结构里是**新增**字段，不是任何旧接口的搬运。

现在客户端是把「今天签到过了」写在本机 `UserDefaults` 里
（`ProfileStore.checkInKey`），因此：
- 换设备、重装 App → 签到按钮又变成可点，点了服务端才说「今天已签到」;
- 同一账号两台设备状态不一致。

服务端本来就知道答案，顺手带回来即可。`POST /checkin` 保持不变。

---

## 7. 验收清单

- [ ] `GET /mobile/profile.json` 带 User API Key 返回 200，结构同 2.1
- [ ] 不带 `username` 时返回当前登录用户
- [ ] 带任意 `username` 时返回该用户（公开字段）
- [ ] `activity_filter` 分别传 1 / 3 / 4 / 5 都能返回对应活动列表
- [ ] 把 points-service 停掉，接口仍返回 200，`points` 为 `null`
- [ ] 第二次请求带 `If-None-Match` 返回 304
- [ ] 每个子对象都能被客户端现有模型解析（联调时以客户端解析成功为准）
- [ ] `feature_flags.json` 里出现 `profile_aggregate`
- [ ] 压测：P95 < 300ms，且无全表扫描

---

## 8. 客户端这边的配套改动（不需要后端做，列出以便对齐）

1. `ProfileAggregateResponse` 外壳模型，内部复用现有 6 个模型。
2. 个人页数据落盘（`FileManager` + JSON），启动即渲染缓存，再后台刷新。
   与 `ChatRealtime` 的原始 JSON 快照策略一致。
3. 保留现有 5 路并发作为回退分支，由 `profile_aggregate` flag 切换。
4. 签到状态改以服务端为准，本地 `UserDefaults` 仅作离线兜底。
