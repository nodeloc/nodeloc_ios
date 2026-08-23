# 03 · 架构

## 1. 分层

```
UI (Compose Screen)  ←  ViewModel(StateFlow)  ←  Repository/Store  ←  DiscourseClient(Retrofit/OkHttp)
                                                  ↑
                          文件缓存(JSON 快照/图片) + DataStore(偏好/水位线)
```

iOS 对应关系：`@Observable` Store ↔ ViewModel + StateFlow；`@State` 单页状态 ↔ `remember`/ViewModel 字段。

## 2. Store 清单（与 iOS 一一对应）

| iOS Store | 职责 | Android 形态 |
|-----------|------|--------------|
| FeedStore | 首页 latest 分页、TopicListItem→Post 映射（FeedMapper 共享给节点列表） | FeedRepository + FeedViewModel |
| TopicStore | 阅读器全量：嵌套树加载/加载更多子回复、点赞/书签/回复/打赏/转发、投票/抽奖/红包、解析缓存 | TopicRepository + ReaderViewModel |
| TopicReadTracker | 阅读进度：每秒 tick 给可见楼层计时，每 10s flush `topics/timings` | ReaderViewModel 内协程心跳 |
| MessageCenterStore（单例） | 消息 Tab 徽标 + 通知/私信/群组/聊天列表 | 单例 MessageCenterRepository |
| ChatConversationStore | 会话：快照缓存优先 + 网络对账 + MessageBus 实时 + 发送轻刷新 | ChatViewModel |
| SearchStore | 一次 search.json 出四组结果（帖/用户/节点）+ 应用目录本地过滤 | SearchViewModel |
| ProfileStore（单例） | 自己的资料（跨 Tab 保活，防止切页重置） | 单例 ProfileRepository |
| PublicProfileStore | 他人资料 | ViewModel |
| NodeDetailStore / NodeCatalog | 节点详情/slug 解析目录 | Repository |
| NodeReadingModeStore（单例） | 阅读模式：**本机选择 > 账户偏好(community_view_mode) > 默认紧凑**，本机持久化 | DataStore 支持的单例 |
| UserPreferencesStore | 账户偏好整包（user_option）读写 | Repository |
| ProfileTabAvatarStore（单例） | 当前用户头像，供 Tab 栏与阅读器头像共用（**只拉一次 currentUser**） | 单例 |
| SiteResources | site.json / categories.json 会话级缓存 + 请求合并 | 单例，Mutex 合并并发 |
| PushNotificationService | 推送轮询/水位线/分类过滤/深链 | WorkManager Worker + Repository |
| ToastCenter（单例） | 全局操作失败提示 | 单例 + 根部 Host |

## 3. 缓存架构（无数据库，刻意决定）

1. **图片**：Coil 内存+磁盘缓存；**按显示尺寸请求解码**（对位 iOS 的 maxPixel 下采样与"≥所需尺寸命中"策略）；responsive variants：`PostMedia.bestURL(宽×density)` 从 srcset 变体里选最小够用的。
2. **聊天快照**：`cacheDir/ChatMessages/channel-{id}.json` 存**服务器原始响应 JSON**（同一解码路径回放），打开会话先渲染快照再网络对账；发送/实时事件后用最新页替换并回写。
3. **帖子解析缓存**：cooked→块树的解析结果内存 LRU（keyed by post id+updatedAt）。
4. **会话级 JSON**：site/categories 等仅内存。
5. **偏好/水位线**：DataStore——阅读模式、推送开关与分类、推送已见最大通知 id、待激活的兴趣节点 id 列表、搜索历史。
6. 全部缓存放 `cacheDir`（系统可清），偏好放 DataStore。**不要引入 Room**。

## 4. 并发模型

- Repository 挂 `Dispatchers.IO`；HTML 解析在 `Dispatchers.Default`（**注意默认线程栈小，解析器必须带深度熔断**，见 07）。
- MessageBus 长轮询：会话页生命周期内的协程 loop（`viewModelScope`），错误退避 4s；离开页面取消。
- 推送轮询：WorkManager 周期任务（15min 起），约束 network；应用前台时不弹（进入前台清除已展示通知并校准水位线由"首次轮询只建基线"策略覆盖）。
- 乐观更新模式：点赞/收藏先改 UI，失败回滚 + Toast（文案见 04 错误规范）。

## 5. 状态与错误呈现总则

- 列表三态：骨架（首载）/ 内容 / 空态（区分"暂无内容"与"网络不可用+重试"）。
- 用户主动操作失败：**永不静默**——Toast 友好文案；成功有意义时也提示（如"已保存书签"）。
- 后台/衍生请求失败：静默保留现状，等下次机会对账。
