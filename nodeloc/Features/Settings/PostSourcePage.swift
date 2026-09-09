//
//  PostSourcePage.swift
//  nodeloc
//
//  发帖来源 (小尾巴): how much of the device a post discloses, plus taking it
//  back off posts already published. Server-side (discourse-mobile), so the
//  choice follows the account rather than this phone.
//

import SwiftUI

/// The disclosure ladder, matching `DiscourseMobile::PostSource` rung for rung.
/// Raw values are the integers the endpoint stores, so they must not be
/// renumbered.
///
/// A ladder rather than separate switches, deliberately: "show the model but
/// not the brand" isn't a thing anyone means.
enum PostSourceLevel: Int, CaseIterable, Identifiable {
    case off = 0
    case client = 1
    case platform = 2
    case brand = 3
    case model = 4

    var id: Int { rawValue }

    /// The server's default for anyone who has never opened this screen — and
    /// the reason this page has to be honest rather than reassuring.
    static let serverDefault: PostSourceLevel = .model

    var title: String {
        switch self {
        case .off: return AppString("关闭")
        case .client: return AppString("客户端")
        case .platform: return AppString("平台")
        case .brand: return AppString("设备类型")
        case .model: return AppString("机型")
        }
    }

    /// What a post would actually show at this rung, on this device.
    var example: String {
        switch self {
        case .off: return AppString("不显示")
        case .client: return "NodeLoc App"
        case .platform: return "iOS"
        // The plugin resolves Apple's brand rung to the product line rather
        // than printing "Apple", which would only repeat the platform rung.
        case .brand: return appleFamily
        case .model: return AppString("\(appleFamily)（具体型号）")
        }
    }

    var detail: String {
        switch self {
        case .off: return AppString("帖子上不显示任何来源")
        case .client: return AppString("只说明这条帖子是用 App 发的")
        case .platform: return AppString("加上操作系统")
        case .brand: return AppString("加上设备类型")
        case .model: return AppString("显示具体机型，例如 iPhone 16 Pro")
        }
    }

    /// "iPhone17,1" → "iPhone". The identifier is all iOS exposes; the marketing
    /// name is filled in server-side.
    private var appleFamily: String {
        let identifier = DeviceSource.model
        guard let family = identifier.split(separator: ",").first?.prefix(while: { !$0.isNumber }),
              !family.isEmpty else {
            return "iPhone"
        }
        return String(family)
    }
}

@MainActor
@Observable
final class PostSourceStore {
    private let client = DiscourseClient()

    var level: PostSourceLevel = .serverDefault
    var isLoading = false
    var isSaving = false
    var isClearing = false
    /// Nil until a withdrawal has run; then how many tails came off.
    var clearedCount: Int?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let response = try? await client.postSourceLevel(),
              let stored = response.level.flatMap(PostSourceLevel.init(rawValue:)) else { return }
        level = stored
    }

    /// Applied locally first so the picker answers immediately; rolled back if
    /// the write fails, since otherwise the screen would claim a setting the
    /// server never took.
    func setLevel(_ newLevel: PostSourceLevel) async {
        guard newLevel != level, !isSaving else { return }
        let previous = level
        level = newLevel
        isSaving = true
        defer { isSaving = false }

        do {
            try await client.setPostSourceLevel(newLevel.rawValue)
        } catch {
            level = previous
            ToastCenter.shared.showError(error)
        }
    }

    func clearHistory() async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }

        do {
            let response = try await client.clearPostSourceHistory()
            clearedCount = response.cleared ?? 0
            ToastCenter.shared.show(AppString("已清除 \(response.cleared ?? 0) 条来源"))
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}

struct PostSourcePage: View {
    let onClose: () -> Void

    @State private var store = PostSourceStore()
    @State private var isConfirmingClear = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 0) {
                    SettingsSection(title: AppString("显示内容"), footer: levelFooter) {
                        SettingsPickerRow(
                            title: AppString("来源信息"),
                            detail: AppString("帖子上显示：\(store.level.example)"),
                            options: PostSourceLevel.allCases,
                            label: \.title,
                            selection: levelBinding
                        )
                    }

                    SettingsSection(title: AppString("已发布的帖子"), footer: clearFooter) {
                        SettingsNavRow(
                            title: AppString("清除已有帖子的来源"),
                            icon: "eraser",
                            isDestructive: true
                        ) {
                            isConfirmingClear = true
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
        .confirmationDialog(
            AppString("清除所有帖子的来源？"),
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                Task { await store.clearHistory() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你已发布帖子上的来源会被删除，无法恢复。这不影响以后发帖的设置。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .glassButton(tint: Theme.bg.opacity(0.34), shape: .circle)

            Text("发帖来源").font(Theme.body(15, weight: .medium))

            Spacer()

            if store.isLoading || store.isSaving {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// States the default outright. The site shows the model unless told
    /// otherwise, so a footer promising silence would be a lie.
    private var levelFooter: String {
        """
        在 App 里发帖时，帖子上会显示你选择的来源，站点默认显示机型。\
        来源只是一个装饰：任何客户端都能声称自己是任意机型，所以它不代表任何凭证。
        """
    }

    private var clearFooter: String {
        if let cleared = store.clearedCount {
            return AppString("已清除 \(cleared) 条。降低上面的层级只影响以后发的帖子。")
        }
        return AppString("降低上面的层级只影响以后发的帖子；已经发出去的需要在这里清除。")
    }

    private var levelBinding: Binding<PostSourceLevel> {
        Binding(
            get: { store.level },
            set: { newValue in Task { await store.setLevel(newValue) } }
        )
    }
}
