import SwiftUI
import UIKit

struct BatchSubmissionView: View {
    @StateObject private var model = BatchViewModel()
    @State private var showsRosterManager = false

    var body: some View {
        NavigationStack {
            Form {
                Section("问卷") {
                    TextField("https://v.wjx.cn/vm/xxxx.aspx", text: $model.surveyURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isRunning || model.isDetectingFields)
                    LabeledContent("状态") {
                        if model.surveyURL != nil {
                            Label("地址有效", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("地址无效", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("问卷字段") {
                    Button {
                        model.detectSurveyFields()
                    } label: {
                        HStack {
                            if model.isDetectingFields {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在识别")
                            } else {
                                Label("自动识别姓名、工号、邮箱", systemImage: "viewfinder")
                            }
                            Spacer()
                        }
                    }
                    .disabled(model.surveyURL == nil || model.isRunning || model.isDetectingFields)

                    if let message = model.fieldDetectionMessage {
                        Label(
                            message,
                            systemImage: model.fieldDetectionSucceeded
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            model.fieldDetectionSucceeded
                                ? Color.green
                                : (message.hasPrefix("已识别") ? Color.orange : Color.red)
                        )
                    }

                    Stepper("姓名题号：\(model.nameTopic)", value: $model.nameTopic, in: 1...200)
                        .disabled(model.isRunning)
                    Stepper("工号题号：\(model.employeeIDTopic)", value: $model.employeeIDTopic, in: 1...200)
                        .disabled(model.isRunning)
                    Stepper("邮箱题号（可选）：\(model.emailTopic)", value: $model.emailTopic, in: 1...200)
                        .disabled(model.isRunning)
                    if !model.topicsAreValid {
                        Label(
                            model.hasAnyEmail
                                ? "姓名、工号、邮箱题号不能重复"
                                : "姓名和工号题号不能重复",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    LabeledContent("名单数量") {
                        Text("\(model.inputCount) 份")
                    }
                    LabeledContent("完整状态") {
                        if model.rosterEntries.isEmpty {
                            Text("暂无名单")
                                .foregroundStyle(.secondary)
                        } else if model.incompleteRosterCount == 0 {
                            Label("全部完整", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label(
                                "\(model.incompleteRosterCount) 份待完善",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    Button {
                        showsRosterManager = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("管理名单", systemImage: "person.3.fill")
                            Spacer()
                        }
                    }
                } header: {
                    Text("名单")
                } footer: {
                    Text("名单已移至导航栏菜单，每份对应一个独立隐藏浏览器。")
                }

                Section("执行设置") {
                    Picker("开始方式", selection: $model.startMode) {
                        ForEach(BatchStartMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)

                    if model.startMode == .scheduled {
                        DatePicker(
                            "提交时间",
                            selection: $model.scheduledDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .disabled(model.isRunning)
                    }

                    LabeledContent("提交引擎") {
                        Label("隐藏 WebKit", systemImage: "safari.fill")
                            .foregroundStyle(.blue)
                    }
                    LabeledContent("后台续跑") {
                        Label(
                            model.isBackgroundExecutionActive ? "已申请" : "任务启动时申请",
                            systemImage: model.isBackgroundExecutionActive
                                ? "checkmark.circle.fill"
                                : "clock"
                        )
                        .foregroundStyle(
                            model.isBackgroundExecutionActive ? Color.green : Color.secondary
                        )
                    }
                    Toggle("我已获授权测试此问卷", isOn: $model.isAuthorized)
                        .disabled(model.isRunning)
                }

                Section {
                    if model.isRunning {
                        Button(role: .destructive) {
                            model.cancel()
                        } label: {
                            Label(
                                model.isWaitingForSchedule ? "取消定时" : "停止任务",
                                systemImage: "stop.fill"
                            )
                        }
                    } else {
                        Button {
                            model.requestStart()
                        } label: {
                            HStack {
                                Spacer()
                                Label(
                                    model.startMode == .scheduled ? "设置定时提交" : "开始批量提交",
                                    systemImage: model.startMode == .scheduled
                                        ? "clock.badge.checkmark.fill"
                                        : "paperplane.fill"
                                )
                                Spacer()
                            }
                        }
                        .disabled(!model.canStart)
                    }
                }

                if !model.logs.isEmpty {
                    Section {
                        ForEach(model.logs) { entry in
                            BatchLogRow(entry: entry)
                        }
                    } header: {
                        HStack {
                            Text("运行日志")
                            Spacer()
                            Button {
                                model.clearLogs()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("清空日志")
                        }
                    }
                }

                if !model.items.isEmpty {
                    Section("进度") {
                        if let scheduledAt = model.scheduledAt {
                            LabeledContent("计划提交") {
                                Text(scheduledAt, format: .dateTime.month().day().hour().minute())
                            }
                            LabeledContent("倒计时") {
                                Text(scheduledAt, style: .timer)
                                    .monospacedDigit()
                            }
                        }
                        ProgressView(
                            value: Double(model.completedCount),
                            total: Double(model.items.count)
                        )
                        LabeledContent("完成") {
                            Text("\(model.completedCount) / \(model.items.count)")
                        }
                        LabeledContent("成功") {
                            Text("\(model.successCount)")
                                .foregroundStyle(.green)
                        }

                        ForEach(model.items) { item in
                            BatchItemRow(item: item)
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section("错误") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

            }
            .navigationTitle("批量提交")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            showsRosterManager = true
                        } label: {
                            Label("名单管理", systemImage: "person.3.fill")
                        }

                        Button {
                            model.addRosterEntry()
                            showsRosterManager = true
                        } label: {
                            Label("新增名单", systemImage: "person.badge.plus")
                        }
                        .disabled(model.isRunning || model.rosterEntries.count >= 10)

                        if !model.logs.isEmpty {
                            Divider()
                            Button(role: .destructive) {
                                model.clearLogs()
                            } label: {
                                Label("清空运行日志", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("菜单")
                }
            }
            .onAppear {
                model.reloadSurveyURL()
            }
            .sheet(isPresented: $showsRosterManager) {
                RosterManagementView(model: model)
            }
            .alert("确认批量提交", isPresented: $model.showsConfirmation) {
                Button("取消", role: .cancel) {}
                Button("确认提交") {
                    model.start()
                }
            } message: {
                Text(
                    confirmationTopics
                    + confirmationTiming
                    + "共 \(model.inputCount) 份，页面预加载完成后统一提交。"
                )
            }
        }
    }

    private var confirmationTiming: String {
        guard model.startMode == .scheduled else { return "" }
        return "定时：\(model.scheduledFireDate.formatted(date: .abbreviated, time: .standard))\n"
    }

    private var confirmationTopics: String {
        if model.hasAnyEmail {
            return "字段题号：姓名 \(model.nameTopic)、工号 \(model.employeeIDTopic)、邮箱 \(model.emailTopic)\n"
        }
        return "字段题号：姓名 \(model.nameTopic)、工号 \(model.employeeIDTopic)、邮箱跳过\n"
    }
}

private struct RosterManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BatchViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("名单数量") {
                        Text("\(model.inputCount) / 10")
                    }
                    LabeledContent("资料完整") {
                        Text("\(model.completeRosterCount) 份")
                            .foregroundStyle(
                                model.incompleteRosterCount == 0 ? Color.green : Color.primary
                            )
                    }
                    if model.incompleteRosterCount > 0 {
                        LabeledContent("待完善") {
                            Text("\(model.incompleteRosterCount) 份")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("概览")
                }

                Section {
                    if model.rosterEntries.isEmpty {
                        Label("暂无名单", systemImage: "person.crop.circle.badge.plus")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($model.rosterEntries) { $entry in
                        RosterEntryCard(
                            number: model.ordinal(for: entry.id),
                            entry: $entry,
                            issues: model.validationIssues(for: entry),
                            isDisabled: model.isRunning,
                            onDelete: { model.removeRosterEntry(entry.id) }
                        )
                        .listRowInsets(
                            EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
                        )
                        .listRowBackground(Color.clear)
                    }

                    Button {
                        model.addRosterEntry()
                    } label: {
                        HStack {
                            Spacer()
                            Label("增加名单", systemImage: "plus.circle.fill")
                            Spacer()
                        }
                    }
                    .disabled(model.isRunning || model.rosterEntries.count >= 10)

                    if !model.rosterEntries.isEmpty {
                        Button(role: .destructive) {
                            model.clearRoster()
                        } label: {
                            HStack {
                                Spacer()
                                Label("清空名单", systemImage: "trash")
                                Spacer()
                            }
                        }
                        .disabled(model.isRunning)
                    }
                } header: {
                    Text("名单")
                } footer: {
                    Text("姓名和工号必填，邮箱可选；最多 10 份。")
                }
            }
            .navigationTitle("名单管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RosterEntryCard: View {
    @State private var showsDeleteConfirmation = false

    let number: Int
    @Binding var entry: RosterDraft
    let issues: [String]
    let isDisabled: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("名单 \(number)")
                        .font(.subheadline.bold())
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                Image(systemName: issues.isEmpty ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(issues.isEmpty ? Color.green : Color.secondary)
                    .frame(width: 28, height: 28)

                Button {
                    showsDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除名单 \(number)")
                .disabled(isDisabled)
            }

            HStack(alignment: .top, spacing: 10) {
                RosterField(
                    title: "姓名",
                    placeholder: "姓名",
                    text: $entry.name,
                    keyboardType: .default
                )
                RosterField(
                    title: "工号",
                    placeholder: "工号",
                    text: $entry.employeeID,
                    keyboardType: .default
                )
            }

            RosterField(
                title: "邮箱（可选）",
                placeholder: "无邮箱时留空",
                text: $entry.email,
                keyboardType: .emailAddress
            )
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusColor.opacity(0.35), lineWidth: 1)
        }
        .alert("删除名单 \(number)？", isPresented: $showsDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("删除后无法恢复。")
        }
        .disabled(isDisabled)
    }

    private var statusText: String {
        issues.isEmpty ? "资料完整" : issues.joined(separator: "、")
    }

    private var statusColor: Color {
        if issues.isEmpty { return .green }
        if issues.contains(where: { $0.contains("无效") || $0.contains("重复") }) {
            return .red
        }
        return .orange
    }
}

private struct RosterField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboardType: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BatchLogRow: View {
    let entry: BatchLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    private var icon: String {
        switch entry.level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct BatchItemRow: View {
    let item: BatchItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.entry.name)
                    .font(.body)
                Text(itemSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)
        }
    }

    private var detail: String? {
        switch item.state {
        case .success(let answerNumber):
            return answerNumber.map { "答卷号 \($0)" }
        case .verificationRequired(let message), .failed(let message):
            return message
        case .queued, .running, .cancelled:
            return nil
        }
    }

    private var itemSubtitle: String {
        item.entry.email.isEmpty
            ? item.entry.employeeID
            : "\(item.entry.employeeID) · \(item.entry.email)"
    }

    private var statusIcon: String {
        switch item.state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .verificationRequired: return "person.badge.shield.checkmark.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .queued: return .secondary
        case .running: return .blue
        case .success: return .green
        case .verificationRequired: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
