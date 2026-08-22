//
//  ProfileEditPage.swift
//  nodeloc
//
//  Edits the signed-in user's profile: avatar, card background, name, bio,
//  website, location, title, and featured badges.
//

import PhotosUI
import SwiftUI

struct ProfileEditPage: View {
    let onClose: () -> Void

    private var store = ProfileEditStore.shared

    @State private var avatarItem: PhotosPickerItem?
    @State private var cardItem: PhotosPickerItem?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    imagesSection
                    textSection
                    titleSection
                    flairSection
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.load() }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let (data, mime) = await imageData(item) { await store.uploadAvatar(data, mimeType: mime) }
            }
        }
        .onChange(of: cardItem) { _, item in
            guard let item else { return }
            Task {
                if let (data, mime) = await imageData(item) { await store.uploadCardBackground(data, mimeType: mime) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.saveTextFields(); onClose() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)

            Text("个人资料").font(Theme.body(15, weight: .medium))
            Spacer()
            if store.isSaving {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: Avatar + card background

    private var imagesSection: some View {
        VStack(spacing: 16) {
            // Card background behind the avatar, mirroring the profile card.
            ZStack(alignment: .bottomLeading) {
                cardBackground
                RemoteAvatar(
                    url: store.avatarURL,
                    letter: String(store.name.prefix(1)).uppercased(),
                    variant: abs(store.name.hashValue),
                    size: 76
                )
                .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))
                .padding(.leading, 16)
                .offset(y: 24)
            }
            .padding(.bottom, 24)

            HStack(spacing: 10) {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    Label("更换头像", systemImage: "person.crop.circle")
                        .font(Theme.body(13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)

                PhotosPicker(selection: $cardItem, matching: .images) {
                    Label("更换背景", systemImage: "photo")
                        .font(Theme.body(13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if store.cardBackgroundURL != nil {
                Button(role: .destructive) {
                    Task { await store.removeCardBackground() }
                } label: {
                    Text("移除背景").font(Theme.body(12)).foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if let url = store.cardBackgroundURL {
                CachedRemoteImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                    Theme.surface
                }
            } else {
                LinearGradient(
                    colors: [Theme.accent.opacity(0.35), Theme.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .padding(.horizontal, 16)
    }

    // MARK: Text fields

    private var textSection: some View {
        SettingsSection(title: "资料") {
            SettingsTextRow(title: "昵称", placeholder: "你的名字", text: bindingName)
            SettingsMultilineRow(title: "自我介绍", placeholder: "介绍一下自己", text: bindingBio)
            SettingsTextRow(title: "网站", placeholder: "https://", text: bindingWebsite)
            SettingsTextRow(title: "地点", placeholder: "所在地", text: bindingLocation)
        }
    }

    private var bindingName: Binding<String> { Binding(get: { store.name }, set: { store.name = $0 }) }
    private var bindingBio: Binding<String> { Binding(get: { store.bio }, set: { store.bio = $0 }) }
    private var bindingWebsite: Binding<String> { Binding(get: { store.website }, set: { store.website = $0 }) }
    private var bindingLocation: Binding<String> { Binding(get: { store.location }, set: { store.location = $0 }) }

    // MARK: Title

    /// Wraps the title choice so it can drive a `SettingsPickerRow`. The empty
    /// string is the "无" (clear) option.
    private struct TitleChoice: Identifiable, Equatable {
        let value: String
        var id: String { value }
        var label: String { value.isEmpty ? "无" : value }
    }

    private var titleChoices: [TitleChoice] {
        [TitleChoice(value: "")] + store.titleOptions.map { TitleChoice(value: $0) }
    }

    @ViewBuilder
    private var titleSection: some View {
        SettingsSection(
            title: "头衔",
            footer: store.titleOptions.isEmpty ? "只有可授予头衔的徽章才能设为头衔。" : nil
        ) {
            if store.titleOptions.isEmpty {
                // Nothing to choose: a plain, non-tappable row.
                HStack {
                    Text("头衔").font(Theme.body(14)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text("无").font(Theme.body(13)).foregroundStyle(Theme.muted(0.4))
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SettingsPickerRow(
                    title: "头衔",
                    options: titleChoices,
                    label: \.label,
                    selection: titleBinding
                )
            }
        }
    }

    private var titleBinding: Binding<TitleChoice> {
        Binding(
            get: { TitleChoice(value: store.title ?? "") },
            set: { choice in Task { await store.setTitle(choice.value.isEmpty ? nil : choice.value) } }
        )
    }

    // MARK: 资质 (flair group)

    /// Wraps a flair choice for `SettingsPickerRow`. `id == nil` is the "无" row.
    private struct FlairChoice: Identifiable, Equatable {
        let group: UserGroupFlair?
        var id: Int { group?.id ?? -1 }
        var label: String { group?.displayName ?? "无" }
    }

    @ViewBuilder
    private var flairSection: some View {
        if !store.flairOptions.isEmpty {
            SettingsSection(
                title: "资质",
                footer: "资质来自你所在的用户组，会显示在你的头像旁。"
            ) {
                SettingsPickerRow(
                    title: "资质",
                    options: flairChoices,
                    label: \.label,
                    selection: flairBinding
                )
            }
        }
    }

    private var flairChoices: [FlairChoice] {
        [FlairChoice(group: nil)] + store.flairOptions.map { FlairChoice(group: $0) }
    }

    private var flairBinding: Binding<FlairChoice> {
        Binding(
            get: { FlairChoice(group: store.currentFlairGroup) },
            set: { choice in Task { await store.setFlairGroup(choice.group?.id) } }
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
