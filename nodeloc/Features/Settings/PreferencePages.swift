//
//  PreferencePages.swift
//  nodeloc
//
//  One page per group of Discourse account preferences. Between them these
//  cover every field in `UserUpdater::OPTION_ATTR`.
//

import SwiftUI

/// Groups shown on the settings screen. Each is a page of related options.
enum PreferenceGroup: String, CaseIterable, Identifiable {
    case interface
    case notifications
    case emails
    case tracking
    case privacy
    case other
    case webOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interface: return "界面"
        case .notifications: return "通知"
        case .emails: return "电子邮件"
        case .tracking: return "跟踪"
        case .privacy: return "隐私"
        case .other: return "其他"
        case .webOnly: return "网页端设置"
        }
    }

    var icon: String {
        switch self {
        case .interface: return "paintbrush"
        case .notifications: return "bell"
        case .emails: return "envelope"
        case .tracking: return "eye"
        case .privacy: return "lock"
        case .other: return "slider.horizontal.3"
        case .webOnly: return "globe"
        }
    }
}

/// The page for one group.
struct PreferencePage: View {
    let group: PreferenceGroup
    let onClose: () -> Void

    private var prefs = UserPreferencesStore.shared

    init(group: PreferenceGroup, onClose: @escaping () -> Void) {
        self.group = group
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 0) {
                    switch group {
                    case .interface: interfaceSection
                    case .notifications: notificationsSection
                    case .emails: emailSection
                    case .tracking: trackingSection
                    case .privacy: privacySection
                    case .other: otherSection
                    case .webOnly: webOnlySection
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await prefs.load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)

            Text(group.title).font(Theme.body(15, weight: .medium))

            Spacer()

            if prefs.isSaving {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: Interface

    @ViewBuilder
    private var interfaceSection: some View {
        SettingsSection(title: "外观") {
            SettingsPickerRow(
                title: "颜色模式",
                options: InterfaceColorMode.allCases,
                label: \.label,
                selection: prefs.colorModeBinding
            )
            SettingsPickerRow(
                title: "文本大小",
                options: TextSize.ordered,
                label: \.label,
                selection: prefs.textSizeBinding
            )
        }

        SettingsSection(title: "浏览") {
            SettingsPickerRow(
                title: "默认首页",
                options: HomepageChoice.allCases,
                label: \.label,
                selection: prefs.choice(\.homepageId, "homepage_id", default: HomepageChoice.latest)
            )
            SettingsToggleRow(
                title: "自动翻译",
                detail: "自动翻译以其他语言发布的话题和帖子",
                isOn: prefs.toggle(\.automaticallyTranslate, "automatically_translate", default: true)
            )
        }
    }

    // MARK: Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        SettingsSection(title: "推送通知") {
            SettingsPickerRow(
                title: "推送通知",
                options: PushNotificationLevel.allCases,
                label: \.label,
                selection: prefs.choice(
                    \.pushNotificationLevel, "push_notification_level",
                    default: PushNotificationLevel.all
                )
            )
        }

        SettingsSection(title: "提醒我") {
            SettingsPickerRow(
                title: "被赞时通知",
                options: LikeNotificationFrequency.allCases,
                label: \.label,
                selection: prefs.choice(
                    \.likeNotificationFrequency, "like_notification_frequency",
                    default: LikeNotificationFrequency.firstTimeAndDaily
                )
            )
            SettingsToggleRow(
                title: "链接提醒",
                detail: "当有人分享我的帖子链接时通知我",
                isOn: prefs.toggle(\.notifyOnLinkedPosts, "notify_on_linked_posts", default: true)
            )
            SettingsToggleRow(
                title: "即将推出的更改",
                detail: "当即将推出的更改可供预览时通知我",
                isOn: prefs.toggle(
                    \.enableUpcomingChangeAvailableNotifications,
                    "enable_upcoming_change_available_notifications",
                    default: true
                )
            )
        }
    }

