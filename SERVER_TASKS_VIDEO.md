# 服务端待办 —— discourse-anyvideo 视频清晰度

iOS 客户端播放站内视频时画面明显模糊。**原因全在服务端的转码产物**,客户端已确认无可改之处(AVFoundation 没有"优先选最高变体"的 API：`preferredPeakBitRate` 只能设上限,`variantPreferences` 只管无损音频)。

有**两个独立问题**,第 2 个才是清晰度的上限。

测量对象(下文所有数据都来自这一条,2026-09-02):

```
sha1   f1023c30018e7c594db90e6c36a30bea0d4f73fc
源视频  720x1440(竖屏), 15 秒
接口   /anyvideo/videos/by_sha1/<sha1>.json  →  status: ready
```

---

## 问题 1【必须】master.m3u8 缺 RESOLUTION 和 CODECS

### 现状

`GET /plugins/discourse-anyvideo/videos/<sha1>/master.m3u8` 返回:

```
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=800000
360p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000
720p/index.m3u8
```

只有 `BANDWIDTH`。

### 为什么这是问题

AVPlayer 靠 `RESOLUTION` 把变体和屏幕尺寸对应起来。没有它,播放器只能从最保守的一档起播,再靠实测带宽往上切 —— 而站内多是十几秒的短片,**常常还没切上去就播完了**,全程停在最低档。

用 AVFoundation 直接读这个 playlist,可以看到它确实什么都不知道:

```
variants: 2
[0] peak=800000 avg=nil presentationSize=0x0 codecs=[]
[1] peak=2500000 avg=nil presentationSize=0x0 codecs=[]
```

`presentationSize=0x0`、`codecs=[]` —— 播放器手里没有任何可用于选档的信息。

### 需要改成

我把两个变体的实际参数解出来了(从 TS 分片里解 H.264 SPS),按这个补:

```
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=<实测均值>,RESOLUTION=180x364,CODECS="avc1.64000D,mp4a.40.2"
360p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,AVERAGE-BANDWIDTH=<实测均值>,RESOLUTION=360x720,CODECS="avc1.64001E,mp4a.40.2"
720p/index.m3u8
```

各字段的来源:

| 变体 | 实测分辨率 | H.264 | CODECS |
|---|---|---|---|
| `360p/` | **180x364** | High profile, level 1.3 | `avc1.64000D` |
| `720p/` | **360x720** | High profile, level 3.0 | `avc1.64001E` |

- 两档都含 AAC 音轨(TS 里有 ADTS 同步头),所以 CODECS 里要带 `mp4a.40.2`
- `avc1.` 后面是 `profile_idc + constraint_flags + level_idc` 的十六进制。**不要照抄上面的值** —— 不同片子 level 会变(这条 360p 是 0x0D、720p 是 0x1E)。请在生成 playlist 时从 ffprobe 结果里取:

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,profile,level \
  -of default=nw=1 <rendition>.m3u8
```

- `AVERAGE-BANDWIDTH` 是可选的,但 Apple 的 HLS 认证要求它,填上能让选档更准
- `RESOLUTION` 必须是该 rendition 的**真实**像素尺寸,不能按档位名字凑

---

## 问题 2【这才是清晰度的上限】转码档位远低于源视频

### 现状

| | 分辨率 | 像素数 |
|---|---|---|
| 源视频 | 720x1440 | 1,036,800 |
| 最高 rendition(`720p/`) | **360x720** | 259,200 |

**最高档只有源视频的 1/4 像素。** 那个叫 `720p` 的目录里装的其实是 360x720。

### 为什么问题 1 修完还是会模糊

现代 iPhone 竖屏约 1179x2556 物理像素。把 360x720 铺满屏幕要放大约 3.5 倍 —— 这跟播放器选哪一档无关,**素材本身就没有那么多信息**。

所以:

- 只修问题 1 → 起播就是 360x720 而不是 180x364,**清晰度翻倍**,是真实改善
- 但要真正清楚,必须**加一档接近源分辨率的 rendition**

### 建议的档位阶梯

竖屏源按长边命名(和现有 `720p` = 720 长边的口径一致):

```
360p    →   180x360    (弱网保底)
720p    →   360x720    (现有最高档)
1080p   →   540x1080
源分辨率 →   720x1440   ← 新增,不放大只做直通或轻度重编码
```

关键是**顶档不要低于源分辨率**。ffmpeg 侧用 `scale` 时加 `'min(iw,720)'` 这类保护,别把 720x1440 的源硬压到 360x720。

---

## 改完怎么验证

```bash
SHA=f1023c30018e7c594db90e6c36a30bea0d4f73fc
curl -s https://www.nodeloc.com/plugins/discourse-anyvideo/videos/$SHA/master.m3u8
```

期望每行 `#EXT-X-STREAM-INF` 都带 `RESOLUTION=` 和 `CODECS=`,且顶档的 `RESOLUTION` 等于 `by_sha1` 里报的 `width`x`height`。

想确认 AVPlayer 这边真的读到了,可以跑这段(macOS 上 `swiftc` 直接编译):

```swift
import AVFoundation
let asset = AVURLAsset(url: URL(string: "https://www.nodeloc.com/plugins/discourse-anyvideo/videos/<sha1>/master.m3u8")!)
for v in try await asset.load(.variants) {
    print(v.videoAttributes?.presentationSize ?? "UNKNOWN", v.peakBitRate ?? -1)
}
```

修好后应打印真实尺寸,而不是当前的 `(0.0, 0.0)`。

---

## 不用改的部分(已确认正常)

- `by_sha1` 接口:200,`status: ready`,`hls_url` 正确
- HLS 分发链路:`master.m3u8` → `<档位>/index.m3u8` → `segment000.ts` 全部 200/206,MIME 分别是 `application/vnd.apple.mpegurl` 和 `video/mp2t`,匿名可取
- `thumbnail_url`:200,`image/jpeg`(客户端已用它做聊天气泡的封面图)

> 顺带一个已知事实,不用处理但值得知道:转码完成后**原始上传文件会 404**(`/uploads/default/original/3X/…/<sha1>.mp4`)。客户端已经全部改走 HLS,不再依赖原文件。
