# NodeLoc iOS — 服务端待办（App Store 上架合规）

iOS 端已完成的部分见文末「客户端已完成」。本文档只列**必须由服务端/后台完成**的事项。

对应 App Store Review Guidelines：
- **4.7** Mini apps, mini games, streaming games, chatbots, plug-ins, and game emulators
- **5.3** Gaming, Gambling, and Lotteries

关键参数（客户端已固定，服务端配置需与之一致）：

| 项 | 值 |
|---|---|
| Bundle ID | `com.nodeloc.app` |
| Team ID | `JU847GN98N`（Nodeloc LLC） |
| 完整 App ID | `JU847GN98N.com.nodeloc.app` |
| 站点主域名 | `www.nodeloc.com` |

---

## 1. 【已上线 2026-09-02】Universal Links —— apple-app-site-association

> **已核实上线**：`https://www.nodeloc.com/.well-known/apple-app-site-association`
> 返回 `200`、`Content-Type: application/json`、**0 次重定向**，appIDs 和
> components 与下方要求完全一致。1.2 那份硬性要求逐条通过。
> 裸域 `https://nodeloc.com/...` 也返回 `200`，但是**经过 1 次重定向**拿到的；
> 由于 entitlements 里只声明了 `applinks:www.nodeloc.com`，这不影响 4.7.4
> （提交给 Apple 的 index 用的就是 www）。见文末「未做的小项」。

**为什么必须**：Guideline **4.7.4** 原文要求
> "You must provide an index of software and metadata available in your app. It must include universal links that lead to all of the software offered in your app."

小程序（17 个 webview 应用）必须每个都有 universal link。下面这份文件就是为此准备的，现已上线。

### 1.1 需要提供的文件

路径：`https://www.nodeloc.com/.well-known/apple-app-site-association`

内容：

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["JU847GN98N.com.nodeloc.app"],
        "components": [
          { "/": "/apps/*" },
          { "/": "/t/*" },
          { "/": "/u/*" },
          { "/": "/n/*" }
        ]
      }
    ]
  }
}
```

### 1.2 硬性要求（很容易踩错，逐条核对）

- [ ] `Content-Type: application/json`
- [ ] **不能有任何重定向**（包括 `http→https`、`nodeloc.com→www.nodeloc.com`）。Apple 的 CDN 抓取时不跟随 302
- [ ] 文件**不要**签名（`.pkcs7` 是旧格式，现在用纯 JSON）
- [ ] 必须走 HTTPS，证书有效
- [ ] 不能要求登录/Cookie，必须匿名可取
- [ ] `apple-app-site-association` **没有** `.json` 后缀

自查命令：

```bash
curl -sv https://www.nodeloc.com/.well-known/apple-app-site-association 2>&1 \
  | grep -Ei "HTTP/|content-type|location"
# 期望：HTTP/2 200、content-type: application/json、无 location
```

### 1.3 同时确认根域名也能取到

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://nodeloc.com/.well-known/apple-app-site-association
```

> 客户端的 `LinkRouter` 把 `nodeloc.com` 和 `www.nodeloc.com` 视为同一站点，两个域名都建议提供。

### 1.4 已确认可用（无需改动）

以下路由已存在并返回 200，客户端已能原生解析，**不用新建页面**：

- `https://www.nodeloc.com/apps/{slug}` → 200（客户端解析为原生小程序详情页）
- `https://www.nodeloc.com/apps/directory` → 200（作为 4.7.4 的 index 提交给 Apple）
- `https://www.nodeloc.com/apps/directory.json` → 200

---

## 2. 【已上线 2026-09-02】小程序功能开关接口 —— feature flags

> **已核实上线**：`GET /mobile/feature_flags.json` 返回 `200`、
> `{"mini_apps_enabled":true,"lottery_enabled":true}`，匿名可取。
> 被拒时可以直接服务端关掉，不用重新打包排队。

**为什么必须**：小程序（4.7）和抽奖（5.3）都有被拒风险。没有服务端开关的话，任何一项被拒都要**重新打包、重新排队审核**，整个版本被卡住。有开关就能服务端关掉再申诉。

### 2.1 接口

```
GET /mobile/feature_flags.json
```

匿名可取（未登录也要能读），返回：

```json
{
  "mini_apps_enabled": true,
  "lottery_enabled": true
}
```

### 2.2 客户端行为（已实现，供后端理解语义）

| 情况 | 客户端行为 |
|---|---|
| 接口 404 / 超时 / 报错 | 保持**上一次**读到的值；从未读到过则默认 `true` |
| 字段缺失（如只返回 `lottery_enabled`） | 缺失的那个保持原值 |
| 返回 `false` | 写入本机并持久化 |

> **持久化是有意的**：一旦服务端说过 `false`，之后即使断网启动也保持关闭。否则网络抖动会把刚被拒的功能又打开。

### 2.3 关掉后的效果（已实现）

