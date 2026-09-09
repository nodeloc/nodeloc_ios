# App Review Notes — NodeLoc iOS 1.1

**1.0 was approved.** Everything below was written for that submission and is
kept because the guideline answers still apply — the features it describes all
still ship. What changed for 1.1 is listed under `WHATS_NEW_FOR_REVIEW`.

Paste the block below into **App Store Connect → App Review Information → Notes**.
It is written in English because that is what App Review reads.

Before submitting 1.1:
- [ ] Demo account still signs in. It was filled in and working for 1.0 —
      re-verify rather than assume, because 1.2 depends on it.

      > 1.0's first submission (f85c73dd) was rejected under 1.2 for
      > report/block "not found". Both write to the server and so need an
      > account: without a working demo login the reviewer cannot reach
      > either, no matter how the app is built. Keep this box honest.

- [ ] Confirm the mini-app and lottery sections still match what ships
- [ ] Re-attach the screen recording if the 1.2 flows changed visually
      (see `RECORDING_SCRIPT` at the bottom of this file)

Settled during the 1.0 review and not expected to need work again:
- [x] Age Rating: "Parental Controls" and "Age Assurance" both **None**
      (guideline 2.3.6 — see `AGE_RATING` below)
- [x] https://www.nodeloc.com/tos contains an explicit no-tolerance clause —
      §7 "Content Standards and Zero-Tolerance Policy" (verified 2026-09-06);
      §8 covers reporting and blocking. See `TERMS_WORDING`.

--------------------------------------------------------------------
WHATS_NEW_FOR_REVIEW — changes since the approved 1.0
--------------------------------------------------------------------
Nothing here changes the answers given for guidelines 1.2, 2.3.6, 3.1.1, 4.7,
4.8, 5.1.1(v) or 5.3. Summarised because a reviewer comparing builds will see
a large diff:

* **Minimum iOS lowered from 26 to 18.** The interface is drawn with the
  system's Liquid Glass materials where available and standard system
  materials below that. No private API is used for either.
* **Sign-in screen simplified** to Apple / email / one "continue another way"
  button — see GUIDELINE 4.8 below. Sign in with Apple is unchanged and still
  prominent.
* **Blocking, reporting and the blocked-user list** are unchanged in behaviour
  from the approved build; only the list's presentation moved.
* **Author-gated post sections** (reply-to-see / paid) are now drawn in an
  explanatory frame. Paid sections still offer **no** purchase control inside
  the app — see GUIDELINE 3.1.1.
* Performance work: the profile screen caches its last response on the device
  so it renders before the network answers. No new data is collected; see
  `PrivacyInfo.xcprivacy`.

---

## Paste from here

