# 04 · API 集成（Discourse @ nodeloc.com）

Base URL `https://www.nodeloc.com`。JSON 一律 snake_case（kotlinx.serialization 配 naming 策略）。**响应字段类型以 07 的怪癖清单为准，不要盲信 Discourse 文档**。

## 1. 认证体系

两种模式并存，二选一生效：

### A. 网站会话（帐密登录）
1. `GET /session/csrf.json` → csrf token（后续 POST 全带 `X-CSRF-Token`）。
2. `POST /session`（form：login、password、timezone、second_factor_method=1）。**HTTP 恒 200，结果看 body**：`error/failed` 字段 = 失败；`reason=="invalid_second_factor"` = 需要二步验证（未带码时提示输码；带码仍此值 = 码错）；`user.username` 出现 = 成功。
3. 2FA 重试：追加 `second_factor_token` + `second_factor_method`（1=TOTP，2=备用码）。
4. **Cookie 管理（血泪教训）**：`_t` 认证 cookie 会**定期轮换**。**必须**依赖 OkHttp CookieJar 自动收发（PersistentCookieJar 落盘），**绝不允许**把登录时的 Cookie 拍快照钉成固定请求头——那会在宽限期后全线 `not_logged_in`。退后台时持久化 jar 即可。
5. 会话模式请求头：`X-CSRF-Token`、`X-Requested-With: XMLHttpRequest`、`Discourse-Present: true`、`Origin`/`Referer` = base。

### B. User API Key（网站 OAuth）
Custom Tab 走 `/user-api-key/new`（application_name、client_id=安装期 UUID、scopes、RSA public_key、nonce、auth_redirect=`nodeloc://auth`），回调 payload 用私钥解密得 key。请求头 `User-Api-Key` + `User-Api-Client-Id`。**不轮换**，无 CSRF 要求。
前置条件：站点管理端已配置 redirect 白名单（沿用 iOS 已配好的 `nodeloc://auth`）。

### 注册
`POST /users`（form：username/name/email/password/timezone + csrf）。响应 `active==true` → 直接转登录；否则邮件激活链接（**没有 6 位验证码**）。辅助接口：`GET /u/check_username.json?username=` → `{available, suggestion}`。

## 2. 端点目录（iOS DiscourseClient 全集）

### 读取（公开）
| 端点 | 用途 |
|------|------|
| `GET /latest.json?page=` | 首页信息流（含 users 数组供作者头像） |
| `GET /site.json` | 站点元数据（categories 全量、trust levels 等，会话级缓存） |
| `GET /categories.json?include_subcategories=true` | 分类树（**节点=子分类**，parent_category_id != null） |
| `GET /c/{parentSlug}/{childSlug}/{id}/l/{sort}.json?page=` | 节点话题列表（sort: latest/top/new…） |
| `GET /t/{id}.json` | 话题（平铺楼层） |
| `GET /n/{slug}/{id}.json?sort=&page=` | **嵌套回复视图**（discourse-community；slug 任意占位） |
| `GET /n/{slug}/{id}/children/{postNumber}.json?sort=&page=` | 某楼层的更多直接回复 |
| `GET /t/{id}/posts.json?post_ids[]=` | 按 id 批量取楼层 |
| `GET /search.json?q=` | 搜索（一次返回 topics/posts/users/categories） |
| `GET /u/{username}.json`、`/u/{username}/summary.json` | 资料/汇总 |
| `GET /user_actions.json?username=&filter=&offset=` | 活动流（filter：1赞 3书签 4主题 5回复） |
| `GET /nodes.json`、`/node/browse/{parentId}.json?page=&per_page=`、`/node/recently-visited.json`、`/custom-feeds.json`、`/node/check-slug?slug=` | 节点目录族 |
| `GET /apps/directory.json`（裸数组！）、`/apps/{slug}.json` | 应用目录 |
| `GET /discourse_custom_badge/group-styles/list`、`/badge-styles/list` | 头衔样式 |
| `GET /u/{username}/points-history.json?page=`、`/points-scores.json` | 能量 |
| `GET /user-badges/{username}.json` | 徽章 |

### 认证读取
`GET /session/current.json`（**未登录返回 404**）、`/notifications.json`、`/topics/private-messages/{user}.json`、`/topics/private-messages-group/{user}/{group}.json`。