    // MARK: Email

    @ViewBuilder
    private var emailSection: some View {
        SettingsSection(title: "电子邮件") {
            SettingsPickerRow(
                title: "活动邮件",
                detail: "当我被引用、回复、被提及，或我关注的内容有新活动时",
                options: EmailLevel.allCases,
                label: \.label,
                selection: prefs.choice(\.emailLevel, "email_level", default: EmailLevel.onlyWhenAway)
            )
            SettingsPickerRow(
                title: "私信邮件",
                detail: "当我收到个人消息时",
                options: EmailLevel.allCases,
                label: \.label,
                selection: prefs.choice(
                    \.emailMessagesLevel, "email_messages_level",
                    default: EmailLevel.always
                )
            )
            SettingsPickerRow(
                title: "包含以前的回复",
                detail: "在电子邮件底部",
                options: PreviousRepliesLevel.allCases,
                label: \.label,
                selection: prefs.choice(
                    \.emailPreviousReplies, "email_previous_replies",
                    default: PreviousRepliesLevel.never
                )
            )
            SettingsToggleRow(
                title: "包含回复节选",
                detail: "在电子邮件中包含帖子回复节选",
                isOn: prefs.toggle(\.emailInReplyTo, "email_in_reply_to", default: true)
            )
        }

        SettingsSection(title: "活动总结") {
            SettingsToggleRow(
                title: "发送总结邮件",
                detail: "当我不访问这里时，向我发送热门话题和回复的电子邮件总结",
                isOn: prefs.toggle(\.emailDigests, "email_digests", default: true)
            )
            SettingsToggleRow(
                title: "包含新用户内容",
                detail: "在总结电子邮件中包含来自新用户的内容",
                isOn: prefs.toggle(\.includeTl0InDigests, "include_tl0_in_digests")
            )
        }

        SettingsSection(
            title: "邮寄名单模式",
            footer: "开启后，每个新帖子都会发一封邮件。"
        ) {
            SettingsToggleRow(
                title: "启用邮寄名单模式",
                isOn: prefs.toggle(\.mailingListMode, "mailing_list_mode")
            )
        }
    }

    // MARK: Tracking

    @ViewBuilder
    private var trackingSection: some View {
        SettingsSection(title: "话题") {
            SettingsPickerRow(
                title: "何时视为新话题",
                options: NewTopicDuration.ordered,
                label: \.label,
                selection: prefs.choice(
                    \.newTopicDurationMinutes, "new_topic_duration_minutes",
                    default: NewTopicDuration.afterTwoWeeks
                )
            )
            SettingsPickerRow(
                title: "自动跟踪我进入的话题",
                options: AutoTrackDuration.allCases,
                label: \.label,
                selection: prefs.choice(
                    \.autoTrackTopicsAfterMsecs, "auto_track_topics_after_msecs",
                    default: AutoTrackDuration.after4Minutes
                )
            )
            SettingsPickerRow(
                title: "发帖时",
                options: ReplyNotificationLevel.allCases,
                label: \.label,
                selection: prefs.choice(
                    \.notificationLevelWhenReplying, "notification_level_when_replying",
                    default: ReplyNotificationLevel.watchTopic
                )
            )
            SettingsToggleRow(
                title: "话题关闭时视为未读",
                isOn: prefs.toggle(\.topicsUnreadWhenClosed, "topics_unread_when_closed", default: true)
            )
            SettingsToggleRow(
                title: "关注优先于免打扰",
                detail: "如果我正在关注的类别或标签中有我已设为免打扰的话题，请通知我",
                isOn: prefs.toggle(\.watchedPrecedenceOverMuted, "watched_precedence_over_muted")
            )
        }
    }

    // MARK: Privacy

