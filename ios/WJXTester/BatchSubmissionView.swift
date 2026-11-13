import SwiftUI

struct BatchSubmissionView: View {
    @StateObject private var model = BatchViewModel()
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("问卷") {
                    TextField("https://v.wjx.cn/vm/xxxx.aspx", text: $model.surveyURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isRunning)
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

                Section {
                    Picker("名单模式", selection: $model.rosterMode) {
                        ForEach(RosterMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)

                    Stepper(
                        "\(model.rosterMode.rawValue)题号：\(model.topicNumber)",
                        value: $model.topicNumber,
                        in: 1...200
                    )
                    .disabled(model.isRunning)

                    ZStack(alignment: .topLeading) {
                        if model.rawList.isEmpty {
                            Text(model.rosterMode.placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $model.rawList)
                            .frame(minHeight: 150)
                            .keyboardType(model.rosterMode.keyboardType)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isEditorFocused)
                            .disabled(model.isRunning)
                    }

                    HStack {
                        Label("\(model.inputCount) 条", systemImage: "list.number")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.loadExample()
                        } label: {
                            Label("示例", systemImage: "doc.badge.plus")
                        }
                        .disabled(model.isRunning)
                        Button(role: .destructive) {
                            model.clear()
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .disabled(model.isRunning || model.rawList.isEmpty)
                    }
                } header: {
                    Text("名单")
                } footer: {
                    Text("每行填写一个\(model.rosterMode.rawValue)，最多 500 条。")
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

                    Stepper("等待时间：\(model.dwellSeconds) 秒", value: $model.dwellSeconds, in: 1...15)
                        .disabled(model.isRunning)
                    Stepper("并发数量：\(model.concurrency)", value: $model.concurrency, in: 1...10)
                        .disabled(model.isRunning)
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
                            isEditorFocused = false
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
            .onAppear {
                model.reloadSurveyURL()
            }
            .alert("确认批量提交", isPresented: $model.showsConfirmation) {
                Button("取消", role: .cancel) {}
                Button("确认提交") {
                    model.start()
                }
            } message: {
                Text(
                    "问卷字段：\(model.rosterMode.rawValue)（第 \(model.topicNumber) 题）\n"
                    + confirmationTiming
                    + "共 \(model.inputCount) 条，并发 \(model.concurrency)，等待 \(model.dwellSeconds) 秒。"
                )
            }
        }
    }

    private var confirmationTiming: String {
        guard model.startMode == .scheduled else { return "" }
        return "定时：\(model.scheduledDate.formatted(date: .abbreviated, time: .shortened))\n"
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
                Text(item.entry.value)
                    .font(.body)
                Text("\(item.entry.mode.rawValue) · 第 \(item.entry.topic) 题")
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
