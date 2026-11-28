//
//  PreferencePages.swift
//  nodeloc
//
//  One page per group of preferences. 界面 is this device's own; the rest are
//  the account's settings on the backend (`/api/v1/me/settings`) — the same
//  fields the web settings page and the Android app write.
//

import SwiftUI

/// Groups shown on the settings screen. Each is a page of related options.
enum PreferenceGroup: String, CaseIterable, Identifiable {
    case interface
    case notifications
    case emails
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interface: return AppString("界面")
        case .notifications: return AppString("通知")
        case .emails: return AppString("电子邮件")
        case .privacy: return AppString("隐私")
        }
    }

    var icon: String {
        switch self {
        case .interface: return "paintbrush"
        case .notifications: return "bell"
        case .emails: return "envelope"
        case .privacy: return "lock"
        }
    }

    /// 界面 is stored on the device, so a guest can use it too.
    var needsAccount: Bool { self != .interface }
}

/// The page for one group.
struct PreferencePage: View {
    let group: PreferenceGroup
    let onClose: () -> Void

    private var prefs = UserPreferencesStore.shared
    private var account = AccountSettingsStore.shared

    init(group: PreferenceGroup, onClose: @escaping () -> Void) {
        self.group = group
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Group {
                    if !group.needsAccount {
                        interfaceSection
                    } else if account.settings == nil {
                        loadingOrFailed
                    } else {
                        switch group {
                        case .interface: EmptyView()
                        case .notifications: notificationsSection
                        case .emails: emailSection
                        case .privacy: privacySection
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .refreshable {
                if group.needsAccount { await account.load(force: true) }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task {
            if group.needsAccount { await account.load() }
        }
        // A save the server refused is rolled back; say why rather than let
        // the switch silently flip back.
        .onChange(of: account.errorText) { _, text in
            guard let text else { return }
            ToastCenter.shared.show(text)
            account.errorText = nil
        }
    }

    private var header: some View {
        SettingsBar(title: group.title, onClose: onClose) {
            if account.isSaving {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private var loadingOrFailed: some View {
        Section {
            if account.loadFailed && !account.isLoading {
                VStack(spacing: 14) {
                    EmptyStateView(icon: "exclamationmark.triangle", message: AppString("加载失败"))
                    Button(AppString("重试")) {
                        Task { await account.load(force: true) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: Interface

    @ViewBuilder
    private var interfaceSection: some View {
        SettingsSection(title: AppString("外观")) {
            SettingsPickerRow(
                title: AppString("颜色模式"),
                options: InterfaceColorMode.allCases,
                label: \.label,
                selection: prefs.colorModeBinding
            )
            SettingsPickerRow(
                title: AppString("文本大小"),
                options: TextSize.ordered,
                label: \.label,
                selection: prefs.textSizeBinding
            )
        }

        languageSection

        SettingsSection(title: AppString("浏览")) {
            // Local, and only the lists the home card list can render — see
            // `HomeFeed`.
            SettingsPickerRow(
                title: AppString("默认首页"),
                options: HomeFeed.allCases,
                label: \.label,
                selection: prefs.homeFeedBinding
            )
            // The home feed's and node pages' 列表样式, the same choice the
            // sheet behind the tab strip's icon makes.
            SettingsPickerRow(
                title: AppString("默认列表视图"),
                options: NodeReadingMode.allCases,
                label: \.label,
                selection: Binding(
                    get: { NodeReadingModeStore.shared.mode },
                    set: { NodeReadingModeStore.shared.select($0) }
                )
            )
        }
    }

    // MARK: Language

    private var languageSection: some View {
        Section {
            Picker(AppString("语言"), selection: Binding(
                get: { ServerLanguage.choice?.code ?? "" },
                set: { code in
                    let chosen = ServerLanguage.all.first { $0.code == code }
                    Task {
                        if let error = await AppLocaleStore.shared.chooseServerLanguage(chosen) {
                            ToastCenter.shared.show(error)
                        }
                    }
                }
            )) {
                Text(AppString("跟随系统")).tag("")
                ForEach(ServerLanguage.all) { language in
                    Text(verbatim: language.name).tag(language.code)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text(AppString("语言"))
        } footer: {
            Text(languageFooter)
        }
    }

    /// Says when the app's own words can't follow the choice.
    private var languageFooter: String {
        guard let choice = ServerLanguage.choice, !choice.appHasStrings else {
            return AppString("帖子、通知和提示会用所选的语言。")
        }
        return AppString("帖子、通知和提示会用 \(choice.name)；App 自己的文字暂时只有简体中文和 English，现在用 \(choice.appLanguage.endonym)。")
    }

    // MARK: Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        ForEach(NotifyKind.groups, id: \.title) { group in
            SettingsSection(title: group.title) {
                ForEach(group.kinds) { kind in
                    SettingsToggleRow(
                        title: kind.title,
                        detail: kind.detail,
                        isOn: account.notify(kind.key)
                    )
                }
            }
        }

        Section {} footer: {
            Text(AppString("密码、两步验证和登录方式的变更总会通知你，无法关闭。"))
        }
    }

    // MARK: Email

    @ViewBuilder
    private var emailSection: some View {
        SettingsSection(
            title: AppString("邮件通知"),
            footer: AppString("关闭后只会收到安全提醒邮件。")
        ) {
            SettingsToggleRow(
                title: AppString("通过邮件接收通知"),
                isOn: account.notify("email")
            )
        }

        if account.notify("email").wrappedValue {
            SettingsSection(title: AppString("通过邮件通知我")) {
                ForEach(NotifyKind.groups.flatMap(\.kinds)) { kind in
                    SettingsToggleRow(
                        title: kind.title,
                        isOn: account.notify(kind.key + ".mail")
                    )
                }
            }
        }

        SettingsSection(title: AppString("活动总结")) {
            SettingsPickerRow(
                title: AppString("邮件精选摘要"),
                detail: AppString("这段时间最受欢迎的帖子和你没看的通知"),
                options: DigestFrequency.allCases,
                label: \.label,
                selection: account.digestBinding
            )
        }
    }

    // MARK: Privacy

    @ViewBuilder
    private var privacySection: some View {
        SettingsSection(title: AppString("互动")) {
            SettingsToggleRow(
                title: AppString("允许他人关注我"),
                detail: AppString("关闭后别人不能再关注你，已经关注你的人不受影响"),
                isOn: account.flag(\.allowFollow, "allow_follow", default: true)
            )
            SettingsPickerRow(
                title: AppString("谁可以私信我"),
                detail: AppString("管理人员不受这项限制"),
                options: ContactPolicy.allCases,
                label: \.label,
                selection: account.policy(\.messagePolicy, "message_policy")
            )
            SettingsPickerRow(
                title: AppString("谁可以 @ 我"),
                detail: AppString("不允许的人 @ 你时不会通知你，帖子照常发出"),
                options: ContactPolicy.allCases,
                label: \.label,
                selection: account.policy(\.mentionPolicy, "mention_policy")
            )
        }

        SettingsSection(title: AppString("主页展示")) {
            SettingsToggleRow(
                title: AppString("显示我加入的节点"),
                detail: AppString("在主页上列出你加入的公开节点"),
                isOn: account.flag(\.showJoinedNodes, "show_joined_nodes", default: true)
            )
            SettingsToggleRow(
                title: AppString("显示在线状态"),
                detail: AppString("关闭后你也看不到别人的在线状态"),
                isOn: account.flag(\.showOnline, "show_online", default: true)
            )
            SettingsToggleRow(
                title: AppString("显示等级与声望"),
                detail: AppString("关闭后其他人看不到你的段位和声望"),
                isOn: account.flag(\.showLevel, "show_level", default: true)
            )
        }

        SettingsSection(title: AppString("可见性")) {
            SettingsToggleRow(
                title: AppString("允许搜索引擎收录我的主页"),
                detail: AppString("关闭后主页会要求搜索引擎不要收录"),
                isOn: account.flag(\.searchIndex, "search_index", default: true)
            )
            SettingsToggleRow(
                title: AppString("公开我赞同过的内容"),
                detail: AppString("打开后别人在你的主页上能看到「赞同过」"),
                isOn: account.flag(\.showUpvotes, "show_upvotes", default: false)
            )
        }
    }
}
