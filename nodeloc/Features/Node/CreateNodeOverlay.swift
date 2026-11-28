//
//  CreateNodeOverlay.swift
//  nodeloc
//
//  创建节点 (App-iOS-CreateNode): who may create and how many more, then
//  基本信息 (name, address, category, one-line introduction), 外观 (colour),
//  节点规则, 谁可以参与, and agreeing to the 节点管理员守则.
//
//  Limits are the server's own (internal/node/service.go): name 2–50, address
//  2–12 lowercase letters, digits and hyphens, introduction ≤ 500, at most 15
//  rules (title ≤ 100, body ≤ 500). Eligibility is `nodes.create` and
//  `nodes.max_owned` from GET /api/v1/me/permissions against the nodes the
//  reader owns in GET /api/v1/me/nodes. A 422's `fields` land under the input
//  they belong to.
//

import SwiftUI

private enum CreateNodeFocusField: Hashable {
    case name, slug, description
}

private enum Participation: String, CaseIterable {
    case open, restricted, closed

    var title: String {
        switch self {
        case .open: AppString("公开")
        case .restricted: AppString("受限")
        case .closed: AppString("私密")
        }
    }

    var detail: String {
        switch self {
        case .open: AppString("所有人可以浏览和发帖")
        case .restricted: AppString("所有人可以浏览，成员才能发帖")
        case .closed: AppString("只有成员能看到")
        }
    }

    var visibility: String { self == .closed ? "members" : "public" }
    var topicPolicy: String { self == .open ? "anyone" : "members" }
}

private struct RuleDraft: Identifiable {
    let id = UUID()
    var title = ""
    var body = ""
}

