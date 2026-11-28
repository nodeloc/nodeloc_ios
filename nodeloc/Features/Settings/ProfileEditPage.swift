//
//  ProfileEditPage.swift
//  nodeloc
//
//  个人资料 (App-iOS-EditProfile): the banner and avatar on top, then 资料
//  (昵称, 用户名, 自我介绍 with its counter, 网站, 地点) and 展示 (头衔,
//  签名). 保存 is the bar's confirmation button. Limits are the server's;
//  a 422 shows under its field. The design's 展示的成就徽章 row is left out:
//  the server has no setting for which badges to feature.
//

import PhotosUI
import SwiftUI

struct ProfileEditPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    private var store = ProfileEditStore.shared

    @State private var avatarItem: PhotosPickerItem?
    @State private var cardItem: PhotosPickerItem?
    @State private var isSavingText = false
    @State private var pickingAvatar = false
    @State private var pickingCard = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private var errors: [String: String] {
        store.localErrors.merging(store.fieldErrors) { local, _ in local }
    }

    var body: some View {
        Form {
            imagesSection
            textSection
            titleSection
        }
        // Backstop: no single child may set the page's width.
        .clampedToWidth()
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(AppString("个人资料"))
        .navigationBarTitleDisplayMode(.inline)
        .primaryToolbarAction(
            AppString("保存"),
            isEnabled: store.isDirty && store.localErrors.isEmpty,
            isWorking: isSavingText || store.isSaving
        ) {
            Task {
                isSavingText = true
                let saved = await store.saveTextFields()
                isSavingText = false
                if saved {
                    ToastCenter.shared.show(AppString("资料已保存"))
                    onClose()
                }
            }
        }
        .photosPicker(isPresented: $pickingAvatar, selection: $avatarItem, matching: .images)
        .photosPicker(isPresented: $pickingCard, selection: $cardItem, matching: .images)
        .task { await store.load() }
        // Leaving by the system back button still saves what is valid, as before.
        .onDisappear {
            if store.isDirty, store.localErrors.isEmpty { Task { await store.saveTextFields() } }
        }
        .onChange(of: store.name) { store.fieldErrors["name"] = nil }
        .onChange(of: store.bio) { store.fieldErrors["bio"] = nil }
        .onChange(of: store.website) { store.fieldErrors["website"] = nil }
        .onChange(of: store.location) { store.fieldErrors["location"] = nil }
        // Uploads report failures through `errorText`.
        .onChange(of: store.errorText) { _, text in
            guard let text else { return }
            ToastCenter.shared.show(text)
            store.errorText = nil
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let (data, mime) = await imageData(item) { await store.uploadAvatar(data, mimeType: mime) }
                avatarItem = nil
            }
        }
        .onChange(of: cardItem) { _, item in
            guard let item else { return }
            Task {
                if let (data, mime) = await imageData(item) { await store.uploadCardBackground(data, mimeType: mime) }
                cardItem = nil
            }
        }
    }

    // MARK: Banner + avatar

    private var imagesSection: some View {
        Section {
            ZStack(alignment: .bottomLeading) {
                cardBackground
                    .overlay(alignment: .topTrailing) { backgroundMenu.padding(10) }
                HStack(alignment: .bottom, spacing: 14) {
                    Button { pickingAvatar = true } label: {
                        RemoteAvatar(
                            url: store.avatarURL,
                            letter: String(store.name.prefix(1)).uppercased(),
                            variant: abs(store.name.hashValue),
                            size: 84
                        )
                        .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 4))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(.systemBackground))
                                .frame(width: 30, height: 30)
                                .background(Color(.label), in: Circle())
                                .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 3))
                                .offset(x: 2, y: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppString("更换头像"))

                    Text(AppString("头像 400×400 以上，背景建议 3:1。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 16)
                .offset(y: 34)
            }
            .padding(.bottom, 34)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    /// 更换背景: the photo picker, and 移除背景 when there is one.
    private var backgroundMenu: some View {
        Menu {
            Button { pickingCard = true } label: {
                Label(AppString("从相册选择"), systemImage: "photo.on.rectangle")
            }
            if store.cardBackgroundURL != nil {
                Button(role: .destructive) {
                    Task { await store.removeCardBackground() }
                } label: {
                    Label(AppString("移除背景"), systemImage: "trash")
                }
            }
        } label: {
            Label(AppString("更换背景"), systemImage: "photo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Group {
            if let url = store.cardBackgroundURL {
                CachedRemoteImage(url: url) { $0.resizable() } placeholder: {
                    Theme.surface
                }
            } else {
                LinearGradient(
                    colors: [Theme.accent.opacity(0.35), Theme.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        // `filledBanner`, not `.scaledToFill()` + `.frame` + clip: a filled
        // wide image reports its scaled width as the view's size, and that
        // widened the whole page. The box is sized first and the image hung in it.
        .filledBanner(height: 132, clip: shape)
    }

    // MARK: 资料

    private var textSection: some View {
        Section {
            field(AppString("昵称"), placeholder: AppString("你的名字"), text: bindingName, key: "name")
            LabeledContent(AppString("用户名")) {
                Text(verbatim: "@\(DiscourseAuth.shared.username ?? "")")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(AppString("自我介绍"))
                    Spacer()
                    Text(verbatim: "\(store.bio.count) / \(ProfileEditStore.bioLimit)")
                        .monospacedDigit()
                        .foregroundStyle(store.bio.count > ProfileEditStore.bioLimit ? Theme.danger : .secondary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                TextField(AppString("介绍一下自己"), text: bindingBio, axis: .vertical)
                    .lineLimit(3...8)
                FieldErrorText(message: errors["bio"])
            }
            .padding(.vertical, 2)
            field(AppString("网站"), placeholder: "https://", text: bindingWebsite, key: "website", keyboard: .URL)
            field(AppString("地点"), placeholder: AppString("所在地"), text: bindingLocation, key: "location")
        } header: {
            Text(AppString("资料"))
        }
    }

    private func field(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        key: String,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            LabeledContent(title) {
                TextField(placeholder, text: text)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(keyboard == .URL ? .never : .sentences)
                    .autocorrectionDisabled(keyboard == .URL)
            }
            FieldErrorText(message: errors[key])
        }
    }

    private var bindingName: Binding<String> { Binding(get: { store.name }, set: { store.name = $0 }) }
    private var bindingBio: Binding<String> { Binding(get: { store.bio }, set: { store.bio = $0 }) }
    private var bindingWebsite: Binding<String> { Binding(get: { store.website }, set: { store.website = $0 }) }
    private var bindingLocation: Binding<String> { Binding(get: { store.location }, set: { store.location = $0 }) }

    // MARK: 展示

    /// One picker choice: a group whose 头衔 to wear, or `id == 0` for none.
    private struct TitleChoice: Identifiable, Hashable {
        let id: Int
        let label: String
    }

    private var titleChoices: [TitleChoice] {
        [TitleChoice(id: 0, label: AppString("无"))] + store.titleGroups.map { group in
            let name = group.label ?? group.name
            guard let title = group.title, !title.isEmpty else { return TitleChoice(id: group.id, label: name) }
            return TitleChoice(id: group.id, label: title == name ? title : "\(title) · \(name)")
        }
    }

    /// 头衔 (the personal one, admin-given, read-only; or the group title you
    /// wear) and 签名.
    private var titleSection: some View {
        Section {
            if let personal = store.title {
                LabeledContent(AppString("头衔")) {
                    UserTitleChip(title: personal, compact: true)
                }
            }
            if !store.titleGroups.isEmpty {
                Picker(store.title == nil ? AppString("头衔") : AppString("用户组头衔"), selection: titleBinding) {
                    ForEach(titleChoices) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            NavigationLink {
                SignatureEditPage()
            } label: {
                LabeledContent(AppString("签名")) {
                    Text(store.signature.isEmpty ? AppString("未设置") : AppString("已设置"))
                }
            }
        } header: {
            Text(AppString("展示"))
        } footer: {
            Text(titleFooter)
        }
    }

    private var titleFooter: String {
        if store.title != nil {
            return AppString("个人头衔由管理员授予，会优先显示；没有个人头衔时显示所选用户组的头衔。签名显示在你发的主题首帖下面。")
        }
        return AppString("头衔从你所在的用户组里选；签名显示在你发的主题首帖下面。")
    }

    private var titleBinding: Binding<TitleChoice> {
        Binding(
            get: { titleChoices.first { $0.id == store.primaryGroupID } ?? titleChoices[0] },
            set: { choice in Task { await store.setPrimaryGroup(choice.id) } }
        )
    }

    // MARK: Helpers

    private func imageData(_ item: PhotosPickerItem) async -> (Data, String)? {
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { return nil }
        // PNG magic number, else treat as JPEG — matches the composer's handling.
        let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        return (data, mime)
    }
}

/// 签名: up to 300 characters of markdown under the first post of your
/// topics. 保存 in the bar; the server's refusal under the field.
struct SignatureEditPage: View {
    @Environment(\.dismiss) private var dismiss
    private var store = ProfileEditStore.shared
    @State private var text = ""
    @State private var loaded = false

    init() {}

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { trimmed.count > ProfileEditStore.signatureLimit }

    var body: some View {
        Form {
            Section {
                TextField(AppString("一句话签名，支持 Markdown"), text: $text, axis: .vertical)
                    .lineLimit(4...10)
                FieldErrorText(message: tooLong
                    ? AppString("签名最多 \(ProfileEditStore.signatureLimit) 个字符")
                    : store.fieldErrors["signature"])
            } footer: {
                HStack {
                    Text(AppString("显示在你发的主题首帖下面。留空就不显示。"))
                    Spacer()
                    Text(verbatim: "\(trimmed.count) / \(ProfileEditStore.signatureLimit)")
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle(AppString("签名"))
        .navigationBarTitleDisplayMode(.inline)
        .primaryToolbarAction(
            AppString("保存"),
            isEnabled: loaded && !tooLong && trimmed != store.signature,
            isWorking: store.isSaving
        ) {
            Task {
                if await store.saveSignature(trimmed) { dismiss() }
            }
        }
        .onAppear {
            guard !loaded else { return }
            text = store.signature
            store.fieldErrors["signature"] = nil
            loaded = true
        }
    }
}