```
NodeLoc is the official iOS client for the community forum at
https://www.nodeloc.com (a Discourse installation). It provides reading,
posting, private messaging, real-time chat, and a directory of
community-built HTML5 mini games.

DEMO ACCOUNT
  Username: <<DEMO_USERNAME>>
  Password: <<DEMO_PASSWORD>>

Most content is readable without an account — tap "Browse as guest" on the
launch screen. An account is required to post, reply, chat, report content,
or enter a giveaway.

--------------------------------------------------------------------
GUIDELINE 1.2 — USER-GENERATED CONTENT
--------------------------------------------------------------------
IMPORTANT: reporting and blocking write to the server, so they need a
signed-in account. Please sign in with the demo account above first. (A
guest who taps either action is now shown the sign-in screen rather than
an error.)

Step by step, on the Home tab:

* TERMS (EULA), presented before registering or signing in:
  The launch screen offers "Log in" / "Sign up". Directly beneath those
  buttons it reads "By continuing, you agree to our Terms and acknowledge
  that you understand the Privacy Policy", where "Terms" and "Privacy
  Policy" are tappable and open in the app. Proceeding past that screen is
  agreement to the Terms. Section 7, "Content Standards and Zero-Tolerance
  Policy", states: "NodeLoc has zero tolerance for objectionable Content and
  abusive conduct, including harassment, threats, hate, and abuse." Section
  8, "Reporting, Blocking, and Content Moderation", describes the reporting
  and blocking features and the enforcement that follows.
    Terms:   https://www.nodeloc.com/tos
    Privacy: https://www.nodeloc.com/privacy
  Both are readable without an account, and are also in the sidebar.

* REPORTING objectionable content:
  1. Tap "..." at the top-right of any post in the feed.
  2. Tap "举报" (Report).
  3. Pick a reason and submit — it enters the staff moderation queue.
  The same action is on every individual reply ("..." on the reply), every
  chat message (long-press), and every mini game.

* BLOCKING an abusive user:
  1. Tap "..." at the top-right of any post in the feed.
  2. Tap "屏蔽作者" (Block author).
  3. Confirm "屏蔽并举报" (Block and report).
  On confirmation three things happen at once:
    - every topic and reply by that user disappears from the feed and from
      every other list instantly, with no refresh;
    - the content is reported to the moderators as a notify_moderators
      flag, which opens a staff message — so we are notified about it;
    - the block persists across launches and stops notifications from them.
  "Block author" is also on every reply, on every mini game, and on each
  user's profile under "通知方式" (Notification level) → "屏蔽" (Ignore).

* FILTERING: staff moderation plus automatic spam and flag handling on the
  server (the Discourse moderation queue).

--------------------------------------------------------------------
GUIDELINE 4.7 — MINI APPS / MINI GAMES
--------------------------------------------------------------------
The Apps tab lists HTML5/JavaScript mini games written by community
members. They are not embedded in the binary; they load from our server.

4.7.1 Filtering / reporting / blocking
  While a mini game is running, the "..." control in the top-right corner
  offers "About", "Report" and "Block author". Reports go to the standard
  moderation queue.

4.7.2 No native API exposure
  Each mini game runs inside an opaque-origin iframe within a server
  document. The app's WKWebView installs NO script message handlers, injects
  NO user scripts, and never calls evaluateJavaScript. There is no bridge of
  any kind between mini-game code and native APIs.

4.7.3 Per-instance consent
  Before a mini game runs for the FIRST time, the app shows the exact
  permission scopes the server granted it and requires explicit consent.
  Consent is recorded per game, so approving one does not approve others.

4.7.4 Index and universal links
  Index (human readable):    https://www.nodeloc.com/apps/directory
  Index (machine readable):  https://www.nodeloc.com/apps/directory.json
  Universal link per game:   https://www.nodeloc.com/apps/{slug}
  Opening such a link opens that game's page natively in the app.

4.7.5 Age restriction
  Mini games are gated behind a declared-age prompt. Users who declare an
  age below the app's age rating cannot launch any mini game. The declared
  year is stored on the device only and is never transmitted. All mini games
  currently offered are within the app's age rating.

--------------------------------------------------------------------
GUIDELINE 5.3 — GIVEAWAYS ("抽奖")
--------------------------------------------------------------------
Members can run community giveaways. This is an in-app points activity with
no real-world stakes:

* The app contains NO in-app purchases of any kind.
* The points used to enter ("energy") CANNOT be bought with money. They are
  earned only through free community activity — daily check-in, receiving
  likes, participating in discussions.
* Points cannot be converted into cash, physical goods, or any benefit
  outside the site.
* Prizes are restricted to on-site virtual items only — points, badges,
  titles, community roles. Cash, physical goods, and gift cards are
  prohibited by the site rules and enforced through moderation.
* If too few people enter, the draw is void and all points are refunded.

Official rules are presented in the app: open any giveaway card or the
giveaway composer and tap "抽奖规则" (Giveaway Rules). Those rules state
explicitly, in the user's language:

  "Apple is not a sponsor of this activity and is not involved in it in
   any manner."

--------------------------------------------------------------------
GUIDELINE 4.8 — LOGIN SERVICES
--------------------------------------------------------------------
Sign in with Apple is offered alongside the third-party providers, is live in
production, and uses the native AuthenticationServices control.

The sign-in sheet offers exactly three routes:

  1. Sign in with Apple (native, no web view)
  2. Email or username (entirely in-app)
  3. "Continue another way" — opens the site's own sign-in page in the system
     browser, where the third-party providers (Google, GitHub, X, Telegram)
     live

Route 3 is one neutral button rather than one button per provider because all
of them do the same thing: the flow opens Discourse's own login page, and that
page carries the provider buttons. Only Apple and email are distinct code
paths, which is why only those two are named.

The browser route deliberately uses the shared system browser session
(ASWebAuthenticationSession with prefersEphemeralWebBrowserSession = false), so
a reader already signed in to Google is offered their account rather than
having to type a password into a blank web view.

An emailed "login link" option is deliberately absent: the link Discourse
mails establishes a browser session, and the app adopts credentials from one
place only, so offering it would be a button that appears to work and doesn't.

--------------------------------------------------------------------
GUIDELINE 5.1.1(v) — ACCOUNT DELETION
--------------------------------------------------------------------
Settings → Account → "注销账号" (Delete Account). Where the server permits
self-service deletion it happens immediately in the app; otherwise the app
submits a deletion request to the moderation team and reports the outcome by
private message. Deletion is always initiated inside the app.

--------------------------------------------------------------------
BACKGROUND MODE
--------------------------------------------------------------------
The app declares the "fetch" background mode to poll for new notifications
via BGAppRefreshTask (identifier com.nodeloc.notification-refresh). There is
no other background activity.

--------------------------------------------------------------------
PRIVACY
--------------------------------------------------------------------
No advertising or analytics SDKs. Nothing is sold or shared. Data collected
is the forum account the user already has, plus the content they choose to
publish. One third-party request exists: GIF search sends the typed search
term to api.klipy.com with no account identifier attached. This is declared
in the privacy manifest and in the privacy questionnaire.
```