struct CreateNodeOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(BrowserState.self) private var browser
    @State private var store = CreateNodeStore()
    @State private var profile = ProfileStore.shared
    @State private var name = ""
    @State private var slug = ""
    @State private var description = ""
    @State private var colorHex = CreateNodeStore.availableColors[0]
    @State private var manualSlug = false
    @State private var rules: [RuleDraft] = []
    @State private var participation: Participation = .open
    @State private var agreed = false
    @State private var attempted = false
    @State private var eligibility: Eligibility?
    @FocusState private var focusedField: CreateNodeFocusField?

    private struct Eligibility {
        let canCreate: Bool
        let maxOwned: Int?
        let owned: Int
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    eligibilityBanner
                    if attempted, !problems.isEmpty { problemSummary }
                    basics
                    appearance
                    rulesSection
                    participationSection
                    agreement
                    if let error = store.errorText, !store.parentCategories.isEmpty {
                        Text(error)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.danger)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 36)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(AppString("创建节点"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { closeOverlay(app) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(AppString("关闭"))
                }
                // Enabled while the form still has problems: a tap lists them
                // at the top (`attempted`), which a greyed button never could.
                PrimaryToolbarAction(
                    title: AppString("创建"),
                    isEnabled: eligibility.map { blockedReason($0) == nil } ?? true,
                    isWorking: store.isSubmitting,
                    action: submit
                )
            }
        }
        .task {
            async let parents: Void = store.loadParents()
            await loadEligibility()
            await parents
        }
        .onChange(of: name) { _, newValue in
            if !manualSlug { slug = Self.sanitizedSlug(newValue) }
        }
    }

    // MARK: Eligibility

    /// Only when creating is blocked: the tier can't create nodes, or the
    /// account already runs as many as its tier allows. Someone who can
    /// create sees no notice at all.
    @ViewBuilder
    private var eligibilityBanner: some View {
        if let eligibility, let text = blockedReason(eligibility) {
            Label(text, systemImage: "exclamationmark.circle")
                .font(Theme.body(14))
                .foregroundStyle(AdminTone.orange.text)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AdminTone.orange.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func blockedReason(_ eligibility: Eligibility) -> String? {
        guard eligibility.canCreate else { return AppString("段位还不够，暂时不能创建节点。升到白银后就可以建。") }
        if let max = eligibility.maxOwned, max >= 0, eligibility.owned >= max {
            return AppString("你名下的节点已经到了你这个段位的上限，升段位后可以再建")
        }
        return nil
    }

    private func loadEligibility() async {
        let client = DiscourseClient()
        async let permissionsCall = try? client.myPermissions()
        async let nodesCall = try? client.myNodes()
        let (permissions, nodes) = await (permissionsCall, nodesCall)
        guard let permissions else { return }
        eligibility = Eligibility(
            canCreate: permissions.permissions.contains("nodes.create"),
            maxOwned: permissions.limits?["nodes.max_owned"],
            owned: (nodes?.joined ?? []).filter { $0.owner == true }.count
        )
        if profile.tierName == nil { await profile.load(isAppAuthed: true) }
    }

    // MARK: Problems

    /// What still needs fixing, field by field — the server's words first.
    private var problems: [(String, String)] {
        var list: [(String, String)] = []
        let server = store.fieldErrors
        func add(_ key: String, _ label: String, local: String?) {
            if let message = server[key] { list.append((label, message)) } else if let local { list.append((label, local)) }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        add("name", AppString("节点名称"), local: (2...50).contains(trimmed.count) ? nil : AppString("请填写 2–50 个字的节点名称"))
        add("slug", AppString("节点地址"), local: (2...12).contains(slug.count) && slug.last != "-" ? nil : AppString("请填写 2–12 位的节点地址"))
        add("parent", AppString("分类"), local: store.selectedParentID == nil ? AppString("请选择一个分类") : nil)
        add("description", AppString("一句话简介"), local: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppString("请写一句话简介") : nil)
        add("rules", AppString("节点规则"), local: rules.contains { $0.title.trimmingCharacters(in: .whitespaces).isEmpty } ? AppString("每条规则的标题要填") : nil)
        if !agreed { list.append((AppString("守则"), AppString("需要先同意节点管理员守则"))) }
        return list
    }

    private var problemSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppString("还有 \(problems.count) 处需要修改"))
                .font(Theme.body(15, weight: .bold))
            ForEach(problems, id: \.0) { label, message in
                Text("\(label)：\(message)")
                    .font(Theme.body(13))
            }
        }
        .foregroundStyle(AdminTone.orange.text)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTone.orange.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func fieldError(_ key: String) -> String? {
        if let server = store.fieldErrors[key] { return server }
        guard attempted else { return nil }
        return problems.first { $0.0 == label(for: key) }?.1
    }

    private func label(for key: String) -> String {
        switch key {
        case "name": AppString("节点名称")
        case "slug": AppString("节点地址")
        case "parent": AppString("分类")
        case "description": AppString("一句话简介")
        default: AppString("节点规则")
        }
    }

    // MARK: Sections

    private func sectionTitle(_ title: String, optional: Bool = false, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(Theme.body(19, weight: .bold))
                if optional {
                    Text(AppString("（可选）")).font(Theme.body(14)).foregroundStyle(Theme.textMuted)
                }
            }
            if let note {
                Text(note).font(Theme.body(13)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func fieldLabel(_ title: String, required: Bool = true, count: String? = nil) -> some View {
        HStack(spacing: 2) {
            Text(title).font(Theme.body(15, weight: .bold))
            if required { Text("*").font(Theme.body(15, weight: .bold)).foregroundStyle(AdminTone.orange.text) }
            Spacer()
            if let count { Text(count).font(Theme.body(12)).foregroundStyle(Theme.textMuted).monospacedDigit() }
        }
    }

    private func hint(_ text: String, error: String?) -> some View {
        Text(error ?? text)
            .font(Theme.body(12))
            .foregroundStyle(error == nil ? Theme.textMuted : Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func box<Content: View>(error: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(error ? Theme.danger : Theme.textFaint.opacity(0.6), lineWidth: 1))
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(AppString("基本信息"), note: AppString("名称可以随时修改；地址会出现在链接里，创建后不能修改。"))

            fieldLabel(AppString("节点名称"), count: "\(name.count) / 50")
            box(error: fieldError("name") != nil) {
                TextField(AppString("例如：露营"), text: $name)
                    .focused($focusedField, equals: .name)
            }
            hint(AppString("显示在节点页顶部和帖子旁，创建后可以修改。"), error: fieldError("name"))

            fieldLabel(AppString("节点地址"), count: "\(slug.count) / 12")
                .padding(.top, 6)
            box(error: fieldError("slug") != nil) {
                HStack(spacing: 8) {
                    Text("n/").font(Theme.body(15, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    TextField("camping", text: Binding(get: { slug }, set: { value in
                        manualSlug = true
                        slug = Self.sanitizedSlug(value, trimTrailingDash: false)
                    }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .slug)
                }
            }
            hint(AppString("小写英文字母、数字和连字符，2–12 位。会出现在链接里，创建后不能修改。"), error: fieldError("slug"))

            fieldLabel(AppString("分类"))
                .padding(.top, 6)
            if store.isLoadingParents && store.parentCategories.isEmpty {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            } else if store.parentCategories.isEmpty, let error = store.errorText {
                HStack(spacing: 12) {
                    Text(error).font(Theme.body(13)).foregroundStyle(Theme.danger)
                    Button(AppString("重试")) { Task { await store.loadParents() } }
                        .foregroundStyle(Theme.accent)
                        .font(Theme.body(13, weight: .semibold))
                }
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(store.parentCategories, id: \.id) { category in
                        Button {
                            store.selectedParentID = category.id
                        } label: {
                            Text(category.name)
                                .font(Theme.body(14, weight: .semibold))
                                .foregroundStyle(store.selectedParentID == category.id ? Theme.bg : Theme.text)
                                .padding(.horizontal, 16)
                                .frame(height: 38)
                                .background(store.selectedParentID == category.id ? Theme.text : Theme.bg, in: Capsule())
                                .overlay(Capsule().strokeBorder(store.selectedParentID == category.id ? Color.clear : Theme.textFaint.opacity(0.6), lineWidth: 1))
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            if let error = fieldError("parent") { hint("", error: error) }

            fieldLabel(AppString("一句话简介"), count: "\(description.count) / 500")
                .padding(.top, 6)
            box(error: fieldError("description") != nil) {
                TextField(AppString("告诉大家这个节点聊什么、适合谁"), text: $description, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(.vertical, 12)
                    .focused($focusedField, equals: .description)
            }
            hint(AppString("会显示在节点卡片和搜索结果里。"), error: fieldError("description"))
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(AppString("外观"), optional: true, note: AppString("不设置也可以，系统会用名称首字和主题色生成图标。"))
            Text(AppString("主题色")).font(Theme.body(15, weight: .bold))
            HStack(spacing: 10) {
                ForEach(CreateNodeStore.availableColors, id: \.self) { hex in
                    Button { colorHex = hex } label: {
                        Circle()
                            .fill(nodeAccentColor(hex))
                            .frame(width: 32, height: 32)
                            .overlay {
                                if colorHex == hex {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(hex)
                }
                // Any other colour, from the system picker. Opaque only: the
                // server keeps six hex digits (`color`, ^[0-9a-f]{6}$).
                ColorPicker(selection: customColor, supportsOpacity: false) { EmptyView() }
                    .labelsHidden()
                    .frame(width: 32, height: 32)
                    .overlay {
                        if !CreateNodeStore.availableColors.contains(colorHex) {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(AppString("自定义颜色"))
            }
        }
    }

    /// The system picker's colour, written back as the six hex digits the
    /// server takes.
    private var customColor: Binding<Color> {
        Binding(
            get: { nodeAccentColor(colorHex) },
            set: { colorHex = Self.hex(of: $0) ?? colorHex }
        )
    }

    static func hex(of color: Color) -> String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        // sRGB, clamped: the picker can hand back extended-range values.
        guard let srgb = UIColor(color).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count >= 3 else {
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
            return String(format: "%02X%02X%02X", Int(round(min(max(red, 0), 1) * 255)), Int(round(min(max(green, 0), 1) * 255)), Int(round(min(max(blue, 0), 1) * 255)))
        }
        let c = parts.prefix(3).map { Int(round(min(max($0, 0), 1) * 255)) }
        return String(format: "%02X%02X%02X", c[0], c[1], c[2])
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(AppString("节点规则"), optional: true, note: AppString("每条规则一个简短标题，下面写具体说明。会显示在节点侧栏和发帖页，最多 15 条。"))
            ForEach($rules) { $rule in
                let index = (rules.firstIndex { $0.id == rule.id } ?? 0) + 1
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index)")
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        .background(Theme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(AppString("规则标题"), text: $rule.title)
                            .font(Theme.body(15, weight: .semibold))
                        TextField(AppString("具体说明（可选）"), text: $rule.body, axis: .vertical)
                            .font(Theme.body(14))
                            .lineLimit(1...5)
                        Text("\(rule.body.count) / 500")
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Button(role: .destructive) {
                        rules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppString("删除这条规则"))
                }
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if rules.count < 15 {
                Button {
                    rules.append(RuleDraft())
                } label: {
                    Label(AppString("添加一条规则"), systemImage: "plus")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            if let error = fieldError("rules"), !rules.isEmpty { hint("", error: error) }
        }
    }

    private var participationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(AppString("谁可以参与"), note: AppString("创建后可以随时调整。"))
            ForEach(Participation.allCases, id: \.self) { option in
                Button { participation = option } label: {
                    HStack(spacing: 12) {
                        Image(systemName: participation == option ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(participation == option ? Theme.accent : Theme.textFaint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(Theme.body(15, weight: .bold)).foregroundStyle(Theme.text)
                            Text(option.detail).font(Theme.body(13)).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(participation == option ? Theme.accent : Theme.divider, lineWidth: participation == option ? 1.5 : 1))
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private var agreement: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { agreed.toggle() } label: {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(agreed ? Theme.accent : Theme.textFaint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppString("同意节点管理员守则"))
            (Text(AppString("我已阅读并同意 ")) + Text(AppString("《节点管理员守则》")).foregroundColor(Theme.accent) + Text(AppString("，会对节点内容负责")))
                .font(Theme.body(14))
                .foregroundStyle(attempted && !agreed ? Theme.danger : Theme.text)
                .onTapGesture {
                    if let url = nodelocSiteURL("/node-guidelines") { LinkRouter.open(url, app: app, browser: browser) }
                }
        }
    }

    // MARK: Submit

    private var canSubmit: Bool {
        DiscourseAuth.shared.isAuthenticated && problems.isEmpty && !store.isSubmitting && (eligibility.map { blockedReason($0) == nil } ?? true)
    }

    private func submit() {
        attempted = true
        store.fieldErrors = [:]
        guard problems.isEmpty else { return }
        Task {
            if await store.create(
                name: name,
                slug: slug,
                description: description,
                colorHex: colorHex,
                parentCategoryID: store.selectedParentID,
                visibility: participation.visibility,
                topicPolicy: participation.topicPolicy,
                rules: rules.map { ($0.title.trimmingCharacters(in: .whitespaces), $0.body.trimmingCharacters(in: .whitespaces)) }
            ) {
                let created = store.createdNode
                closeOverlay(app)
                // Straight into the new node, as the web does after creating.
                if let created, !created.slug.isEmpty {
                    app.openNode(slug: created.slug)
                }
            }
        }
    }

    private static func sanitizedSlug(_ value: String, trimTrailingDash: Bool = true) -> String {
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
        while trimTrailingDash, output.last == "-" {
            output.removeLast()
        }
        return output
    }
}