### 写入（form-encoded，带 CSRF）
| 端点 | 说明 |
|------|------|
| `POST /posts` | 发主题（title/raw/category/archetype=regular）或回复（raw/topic_id/reply_to_post_number）→ 返回 post（topic_id 供红包等二段调用） |
| `POST /post_actions` (id, post_action_type_id=2, flag_topic=false) / `DELETE /post_actions/{id}` | 赞/取消赞 |
| `POST /bookmarks` (bookmarkable_id, bookmarkable_type=Post) | 书签 |
| `PUT /notifications/mark-read` | 通知全读 |
| `POST /topics/timings` (topic_id, topic_time, timings[postNumber]=ms) | 阅读进度 |
| `POST /node/join/{categoryId}` / `DELETE /node/leave/{categoryId}` | 加入/退出节点 |
| `POST /category/{id}/notifications` (notification_level) | 节点通知级别（0-4，**403 BAD CSRF 若缺 token**） |
| `POST /node/create` (name/description/slug/parent_category_id/color) | 建节点 |
| `POST /node/repost` (topic_id/category_id/title) | 转发 |
| `POST /reward/give` (post_id/amount/note?) | 打赏 |
| `PUT /polls/vote`（**有序重复键** options[]=a&options[]=b）/ `DELETE /polls/vote` | 投票 |
| `POST /lottery/{id}/participate` (quantity/random)；`POST /lottery`（**JSON body**，嵌套 levels 数组） | 抽奖 |
| `POST /red-envelopes.json` (topic_id/total_points/total_count) | 红包（发帖后的第二请求） |
| `PUT/DELETE /follow/{username}` | 关注 |
| `PUT /u/{username}.json`（formItems 有序重复键） | 资料/偏好更新（users#update，需 CSRF） |
| `POST /uploads.json`（multipart：file + upload_type[composer/avatar/thumbnail…] + synchronous=true） | 上传；**视频封面必须命名 `{videoSHA1}.png`**（服务器按文件名关联） |
| `PUT /u/{u}/preferences/avatar/pick` (upload_id/type) | 选头像 |
| 安全族：`POST /u/confirm-session`、`GET /u/trusted-session`、`POST /u/second_factors`、`/u/create_second_factor_totp`、`/u/enable_second_factor_totp`、`PUT /u/disable_second_factor`、`PUT /u/second_factors_backup`、`POST /u/{u}/preferences/revoke-auth-token`、`/revoke-account`、`POST /session/forgot_password` | 2FA/会话/关联账户 |

### 聊天（chat 插件）
| 端点 | 说明 |
|------|------|
| `GET /chat/api/me/channels.json`（404 时回退 `/chat/api/channels.json`） | 频道列表+tracking |
| `GET /chat/api/channels/{id}/messages.json?page_size=50&fetch_from_last_read=true`（或 target_message_id=） | 消息页 |
| `GET /chat/api/channels/{id}/threads.json?limit≤10&offset=`、`/me/threads.json`、`/threads/{tid}/messages.json` | 讨论串 |
| `GET /chat/api/search.json?query=&limit≤40&offset=&sort=&exclude_threads=` | 聊天搜索 |
| `POST /chat/{channelId}.json` (message, thread_id?) | 发消息 |
| `PUT /chat/api/channels/{id}/read?message_id=` | 已读上报 |

### 外部
Klipy GIF 搜索：`GET https://api.klipy.com/v2/search?key=&q=&media_filter=gif&limit=24&pos=`。

## 3. MessageBus 实时协议（web 同款）

- `POST /message-bus/{clientUUID}/poll`，form body：`{busChannel: lastSeenId}`，如 `/chat/123=-1`。`-1` = 只要新事件。服务器挂住 ~25s（长轮询）。
- 响应：事件数组 `{global_id, message_id, channel, data}`。`/__status` 事件的 data 是 `{channel: currentId}`，用于校准 -1 订阅。
- **实现策略**：事件只当"该频道变了"的信号，收到后重拉最新页（复用现有映射），不解析事件 payload——一次廉价请求换永远一致。
- 错误退避 4s；每收事件更新 position；页面级生命周期。

## 4. 错误处理规范（用户可见文案）

`DiscourseError` 对应的 Kotlin sealed class + 统一映射，**UI 永不显示状态码/技术细节**：

| 条件 | 文案 |
|------|------|
| 401/403 | 没有权限或登录已失效，请重新登录后再试 |
| 404 | 内容不存在或已被删除 |
| 429 | 操作太频繁，请稍后再试 |
| 5xx | 服务器开小差了，请稍后再试 |
| Cloudflare 拦截（`cf-mitigated` 头，或 403+`server: cloudflare`+HTML body） | 请求被站点安全防护拦截，请稍后再试（独立类型 `Challenged`） |
| 断网（UnknownHost/ConnectException 等） | 网络不可用，请检查网络连接（`isOffline` 供空态判断） |
| 超时 | 连接超时，请稍后重试 |
| 解析失败 | 数据加载出错，请稍后重试 |

Debug 构建打印完整诊断（状态码/URL/server/cf-ray/body 前 200 字节）——iOS 靠它抓过会话轮换与 CF 误判。

## 5. 推送（轮询式本地通知）

无 FCM 服务端中继（Discourse 只给官方 App 推）。方案与 iOS 对齐：
- WorkManager 周期任务（15min，网络约束）拉 `notifications.json`；
- 水位线 `lastSeenId` 持久化，**首次轮询只建基线不弹**；每次推进到本次最大 id（含被过滤类型，防积压）；
- 单批最多弹 5 条，按通知分类过滤（回复与提及[1,2,3,9,15]/点赞[5]/私信[6,7]/其他），文案与站内 `NotificationFormatter` 同源；
- 点击深链：topic → 阅读器（带楼层号）、chat → 会话、badge/群组 → 内置浏览器；
- 前台回到应用清除已展示通知。
- Android 侧需要 `POST_NOTIFICATIONS` 运行时权限 + 通知渠道（按分类建 4 个 channel，让系统层也可各自静音）。
