# NODELOC Android — 设计规划文档

以现有 iOS 应用（SwiftUI，`nodeloc/`）为蓝本，为 Android 版本制定的完整设计与实现规划。iOS 版是行为基准：凡未特别说明处，Android 与 iOS 行为一致。

| 文档 | 内容 |
|------|------|
| [01-overview.md](01-overview.md) | 产品概述、功能清单、技术栈选型、模块划分 |
| [02-design-system.md](02-design-system.md) | 设计令牌（颜色/字体/间距/圆角，与 iOS 逐值对齐）、品牌加载动画规范、组件库清单 |
| [03-architecture.md](03-architecture.md) | 分层架构、状态管理、缓存策略、并发模型 |
| [04-api-integration.md](04-api-integration.md) | Discourse + 插件全部接口目录、认证体系、MessageBus 实时协议、错误处理规范 |
| [05-screens.md](05-screens.md) | 全部页面的逐屏规格（布局、交互、状态、边界情况） |
| [06-platform-mapping.md](06-platform-mapping.md) | iOS 概念 → Android 对应实现的决策表 |
| [07-pitfalls.md](07-pitfalls.md) | iOS 版踩过的坑（后端怪癖、性能陷阱），Android 必读 |
| [08-roadmap.md](08-roadmap.md) | 分阶段交付计划与验收标准 |

## 基本事实

- **后端**：nodeloc.com，Discourse + 多个自研插件（discourse-community 节点、reward 打赏、lottery 抽奖、red-envelope 红包、points 能量、follow 关注、custom-badge 头衔样式、apps 应用目录、gifs 图床）。阅读公开（`login_required=false`），写操作需认证。
- **语言**：简体中文为主、英文为辅（双语，String Catalog 对应 Android 的 `values-zh-rCN`/`values`）。
- **设计语言**：自研 "Nocturne" 令牌体系（非 Material 默认色），交互范式大量参考 Reddit（信息流/帖子树）与 Telegram（聊天/搜索/看图）。
- **明确的架构决定**：**不引入数据库**——所有缓存是内存 + 磁盘 JSON/图片文件（详见 03 与 07）。
