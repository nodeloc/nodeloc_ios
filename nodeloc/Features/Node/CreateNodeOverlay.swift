//
//  CreateNodeOverlay.swift
//  nodeloc
//
//  The create-a-node form.
//

import SwiftUI

// MARK: - Create node

private enum CreateNodeFocusField: Hashable {
    case name
    case slug
    case description
}

struct CreateNodeOverlay: View {
    @Environment(AppState.self) private var app
    @State private var store = CreateNodeStore()
    @State private var name = ""
    @State private var slug = ""
    @State private var description = ""
    @State private var colorHex = CreateNodeStore.availableColors[0]
    @State private var manualSlug = false
    @FocusState private var focusedField: CreateNodeFocusField?

    var body: some View {
        VStack(spacing: 0) {
            createHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    titleEditor
                    slugEditor
                    parentPicker
                    colorPicker
                    descriptionEditor
                    authHint
                    errorText
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await store.loadParents() }
        .onAppear { focusedField = .name }
        .onChange(of: name) { _, newValue in
            if !manualSlug {
                slug = Self.sanitizedSlug(newValue)
            }
        }
    }

    private var createHeader: some View {
        HStack(spacing: 12) {
            Button { closeOverlay(app) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)

            parentCategoryMenu

            Spacer(minLength: 8)

            Button {
                submit()
            } label: {
                Group {
                    if store.isSubmitting {
                        ProgressView()
                            .tint(Theme.muted(0.55))
                    } else {
                        Text("创建")
                            .font(Theme.body(15, weight: .semibold))
                    }
                }
                .foregroundStyle(canCreate ? Theme.text : Theme.muted(0.38))
                .padding(.horizontal, 14)
                .frame(height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
            .buttonBorderShape(.capsule)
            .disabled(!canCreate)
            .opacity(canCreate ? 1 : 0.58)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    private var titleEditor: some View {
        TextField("节点名称", text: $name, axis: .vertical)
            .font(Theme.heading(34, weight: .bold))
            .foregroundStyle(Theme.text)
            .lineLimit(1...2)
            .focused($focusedField, equals: .name)
            .submitLabel(.next)
            .onSubmit { focusedField = .slug }
    }

    private var slugEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("短链接")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))

            HStack(spacing: 6) {
                Text("n/")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.54))
                TextField("your-node", text: slugBinding)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .slug)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .description }
                Text("\(slug.count)/12")
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(slug.count > 12 ? Theme.danger : Theme.muted(0.42))
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
    }

    private var parentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("所属主题")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))

            parentCategoryMenu
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("节点颜色")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(CreateNodeStore.availableColors, id: \.self) { color in
                    Button {
                        colorHex = color
                    } label: {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(nodeAccentColor(color))
                            .frame(height: 42)
                            .overlay {
                                if color == colorHex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(color == colorHex ? Theme.text.opacity(0.5) : Theme.divider, lineWidth: color == colorHex ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.5))

            ZStack(alignment: .topLeading) {
                if description.isEmpty {
                    Text("写一句这个节点主要讨论什么")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.muted(0.46))
                        .padding(.horizontal, 13)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $description)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .focused($focusedField, equals: .description)
                    .frame(minHeight: 128)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
    }

    private var parentCategoryMenu: some View {
        Menu {
            if store.isLoadingParents {
                Text("加载主题中")
            }
            ForEach(store.parentCategories) { category in
                Button {
                    store.selectedParentID = category.id
                } label: {
                    if store.selectedParentID == category.id {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(selectedParentName)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.muted(0.65))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .buttonStyle(.glass(.regular.tint(Theme.bg.opacity(0.34))))
        .buttonBorderShape(.capsule)
        .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
    }

    @ViewBuilder
    private var authHint: some View {
        if !DiscourseAuth.shared.isAuthenticated {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("需要登录后才能创建节点")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("创建权限仍由 nodeloc.com 的信任等级和数量限制控制。")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.54))
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorText = store.errorText {
            Text(errorText)
                .font(Theme.body(13, weight: .medium))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var slugBinding: Binding<String> {
        Binding {
            slug
        } set: { value in
            manualSlug = true
            slug = Self.sanitizedSlug(value)
        }
    }

    private var selectedParentName: String {
        guard let selectedParentID = store.selectedParentID,
              let category = store.parentCategories.first(where: { $0.id == selectedParentID })
        else {
            return store.isLoadingParents ? "加载中" : "选择主题"
        }
        return category.name
    }

    private var canCreate: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscourseAuth.shared.isAuthenticated
            && (3...50).contains(trimmedName.count)
            && (1...12).contains(slug.count)
            && store.selectedParentID != nil
            && !store.isSubmitting
    }

    private func submit() {
        Task {
            if await store.create(
                name: name,
                slug: slug,
                description: description,
                colorHex: colorHex,
                parentCategoryID: store.selectedParentID
            ) {
                closeOverlay(app)
            }
        }
    }

    private static func sanitizedSlug(_ value: String) -> String {
        var output = ""
        var previousWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            let isAlphanumeric = (48...57).contains(scalar.value)
                || (97...122).contains(scalar.value)
            if isAlphanumeric {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash && !output.isEmpty {
                output.append("-")
                previousWasDash = true
            }
            if output.count >= 12 { break }
        }
        while output.last == "-" {
            output.removeLast()
        }
        return output
    }
}
