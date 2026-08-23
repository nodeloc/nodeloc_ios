# 02 · 设计系统（Nocturne 令牌）

来源：iOS `Components/Theme.swift`（其源头为 `design_import/rendered.html` 的 :root 覆盖块）。**逐值对齐**，不要用 Material 默认调色。

## 1. 核心色彩角色（light / dark）

| 令牌 | Light | Dark | 用途 |
|------|-------|------|------|
| bg | `#FFFFFF` | `#0B0F0E` | 页面背景 |
| surface | `#F7F7F7` | `#171C1A` | 卡片/分组面 |
| text | `#222222` | `#F1F4F2` | 主文本 |
| divider | `#222222` @12% | `#FFFFFF` @14% | 分隔线 |
| accent | `#009966` | `#26D99B` | 品牌绿（主强调） |
| accent2 | `#FF9933` | `#FFB15C` | 品牌橙（辅强调） |
| headerBg | `#FFFFFF` | `#0B0F0E` | 头部背景 |
| headerText | `#333333` | `#F1F4F2` | 头部文字/图标 |
| selected | `#CDFEEE` | `#133D31` | 选中底色 |
| hover | `#F2F2F2` | `#202624` | 按压/悬停底色 |
| highlight | `#FFFF4D` | `#D9C93F` | 高亮标记 |
| danger | `#C80001` | `#FF6B6B` | 危险/错误 |
| success | `#009900` | `#4ADB84` | 成功 |
| love | `#FA6C8D` | `#FF7A9A` | 点赞爱心 |

**muted 用法**：正文次级文字统一用 `text.opacity(pct)`，常用档位 0.28 / 0.35 / 0.4 / 0.45 / 0.5 / 0.55 / 0.62 / 0.72 / 0.88。Android 侧提供 `Color.muted(pct)` 扩展。

## 2. 中性/强调色阶

**Neutral（light / dark）**：100 `#FFFFFF/#F7FAF8`、200 `#F7F7F7/#EEF2EF`、300 `#F2F2F2/#232927`、400 `#E3E3E3/#343B38`、500 `#BDBDBD/#8B938F`、600 `#8F8F8F/#A6ADA9`、700 `#666666/#C4CBC7`、800 `#333333/#1D2320`、900 `#222222/#050807`。
**Accent**：100 `#CDFEEE/#D7FFF2`、200 `#A3F6DC/#9FF5D9`、300 `#6FE9C5`（两端同值）、400 `#3AD4A8/#42DDB1`、500 = accent、600 `#00875A/#55E2B0`、700 `#00714C/#7BEBC5`、800 `#005A3E/#064B38`、900 `#00402C/#033326`。
**Accent2**：100 `#FFE9CC/#FFE4BF`、500 = accent2、600 `#E37E1A/#FFC078`。

骨架屏占位统一 `neutral300`；图片占位为 `surface` 上的 45° 斜纹（StripePattern，条宽 8、步距 16、色 neutral400）。

## 3. 间距与圆角

| 令牌 | 值 (dp) |
|------|---------|
| space1–space8 | 2.8 / 5.6 / 8.4 / 11.2 / 16.8 / 22.4 |
| radiusSm / Md / Lg | 4 / 8 / 14 |
| 页面水平边距 | 16（信息流卡片内边距 14） |
| 设置卡片圆角 | 14，卡片距屏 16，行内边距 H16 V13 |
| 头部控件 | 图标 34dp 帽高，玻璃胶囊实际 48dp（34 + 上下 7 衬垫）——**头部所有控件按 48dp 对齐** |

## 4. 字体

系统字体（中文回退系统），两族用法：
- **heading(size, weight)**：标题族。常用 24/semibold（帖子标题）、25-26/bold（页面大标题）、32（设置页首）。
- **body(size, weight)**：正文族。基准：帖子正文 16（行距 6）、回复 14（行距 5）、元信息 11-12、按钮 13-15/semibold。
- 引用内嵌套降一级：`bodySize-2`，最小 12。

Android：`Typography` 中显式建 `heading()/body()` 帮助函数，**不接动态字体缩放**（与 iOS 一致，应用内"文本大小"偏好只同步服务器）。

## 5. 品牌加载动画（"The mark, loading" 规范）