## Paste to here

---

# App Store Connect 里还要设置的（不在 Notes 里）

## 年龄分级问卷

必须如实回答，和 App 内的 17 岁门槛保持一致：

| 问题 | 回答 |
|---|---|
| **Contests** | **Yes** —— 会员发起的抽奖 |
| Unrestricted Web Access | **Yes** —— 有内置浏览器 |
| User Generated Content | **Yes** |
| Gambling | **No** —— 积分不可购买，奖品无现实价值 |
| Simulated Gambling | 若小游戏里有老虎机/扑克类玩法则 **Yes**，否则 No |

> `MiniAppGate.minimumAge` 目前是 **17**。如果最终分级不是 17+，要同步改这个常量，否则会出现「分级 12+ 但 App 内要求 17 岁」的不一致。

## 隐私问卷（要和 PrivacyInfo.xcprivacy 一致）

| 数据类型 | 关联到用户 | 用于追踪 | 说明 |
|---|---|---|---|
| Other User Content | 是 | 否 | 主题、回复、聊天、私信、个人简介／网站／所在地 |
| Photos or Videos | 是 | 否 | 用户上传的图片视频 |
| User ID | 是 | 否 | 论坛用户名 |
| Name | 是 | 否 | 昵称 |
| Email Address | 是 | 否 | 注册与找回密码 |
| **Search History** | **否** | 否 | **GIF 搜索词发给 api.klipy.com，不带账号标识** |

> 个人资料里的 `location` 是**自由文本字段**，不是设备定位。**不要**申报成 Location 类型 —— 申报错会造成隐私披露与实际不符，反而可能被拒。

## 截图

- iPhone 6.9" 必需
- **iPad 13" 必需**（`TARGETED_DEVICE_FAMILY = "1,2"`，Apple 会在 iPad 上审）
- 建议至少有一张 iPad 横屏图，展示固定侧边栏

## 提交前最后核对

- [x] ~~手动改 `CURRENT_PROJECT_VERSION`~~ —— **不用管**。分发时勾着 Organizer 的
      「Manage Version and Build Number」，Xcode 会查 ASC 已用的号并自动取下一个空号，
      同时把新号写回 `project.pbxproj`。**注意本地 archive 上的 build 号可能和 ASC 上的
      不一致**（2026-09-02 就出现过：archive 是 build 2，传上去被改成 3），要对应关系
      按上传时间或 dSYM UUID 匹配，别按号认。
      `MARKETING_VERSION`（用户可见的版本号）Xcode 不管，发新版本时自己改。
- [ ] 重新 Archive（改完代码必须重打；archive 里的 dSYM 是符号化的唯一来源）
- [x] AASA 文件已上线（2026-09-02 核实：`200`、`application/json`、0 重定向、appID 与 components 全对）
- [x] `/mobile/feature_flags.json` 已上线（2026-09-02 核实：`200`，两个 flag 都是 `true`）
- [x] ~~确认 `/payment/applications` 不涉及面向用户的付费~~ —— 已确认是开发者后台，OAuth／支付两个侧边栏入口已移除（Guideline 3.1.1 无暴露面）
- [ ] 填好上面 Notes 里的测试账号

---

## AGE_RATING — guideline 2.3.6

App Review could not find Parental Controls or Age Assurance because the app
has neither. Set both to **None** in App Store Connect → App Information →
Age Rating. This is a metadata change only; it needs no new build.

Do **not** claim Age Assurance on the strength of `MiniAppGate`. That gate
(`Core/FeatureFlags.swift`, `minimumAge = 17`) asks the reader to declare a
birth year before a mini game runs and stores it in `UserDefaults`. It is a
self-declaration, not verification or estimation, so it is not what Apple
means by Age Assurance — and claiming it would invite the same rejection.

Setting these two to None does not change the app's age rating, which comes
from the content descriptors. Leave the rating itself at 17+ so it continues
to match `MiniAppGate.minimumAge`.

