# 06 · iOS → Android 平台映射决策

| iOS 现状 | Android 决策 | 说明 |
|----------|--------------|------|
| SwiftUI + @Observable | Compose + ViewModel/StateFlow | 单例 Store → @Singleton Repository |
| 自绘 overlay 体系（app.overlay 枚举） | Navigation Compose 目的地 + 全屏 dialog 目的地 | 阅读器/设置/撰写=目的地；打赏/更多菜单=ModalBottomSheet |
| Liquid Glass 悬浮 Tab 栏 + `Tab(role:.search)` 搜索胶囊 + `.searchable` 变形 | **NavigationBar(5 项) + 搜索 Tab 内常驻 SearchBar** | Android 无"栏变形为搜索框"的系统机制；搜索作为普通 Tab，顶部 Material SearchBar + scope ChipRow。iOS 在这里踩过整整一轮命中测试大坑（07），Android 方案天然无此问题 |
| `.glass` 玻璃按钮/胶囊 | surface 色 + 34% bg 蒙层 + 阴影(black8%, r9, y6) + ripple | 不做实时模糊 |
| fullScreenCover + presentationBackground(.clear)（看图） | 透明主题全屏 Dialog 或共享元素目的地 | 下拉退出手势自实现（Modifier.pointerInput） |
| matchedGeometryEffect（卡片→阅读器过渡） | Compose 1.7+ SharedTransitionLayout | 降级方案：淡入+圆角过渡 |
| BGAppRefreshTask + UNUserNotificationCenter | WorkManager 周期任务 + NotificationManager（4 个分类 channel） | 首启建水位线基线；POST_NOTIFICATIONS 运行时权限 |
| ASWebAuthenticationSession（OAuth） | Custom Tabs + `nodeloc://auth` intent-filter | RSA 解密 payload 逻辑照抄 |
| Keychain | EncryptedSharedPreferences / Keystore | 存 User API Key、用户名；**会话 cookie 交给持久化 CookieJar** |
| URLSession cookie jar | OkHttp CookieJar（持久化实现） | **必须**，见 07 `_t` 轮换 |
| 自定义 PullToRefresh（72dp 越过即触发） | 同规格自实现（nestedScroll） | Material PullToRefreshBox 换不了指示器动画时序，自实现对齐手感 |
| onScrollVisibilityChange（阅读计时/哨兵） | LazyListState 可见项监听 | 50% 阈值语义照搬 |
| WKWebView + KVO(scrollView) | WebView + OnScrollChangeListener | 浏览器镶边显隐/进度胶囊同规格 |
| `.oneTimeCode`/`.newPassword` 内容类型 | Autofill hints：smsOTPCode / newPassword | 触发密码管理器与验证码自动填充 |
| String Catalog（zh-Hans 键 + en 译文） | `values/`(en) + `values-zh-rCN/` | 以中文为源串抽 key；两端文案表共享一份术语表 |
| Info.plist UILaunchScreen（色+字标） | themed SplashScreen API（windowSplashScreenBackground + 品牌图） | 深浅双色与 Theme.bg 一致 |
| 减弱动态 accessibilityReduceMotion | `Settings.Global.ANIMATOR_DURATION_SCALE==0` 或 removeAnimations 无障碍 | 加载器静止满亮度 |
| Haptics(UIImpactFeedbackGenerator light) | View.performHapticFeedback(CONTEXT_CLICK) | 下拉触发、折叠等 |
| GIF：UIImageView 多帧 | Coil GIF decoder | — |
| 视频信息流自动播放 | Media3 + LazyList 可见性驱动播放/静音全局态 | 全局静音单例同 iOS |

## 需要产品确认的平台差异

1. **返回手势**：Android 系统返回应逐级退出（阅读器→列表→…）；iOS 靠 X/边缘滑动。规划：全部目的地接 predictive back。
2. **搜索 Tab 再点击**：Android 惯例 = 聚焦输入框；无 iOS 的"胶囊变形"。
3. 底部导航在滚动时是否隐藏（iOS tabBarMinimizeBehavior）：建议 Android 不隐藏（Material 惯例），仅阅读器全屏无栏。