- `mini_apps_enabled: false` → 只隐藏「开始游戏」按钮。应用目录、应用详情、`查看讨论` 都保留（4.7 管的是运行 webview 那部分）
- `lottery_enabled: false` → 隐藏抽奖创建入口；已有帖子里的抽奖卡片仍显示奖项和结果，但**不能再参与**
- 红包不受影响（领红包不需要付出代价，不构成 contest）

### 2.4 建议做成后台可配

放在 Discourse 站点设置里，改完即时生效，不要写死在代码里。

---

## 3. 【服务端已上线,客户端未接】小程序分级字段

> **已核实 2026-09-02**:`/apps/directory.json` 每个 app 上**已经有** `age_rating`
> 和 `content_descriptors` 了,不用再加。当前全部 33 个 app 的 `age_rating` 都是 `4`。
>
> 也就是说 3.1 要的字段服务端做完了,但**客户端还在走 3.2 的兜底**(把所有小程序
> 当作不超过 App 分级)。要真正满足 4.7.5 的「识别出超出分级的软件」,还需要客户端
> 把 `age_rating` 读出来并和 `MiniAppGate.minimumAge` 比较。因为目前所有值都是 4,
> 兜底和真实判断的结果一致,**不阻塞这次提审**。
>
> 顺带修正:这个接口返回的是 `{ apps, total, page, per_page }` 对象且**分页固定 24 条**
> (`per_page` 作为入参被忽略,`page` 从 0 开始)。客户端原来按裸数组解析,既报错也
> 只拿得到前 24 个 —— 已修。

**为什么**：Guideline **4.7.5** 原文
> "Your app must provide a way for users to identify software that **exceeds the app's age rating**, and use an age restriction mechanism based on verified or declared age to limit access by underage users."

客户端已实现「声明年龄 + 未满 17 岁不能运行小程序」，但要做到「**识别出哪些小程序超出 App 分级**」，需要每个小程序自己的分级。

### 3.1 建议在 `/apps/directory.json` 和 `/apps/{slug}.json` 每个 app 上增加

```json
{
  "slug": "tic-tac-toe",
  "name": "Tic-Tac-toe",
  "age_rating": 4,
  "content_descriptors": []
}
```

- `age_rating`：整数，取 `4 / 9 / 12 / 17`，对齐 App Store 分级档位
- `content_descriptors`：可选，如 `["cartoon_violence", "simulated_gambling"]`

### 3.2 没有这个字段的兜底方案

客户端目前按「所有小程序都不超过 App 分级」处理，并在审核备注里说明。这条**能过但不理想**——如果将来有成人向小游戏上架，就必须补这个字段。

### 3.3 后台还需要

- [ ] 小程序上架审核时必须填分级
- [ ] 举报队列要能处理小程序举报（客户端已接入，走的是标准 flag 队列，flag 的是小程序的宿主主题）

---

## 4. 【已确认】积分不可购买 —— 抽奖可以保留

**已确认（2026-09-02）**：积分（能量）**不能用钱购买**。会员通过站内活动免费获得积分，抽奖奖品也全部是站内虚拟物品。

因此：

| Guideline | 结论 |
|---|---|
| 5.3.3 "may not use in-app purchase to purchase credit or currency for use in conjunction with real money gaming" | **不适用** —— App 内没有任何 IAP，积分也无法用现金购买 |
| 5.3.4 real money gaming 的牌照与地区限制要求 | **不适用** —— 没有现实价值的对价，也没有现实价值的奖品 |

**`lottery_enabled` 保持 `true` 提交。**

### 仍需服务端保证（这是上面结论成立的前提）

- [ ] 积分永远不开放现金购买/充值。一旦开放，抽奖必须同时下架（把 `lottery_enabled` 设为 `false`）
- [ ] 积分不能兑换成现金、实物或任何站外权益
- [ ] 奖品审核按第 5 节执行，确保只有站内虚拟物品

### 另一个独立问题：`/payment/applications` —— 已处理（客户端）

**已确认**：OAuth 应用和支付应用都是**给开发者用的后台**，不面向普通会员。

客户端已在 `SidebarStore.defaultResources` 里移除这两个入口：

- ~~OAuth 应用 → `/oauth-provider/applications`~~
- ~~支付应用 → `/payment/applications`~~

这样 App 内不再有任何指向站外付费页面的链接，Guideline **3.1.1**（不得引导用户到站外购买）没有暴露面。

> 服务端**不需要改动**，页面保留在网站上即可。开发者仍可以直接在浏览器访问。

## 5. 【建议】抽奖奖品的服务端约束

客户端已做的：
- 抽奖规则页（含 Apple 免责声明）
- 奖品输入框提示「限站内虚拟物品」
- 抽奖卡片上有举报入口

客户端**做不到**的（奖品是自由文本，只能靠后端和人工）：

- [ ] 站点规则里写明：奖品仅限站内虚拟物品（能量／徽章／头衔／社区身份），禁止现金、实物、礼品卡、可兑换站外权益的物品
- [ ] 举报队列里对「抽奖奖品违规」做处理流程
- [ ] 建议：`lottery_controller#create` 服务端校验奖品文本，命中现金/红包/微信/支付宝/实物等关键词时拒绝或转人工