## TERMS_WORDING — guideline 1.2 (done)

https://www.nodeloc.com/tos was rewritten on 2026-09-06 and now carries what
1.2 asks for. Verified against the live page:

* **§7 "Content Standards and Zero-Tolerance Policy"** — "NodeLoc has zero
  tolerance for objectionable Content and abusive conduct, including
  harassment, threats, hate, and abuse."
* **§8 "Reporting, Blocking, and Content Moderation"** — describes reporting
  to moderators, and states that "Once blocked, that user's topics and
  replies will be removed immediately from the relevant lists", which is
  what `BlockedUsersStore` now actually does. Worth knowing the terms and
  the app agree on this: a reviewer who reads §8 and then tries the app sees
  the same behaviour.

Readable anonymously (HTTP 200 with no session), so the reviewer can open it
straight from the sign-in screen.

One thing to be aware of, not a review issue: the page is served in English
regardless of `Accept-Language` (a zh-CN request returns the same English
text). That is ideal for App Review, but the app's own interface defaults to
zh-Hans, so Chinese-speaking members tapping 用户协议 also get English
terms. Worth a Chinese translation at some point for the actual user base.

## RECORDING_SCRIPT — the video App Review asked for

One continuous recording on a physical device, ~60 seconds, no cuts. Attach
it in App Review Information → Notes.

1. Launch the app from the Home screen (cold start).
2. On the launch screen, pause on the line beneath the sign-in buttons:
   "By continuing, you agree to our Terms…". Tap **Terms** — the Terms of
   Service opens in the app. Scroll to the no-tolerance clause. Go back.
3. Sign in with the demo account.
4. On the Home feed, tap **"..."** on any post → **举报 (Report)** → pick a
   reason → submit. Show the confirmation.
5. Tap **"..."** on a post by a different author → **屏蔽作者 (Block
   author)** → **屏蔽并举报 (Block and report)**.
6. Hold on the feed for two seconds without refreshing, so the recording
   shows that author's posts vanishing immediately.
7. Open a topic, tap **"..."** on an individual reply, and show that
   **举报** and **屏蔽作者** are there too.

## REPLY_TO_APP_REVIEW — paste into the Resolution Center thread

```
Thank you for the detailed review. We have addressed both items.

GUIDELINE 2.3.6 — AGE RATING
The app does not include Parental Controls or Age Assurance. We have
updated the Age Rating on the App Information page to select "None" for
both. (The app does ask a reader to confirm their age before running a
community mini game, but that is a self-declaration rather than age
verification or estimation, so we are not claiming Age Assurance.)

GUIDELINE 1.2 — USER-GENERATED CONTENT
All of the required precautions are in the app. We believe they could not
be located because reporting and blocking both write to our server and so
require a signed-in account, and our previous submission did not include a
working demo account. A verified demo account is now in the App Review
Information section, and a screen recording made on a physical device is
attached to the Notes field.

Where each mechanism is, after signing in with the demo account:

1. TERMS (EULA) — presented before registering or signing in. The launch
   screen shows, directly beneath the sign-in buttons, "By continuing, you
   agree to our Terms and acknowledge that you understand the Privacy
   Policy", with both documents tappable and readable in the app without an
   account. Section 7 of the Terms, "Content Standards and Zero-Tolerance
   Policy", states: "NodeLoc has zero tolerance for objectionable Content
   and abusive conduct, including harassment, threats, hate, and abuse."
   Section 8, "Reporting, Blocking, and Content Moderation", sets out the
   reporting and blocking features and the enforcement that follows.
   Terms: https://www.nodeloc.com/tos

2. FLAGGING OBJECTIONABLE CONTENT — tap "..." at the top right of any post
   in the feed, then "举报" (Report), choose a reason and submit. The report
   enters our staff moderation queue. The same action is on every reply, on
   every chat message, and on every mini game.

3. BLOCKING AN ABUSIVE USER — tap "..." on any post, then "屏蔽作者"
   (Block author), then confirm "屏蔽并举报" (Block and report). On
   confirmation:
     - all topics and replies by that user are removed from the reader's
       feed and every other list instantly, with no refresh;
     - the content is reported to our moderators, which notifies us;
     - the block persists across launches and stops notifications.
   Blocking is also available on each reply, on each mini game, and on any
   user's profile under "Notification level".

We also changed this build so that a guest who taps Report or Block is
shown the sign-in screen instead of an error, so the mechanisms are
reachable rather than only visible.

Please let us know if anything else would help.
```
