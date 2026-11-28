//
//  ComposerEmojiSheet.swift
//  nodeloc
//
//  The emoji panel that takes the keyboard's place under every input (the
//  topic composer, the reply bar, chat): one scrolling list — recents, the
//  site's packs, a built-in Unicode set and 颜文字 — with section tabs and ⌫
//  along the bottom.
//

import SwiftUI

// MARK: - What a pick inserts

/// One thing the panel can put into a draft.
///
/// Three kinds because each travels differently: a site emoji is text the
/// server cooks into an image (`:code:`), a Unicode emoji is just a character,
/// and a 颜文字 is plain text. `Codable` so recents can be stored as-is.
enum ComposerEmojiPick: Hashable, Codable {
    case site(code: String)
    case character(String)
    case kaomoji(String)
}

// MARK: - Recents

/// The last picks, newest first, kept on the device.
///
/// 颜文字 aren't recorded: they are phrases, and a row of them would crowd out
/// the emoji the section is for.
enum ComposerEmojiRecents {
    static let limit = 14
    private static let key = "composer.emojiRecents"

    static func load() -> [ComposerEmojiPick] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let picks = try? JSONDecoder().decode([ComposerEmojiPick].self, from: data)
        else { return [] }
        return picks
    }

    static func record(_ pick: ComposerEmojiPick) {
        if case .kaomoji = pick { return }
        let picks = Array(([pick] + load().filter { $0 != pick }).prefix(limit))
        if let data = try? JSONEncoder().encode(picks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Built-in sets

/// A Unicode group. Names are the search terms (space-separated synonyms).
private struct UnicodeGroup {
    let id: String
    let title: String
    let tab: String
    let items: [(String, String)]
}

private enum BuiltInEmoji {
    static let groups: [UnicodeGroup] = [
        UnicodeGroup(id: "smile", title: "笑脸", tab: "😀", items: [
            ("😀", "嘿嘿"), ("😃", "哈哈"), ("😄", "大笑"), ("😁", "露齿笑"), ("😆", "斜眼笑"), ("😅", "苦笑 尴尬"), ("🤣", "笑得打滚"), ("😂", "笑哭"), ("🙂", "微笑"), ("😉", "眨眼"), ("😊", "羞涩微笑"), ("😇", "天使"), ("🥰", "喜欢"), ("😍", "花痴"), ("😘", "飞吻"), ("😋", "好吃"), ("😜", "调皮"), ("🤔", "思考"), ("🤨", "质疑"), ("😐", "面无表情"), ("😑", "无语"), ("😏", "得意"), ("😒", "不屑"), ("🙄", "翻白眼"), ("😬", "龇牙"), ("😴", "睡着"), ("😷", "口罩"), ("🤯", "爆炸"), ("😎", "酷"), ("🥺", "求求"), ("😢", "流泪"), ("😭", "大哭"), ("😱", "吓死"), ("😤", "生气"), ("😡", "愤怒"), ("🤡", "小丑"), ("💀", "骷髅 笑死"), ("👻", "鬼"), ("🤖", "机器人"), ("💩", "便便")
        ]),
        UnicodeGroup(id: "hand", title: "手势", tab: "👍", items: [
            ("👍", "赞 点赞"), ("👎", "踩"), ("👏", "鼓掌"), ("🙌", "举手欢呼"), ("🙏", "拜托 谢谢"), ("🤝", "握手"), ("👌", "好的"), ("✌️", "胜利"), ("🤞", "好运"), ("🤟", "爱你"), ("🤘", "摇滚"), ("👊", "拳头"), ("✊", "加油"), ("💪", "肌肉"), ("👋", "挥手 你好"), ("🫡", "敬礼"), ("🫶", "比心"), ("👀", "看看 围观"), ("🧠", "大脑"), ("🙋", "举手提问"), ("🤷", "不知道"), ("🤦", "捂脸"), ("🙇", "鞠躬"), ("💃", "跳舞")
        ]),
        UnicodeGroup(id: "nature", title: "动物与自然", tab: "🐱", items: [
            ("🐶", "狗"), ("🐱", "猫"), ("🐭", "鼠"), ("🐹", "仓鼠"), ("🐰", "兔"), ("🦊", "狐狸"), ("🐻", "熊"), ("🐼", "熊猫"), ("🐨", "考拉"), ("🐯", "虎"), ("🦁", "狮"), ("🐮", "牛"), ("🐷", "猪"), ("🐸", "青蛙"), ("🐵", "猴"), ("🐔", "鸡"), ("🐧", "企鹅"), ("🦄", "独角兽"), ("🐟", "鱼"), ("🐳", "鲸"), ("🌸", "樱花"), ("🌱", "幼苗"), ("🍀", "四叶草"), ("🔥", "火 热门"), ("⭐", "星"), ("🌈", "彩虹"), ("☀️", "太阳"), ("🌙", "月亮"), ("⚡", "闪电"), ("❄️", "雪"), ("💧", "水滴"), ("🌊", "海浪")
        ]),
        UnicodeGroup(id: "food", title: "食物", tab: "🍜", items: [
            ("🍎", "苹果"), ("🍉", "西瓜 吃瓜"), ("🍊", "橘子"), ("🍋", "柠檬 酸"), ("🍌", "香蕉"), ("🍇", "葡萄"), ("🍓", "草莓"), ("🍑", "桃子"), ("🍜", "拉面"), ("🍚", "米饭"), ("🍙", "饭团"), ("🍣", "寿司"), ("🥟", "饺子"), ("🍔", "汉堡"), ("🍕", "披萨"), ("🍟", "薯条"), ("🍰", "蛋糕"), ("🍩", "甜甜圈"), ("🍪", "饼干"), ("🍫", "巧克力"), ("🍺", "啤酒"), ("🍻", "干杯"), ("☕", "咖啡"), ("🍵", "茶")
        ]),
        UnicodeGroup(id: "play", title: "活动与旅行", tab: "🎮", items: [
            ("⚽", "足球"), ("🏀", "篮球"), ("🎮", "游戏"), ("🎲", "骰子"), ("🎯", "靶心"), ("🎸", "吉他"), ("🎧", "耳机"), ("🎬", "电影"), ("🎨", "画画"), ("📷", "相机"), ("🎉", "庆祝 恭喜"), ("🎁", "礼物"), ("🏆", "奖杯"), ("🥇", "金牌"), ("🚀", "火箭 上线"), ("✈️", "飞机"), ("🚗", "汽车"), ("🚲", "自行车"), ("🏠", "家"), ("🏔️", "雪山"), ("🏖️", "海滩"), ("🗺️", "地图"), ("⛺", "露营"), ("🧧", "红包")
        ]),
        UnicodeGroup(id: "object", title: "物品", tab: "💡", items: [
            ("💡", "灯泡 想法"), ("💻", "电脑"), ("📱", "手机"), ("⌨️", "键盘"), ("🖥️", "显示器"), ("🔋", "电池"), ("🔌", "插头"), ("💾", "存盘"), ("📦", "包裹"), ("📌", "图钉"), ("📎", "回形针"), ("✏️", "铅笔"), ("📚", "书"), ("📈", "上涨"), ("📉", "下跌"), ("💰", "钱袋"), ("💳", "银行卡"), ("🔑", "钥匙"), ("🔒", "锁"), ("🔔", "铃铛"), ("⏰", "闹钟"), ("🛠️", "工具"), ("🧪", "试管"), ("🧲", "磁铁")
        ]),
        UnicodeGroup(id: "symbol", title: "符号", tab: "❤️", items: [
            ("❤️", "红心 爱"), ("🧡", "橙心"), ("💛", "黄心"), ("💚", "绿心"), ("💙", "蓝心"), ("💜", "紫心"), ("🖤", "黑心"), ("💔", "心碎"), ("✅", "对勾 完成"), ("❌", "叉 错"), ("⭕", "圈"), ("❓", "问号"), ("❗", "感叹号"), ("💯", "满分"), ("➕", "加"), ("➖", "减"), ("♻️", "回收"), ("⚠️", "警告"), ("🚫", "禁止"), ("🆗", "OK"), ("🆕", "NEW"), ("🔝", "TOP 置顶"), ("💤", "睡觉"), ("💬", "对话")
        ]),
    ]

    static let kaomoji: [(String, String)] = [
        ("(｡･ω･｡)", "卖萌"), ("(≧▽≦)", "开心"), ("(｀・ω・´)", "认真"), ("(´；ω；`)", "哭"),
        ("(・_・;)", "汗"), ("(￣▽￣)ノ", "你好"), ("( •̀ ω •́ )✧", "自信"), ("(=^･ω･^=)", "猫"),
        ("(｡•́︿•̀｡)", "委屈"), ("ヾ(•ω•`)o", "再见"), ("¯\\_(ツ)_/¯", "摊手"), ("(づ｡◕‿‿◕｡)づ", "抱抱"),
        ("(╯°□°）╯︵ ┻━┻", "掀桌"), ("┬─┬ノ( º _ ºノ)", "摆好"), ("orz", "失意"),
    ]

    /// The group titles, localised here because the table above is data.
    static func title(for id: String) -> String {
        switch id {
        case "smile": AppString("笑脸")
        case "hand": AppString("手势")
        case "nature": AppString("动物与自然")
        case "food": AppString("食物")
        case "play": AppString("活动与旅行")
        case "object": AppString("物品")
        case "symbol": AppString("符号")
        default: id
        }
    }
}

// MARK: - Panel

/// The emoji panel, in the keyboard's place under the input (it is the
/// editor's `inputView`): recents, the site's packs, the Unicode groups and
/// 颜文字 in one scrolling list, the section tabs and ⌫ along the bottom
/// where a thumb reaches them. A pick goes straight in and the panel stays.
struct ComposerEmojiPanel: View {
    let onPick: (ComposerEmojiPick) -> Void
    let onDelete: () -> Void

    @State private var catalog = EmojiCatalog.shared
    /// A snapshot taken when the panel is made: re-sorting under the finger
    /// as you tap would move the next emoji you were aiming for.
    @State private var recents = ComposerEmojiRecents.load()
    /// The section at the top of the list; setting it scrolls there.
    @State private var section: String?

    private static let siteColumns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 6)
    private static let unicodeColumns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            sectionList
            tabBar
        }
        .background(Theme.bg)
        .task { await catalog.loadIfNeeded() }
    }

    private func pick(_ value: ComposerEmojiPick) {
        onPick(value)
    }

    // MARK: Sections

    private struct Section: Identifiable {
        let id: String
        let title: String
        let kind: Kind
        enum Kind {
            case recents([ComposerEmojiPick])
            case site([DiscourseEmoji])
            case unicode([(String, String)])
            case kaomoji([(String, String)])
        }
    }

    /// Recents that still resolve — a pack an admin turned off drops out.
    private var visibleRecents: [ComposerEmojiPick] {
        recents.filter {
            if case .site(let code) = $0 { return catalog.emoji(named: code) != nil }
            return true
        }
    }

    private var sections: [Section] {
        var list: [Section] = []
        let recent = visibleRecents
        if !recent.isEmpty {
            list.append(Section(id: "recent", title: AppString("最近使用"), kind: .recents(recent)))
        }
        for group in catalog.groups where group.isCustom {
            list.append(Section(id: "pack:\(group.key)", title: group.title, kind: .site(group.emojis)))
        }
        for group in BuiltInEmoji.groups {
            list.append(Section(id: group.id, title: BuiltInEmoji.title(for: group.id), kind: .unicode(group.items)))
        }
        list.append(Section(id: "kao", title: AppString("颜文字"), kind: .kaomoji(BuiltInEmoji.kaomoji)))
        return list
    }

    private var sectionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .scrollPosition(id: $section, anchor: .top)
        .scrollIndicators(.hidden)
        .clipped()
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(Theme.body(12, weight: .bold))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .padding(.bottom, 4)
            switch section.kind {
            case .recents(let picks):
                LazyVGrid(columns: Self.unicodeColumns, spacing: 2) {
                    ForEach(picks, id: \.self) { recentCell($0) }
                }
            case .site(let emojis):
                siteGrid(emojis)
            case .unicode(let items):
                unicodeGrid(items)
            case .kaomoji(let items):
                kaomojiFlow(items)
            }
        }
        .id(section.id)
    }

    private func siteGrid(_ emojis: [DiscourseEmoji]) -> some View {
        LazyVGrid(columns: Self.siteColumns, spacing: 2) {
            ForEach(emojis) { emoji in
                Button { pick(.site(code: emoji.name)) } label: {
                    SiteEmojiImage(emoji: emoji)
                        .padding(6)
                }
                .buttonStyle(EmojiCellStyle())
                .accessibilityLabel(Self.label(for: emoji))
            }
        }
    }

    private func unicodeGrid(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: Self.unicodeColumns, spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button { pick(.character(item.0)) } label: {
                    unicodeGlyph(item.0)
                }
                .buttonStyle(EmojiCellStyle())
                .accessibilityLabel(item.1.split(separator: " ").first.map(String.init) ?? item.0)
            }
        }
    }

    private func unicodeGlyph(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 28))
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
    }

    private func kaomojiFlow(_ items: [(String, String)]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { item in
                Button { pick(.kaomoji(item.0)) } label: {
                    Text(item.0)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(item.1)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func recentCell(_ value: ComposerEmojiPick) -> some View {
        switch value {
        case .site(let code):
            if let emoji = catalog.emoji(named: code) {
                Button { pick(value) } label: {
                    SiteEmojiImage(emoji: emoji)
                        .padding(7)
                        .aspectRatio(1, contentMode: .fit)
                }
                .buttonStyle(EmojiCellStyle())
                .accessibilityLabel(Self.label(for: emoji))
            }
        case .character(let glyph):
            Button { pick(value) } label: { unicodeGlyph(glyph) }
                .buttonStyle(EmojiCellStyle())
        case .kaomoji:
            EmptyView()
        }
    }

    private static func label(for emoji: DiscourseEmoji) -> String {
        let name = emoji.searchAliases?.first(where: { !$0.isEmpty })
        return [emoji.group, name ?? emoji.name].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Tabs

    /// Jumps between sections; the one at the top of the list is lit.
    private var tabBar: some View {
        let list = sections
        let active = section ?? list.first?.id
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(list) { item in
                        Button {
                            withAnimation(.snappy(duration: 0.3)) { section = item.id }
                        } label: {
                            tabIcon(item)
                                .frame(width: 44, height: 44)
                                .background(
                                    item.id == active ? Theme.hover : .clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay(alignment: .bottom) {
                                    Capsule()
                                        .fill(Theme.accent)
                                        .frame(height: 3)
                                        .padding(.horizontal, 10)
                                        .padding(.bottom, 1)
                                        .opacity(item.id == active ? 1 : 0)
                                }
                                .foregroundStyle(item.id == active ? Theme.text : Theme.textMuted)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(item.id == active ? .isSelected : [])
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .trailing, spacing: 0) { deleteKey }
            .onChange(of: active) { _, id in
                // Keep the lit tab on screen as the list scrolls past sections.
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabIcon(_ item: Section) -> some View {
        switch item.kind {
        case .recents:
            Image(systemName: "clock")
                .font(.system(size: 19, weight: .medium))
        case .site(let emojis):
            if let first = emojis.first {
                SiteEmojiImage(emoji: first).frame(width: 26, height: 26)
            }
        case .unicode:
            Text(BuiltInEmoji.groups.first { $0.id == item.id }?.tab ?? "")
                .font(.system(size: 20))
        case .kaomoji:
            Text("ツ")
                .font(.system(size: 18, weight: .medium))
        }
    }

    /// ⌫: one character, or one whole emoji, before the caret.
    private var deleteKey: some View {
        Button(action: onDelete) {
            Image(systemName: "delete.left")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .background(Theme.bg)
        .accessibilityLabel(AppString("删除"))
    }
}

/// A site emoji, from the shared image cache — the same files posts show.
private struct SiteEmojiImage: View {
    let emoji: DiscourseEmoji

    var body: some View {
        CachedRemoteImage(url: emoji.url.flatMap { nodelocSiteURL($0) }) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A square cell that darkens and shrinks a touch while pressed.
private struct EmojiCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Theme.hover : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