> Guideline **5.3.1** 原文是 "Sweepstakes and contests must be sponsored by the developer of the app."。抽奖由用户发起，严格按字面读**无法完全满足**。上面这些措施的作用是把抽奖定性成「站内积分玩法」而不是「有现实价值的抽奖」，从而让 5.3 不适用。这是降低风险，不是消除风险——所以第 2 项的开关必须有。

---

## 6. 【建议】Klipy API Key 改为服务端代理

现状：`DiscourseConfig.klipyAPIKey` **硬编码在 App 里**，可以从 IPA 里直接提取。

建议在 companion plugin 里加一个代理接口：

```
GET /mobile/gifs/search.json?q=<query>&pos=<cursor>
```

服务端持有 key 转发到 `https://api.klipy.com/v2/search`，返回原样 JSON（客户端已有的 `KlipySearchResponse` 解析结构可直接复用，字段不用改）。

这样：
- key 不再随包分发
- 第三方请求从「App 直连 Klipy」变成「App → 自家服务器」，隐私申报也更简单

不做这个不影响上架，只是 key 会泄露。

---

## 7. 提交给 Apple 的材料（需要服务端提供内容）

### 7.1 App Review Notes 里要写的（4.7.4 的 index）

```
Mini apps index:      https://www.nodeloc.com/apps/directory
Machine-readable:     https://www.nodeloc.com/apps/directory.json
Per-app universal link pattern: https://www.nodeloc.com/apps/{slug}
```

### 7.2 需要服务端确认后写进备注的技术说明

- 小程序运行在服务端文档内的 **opaque-origin iframe** 里
- 客户端 WKWebView **没有** `WKScriptMessageHandler`、没有注入脚本、没有 `evaluateJavaScript`，不向小程序暴露任何原生 API（对应 4.7.2，客户端已核实）
- 小程序的权限范围由服务端 `approved_scopes` 授予，客户端在**每个小程序首次运行前**展示并要求用户同意（对应 4.7.3）

### 7.3 审核账号

需要提供一个可登录的测试账号（游客模式只能浏览，发帖／聊天／举报／抽奖都需要账号）。

---

## 客户端已完成（无需服务端配合，仅供对照）

| Guideline | 实现 |
|---|---|
| 4.7.1 | 小程序菜单加了**举报**（走标准 flag 队列，flag 宿主主题）和**屏蔽作者** |
| 4.7.2 | 已核实无 JS bridge、无注入脚本、无原生 API 暴露 |
| 4.7.3 | 每个小程序**首次运行前**展示 `approved_scopes` 并要求同意，按 slug 分别记录 |
| 4.7.4 | `LinkRouter` 已能把 `/apps/{slug}` 解析为原生详情页（`/apps/directory` 和 `/apps/installs/*` 正确排除） |
| 4.7.5 | 声明出生年份，未满 17 岁不能运行小程序，只存本机不上传 |
| 5.3.2 | 抽奖规则页，含「Apple 不是本活动的赞助方，也未以任何方式参与本活动」；从抽奖卡片和创建界面都能打开 |
| 5.3 | 奖品输入框提示限站内虚拟物品；抽奖卡片有举报入口 |
| 5.1 | `PrivacyInfo.xcprivacy` 增加 Klipy 搜索词申报（`SearchHistory`，not linked） |
| 1.2 | 屏蔽作者已补到**回复的 `…` 菜单**（`PostDetailOverlay.replyMoreSheet`），紧跟在举报下面；屏蔽后 `TopicStore.blockAuthor` 会重载主题，该作者的回复立刻变成 ignored 占位块 |
| 1.2 | 登录／注册页的服务条款和隐私政策改成**真链接**（`AuthLegalCopy`），未登录也能读；走 `LinkRouter` 在内置浏览器打开 |
| — | `FeatureFlags` 读 `/mobile/feature_flags.json`，可服务端关闭小程序／抽奖 |

### Xcode 侧（已完成 2026-09-02）

- ✅ Associated Domains 已加：`nodeloc/nodeloc.entitlements` 含 `applinks:www.nodeloc.com`，`CODE_SIGN_ENTITLEMENTS` 在 Debug 和 Release 都已设置，已核实打出的包里带这个 entitlement

**Universal Links 两半都已就位**（entitlements + AASA），4.7.4 的链路已通。

### 未做的小项（不阻塞上架）

- 裸域 `nodeloc.com` 没写进 entitlements，而且它的 AASA 是经重定向返回的（Apple 抓 AASA 不跟随重定向）。结果是分享出去的 `nodeloc.com/t/...` 不会唤起 App，只有 `www.` 会。要修的话得让裸域**直接**返回该文件，再把 `applinks:nodeloc.com` 加进 entitlements。
- 第 3 节的 `age_rating` 字段仍未提供，按 3.2 的兜底方案提交。
- 第 6 节的 Klipy key 仍硬编码在包里。