    @ViewBuilder
    private var privacySection: some View {
        SettingsSection(title: "个人资料") {
            SettingsToggleRow(
                title: "隐藏我的公开个人资料",
                isOn: prefs.toggle(\.hideProfile, "hide_profile")
            )
            SettingsToggleRow(
                title: "隐藏在线状态",
                isOn: prefs.toggle(\.hidePresence, "hide_presence")
            )
        }

        SettingsSection(title: "个人消息") {
            SettingsToggleRow(
                title: "允许其他用户向我发送个人消息",
                isOn: prefs.toggle(\.allowPrivateMessages, "allow_private_messages", default: true)
            )
            SettingsToggleRow(
                title: "仅允许指定用户发送消息",
                isOn: prefs.toggle(\.enableAllowedPmUsers, "enable_allowed_pm_users")
            )
        }
    }

    // MARK: Other

    @ViewBuilder
    private var otherSection: some View {
        SettingsSection(title: "常规") {
            SettingsTextRow(
                title: "时区",
                placeholder: TimeZone.current.identifier,
                text: prefs.timezoneBinding
            )
            SettingsPickerRow(
                title: "默认日历",
                options: DefaultCalendar.allCases,
                label: \.label,
                selection: prefs.choice(
                    \.defaultCalendar, "default_calendar",
                    default: DefaultCalendar.noneSelected
                )
            )
            SettingsPickerRow(
                title: "编辑器模式",
                options: CompositionMode.allCases,
                label: \.label,
                selection: prefs.choice(
                    \.compositionMode, "composition_mode",
                    default: CompositionMode.rich
                )
            )
            SettingsToggleRow(
                title: "跳过新用户入门提示",
                isOn: prefs.toggle(\.skipNewUserTips, "skip_new_user_tips")
            )
            SettingsToggleRow(
                title: "到达底部时自动取消置顶话题",
                isOn: prefs.toggle(\.automaticallyUnpinTopics, "automatically_unpin_topics", default: true)
            )
        }
    }

    // MARK: Web-only

    @ViewBuilder
    private var webOnlySection: some View {
        SettingsSection(
            title: "网页端设置",
            footer: "这些设置会保存到你的账号并在网页端生效，但对本 app 没有影响。"
        ) {
            SettingsToggleRow(
                title: "在新标签页中打开外部链接",
                isOn: prefs.toggle(\.externalLinksInNewTab, "external_links_in_new_tab")
            )
            SettingsToggleRow(
                title: "在浏览器图标上显示数量",
                isOn: prefs.toggle(\.dynamicFavicon, "dynamic_favicon")
            )
            SettingsToggleRow(
                title: "为高亮显示的文字启用引用回复",
                isOn: prefs.toggle(\.enableQuoting, "enable_quoting", default: true)
            )
            SettingsToggleRow(
                title: "在编辑器中启用智能列表",
                isOn: prefs.toggle(\.enableSmartLists, "enable_smart_lists", default: true)
            )
            SettingsToggleRow(
                title: "Markdown 模式使用等宽字体",
                isOn: prefs.toggle(
                    \.enableMarkdownMonospaceFont, "enable_markdown_monospace_font",
                    default: true
                )
            )
            SettingsPickerRow(
                title: "页面标题显示数量",
                options: TitleCountMode.allCases,
                label: \.label,
                selection: prefs.titleCountModeBinding
            )
            SettingsPickerRow(
                title: "聊天编辑器发送方式",
                options: SendShortcut.allCases,
                label: \.label,
                selection: prefs.choice(\.sendShortcut, "send_shortcut", default: SendShortcut.enter)
            )
            SettingsToggleRow(
                title: "侧边栏链接到筛选列表",
                isOn: prefs.toggle(\.sidebarLinkToFilteredList, "sidebar_link_to_filtered_list")
            )
            SettingsToggleRow(
                title: "侧边栏显示新内容数量",
                isOn: prefs.toggle(\.sidebarShowCountOfNewItems, "sidebar_show_count_of_new_items")
            )
        }
    }
}