11c 六边形标志几何，viewBox `23.4 20 84.2 94.5`：
- 六顶点：(65,25) (99.6,45) (99.6,85) (65,105) (30.4,85) (30.4,45)；中心 (65,65) r12。
- 六辐条（虚线 dash 4.4/3.2，宽 2.4）：(65,49→65,33)、(79.8,57.5→92.7,50.1)、(79.8,72.5→92.2,79.7)、(65,81→65,97)、(50.2,72.5→37.8,79.7)、(50.2,57.5→37.3,50.1)。外框线宽 2.6。
- 顶点节点半径（La/Lb）：5 / 6.5 / 8 / 9.5 / 7 / 5.5。

**运动铁律：不旋转、不弹跳、虚线相位不滚动**；加载感来自沿六边形的时序。

| 变体 | 关键帧 | 用途 |
|------|--------|------|
| **La Relay** | `nl-relay`：0%→12% 透明度 0.18→1，→38% 回 0.18；周期 1.8s linear，辐条+节点各延迟 i×0.3s | 内容加载默认 |
| **Lb Reach out** | 外框呼吸 0.55↔1（1.6s ease-in-out）；辐条 `nl-out`（0→22% 入、62% 持、88% 出）延迟 i×0.07s；节点再 +0.12s | 启动/品牌时刻 |
| **Lc Minimal** | 结构幽灵化（框 0.4、辐条 0.22、心 0.32），六等大点 r5 走 `nl-relay` 1.5s、延迟 i×0.25s | 小尺寸/下拉刷新/按钮内 |

尺寸降级（Lc）：≤30dp → 粗框(线宽4)+点 r7.5、无辐条无心；≤18dp → 仅六点 r11。
色板：深色地=框 `#00A870`/辐条 `#FF9933`/心 `#6FE9C5`/节点 [`#00875A`,`#00A870`,`#3AD4A8`,`#3AD4A8`,`#009966`,`#00A870`]；浅色地=框 `#009966`/辐条 `#E0771A`/心 `#00593B`/节点 [`#7CEBC4`,`#3AD4A8`,`#00714C`,`#00402C`,`#009966`,`#3AD4A8`]，Lc 点浅色地用 `#00593B`。
按钮内 loader 用 `currentColor`。**尊重"减弱动态"：静止满亮度**。

Android 实现：`Canvas` + `withInfiniteAnimation`/`rememberInfiniteTransition` 逐帧算透明度（关键帧分段函数照抄 iOS `NodelocLoader`）。

## 6. 组件库清单（core/design）

| 组件 | 规格要点 |
|------|----------|
| Avatar / RemoteAvatar | 圆形（或指定圆角），失败回退首字母+变体配色；游客态用灰色 person 图标 |
| HeaderIconButton | 34dp 图标帽 + 玻璃质感圆钮（Android 用 tonal surface + 阴影近似，见 06），阴影 black8% r9 y6 |
| GuestLoginButton | 与 HeaderIconButton 同质感的"登录"胶囊，五处游客入口共用 |
| SettingsSection/Row 族 | 分组卡 + Toggle/Picker(底部单选表)/Nav/Text/Multiline 行 |
| SkeletonLine + skeletonPulsing | 灰条(高13、圆角4、scaleX=widthFraction) + 0.55↔1 透明度 0.9s 往返脉冲，容器级挂一次保证同相位 |
| NodelocLoader | 上节规范 |
| PullToRefresh + 指示器 | 自定义下拉：阈值 72dp 越过即触发（轻触感），Lc 指示器随进度淡入放大(0.7→1)，刷新至少持续 0.6s |
| EmptyStateView | 图标+文案居中；断网态带"重试"按钮 |
| ToastCenter/Host | 顶部胶囊 toast，2.6s 自动消失，新消息顶替；只输出友好文案 |
| FlowLayout | 标签/胶囊流式布局（Compose `FlowRow`） |
| UserFlair / 头衔 chip | flair 可能是图片或 Font Awesome 图标名（映射表）；头衔支持 custom-badge 插件的样式 |

## 7. 视觉材质说明（玻璃 → Android）

iOS 大量使用 Liquid Glass（`.glass` 按钮、`glassEffect` 胶囊）。Android 没有等价系统材质，约定：
- 头部悬浮控件：`surface` 色 + 34% bg 蒙层近似 + 阴影（black 8%, blur 9, y 6），形状同为圆/胶囊；
- 按压反馈用 Material ripple 替代 glass 的 interactive 放大；
- **不要**尝试实时高斯模糊背景（性能不值），用半透明底色即可。
