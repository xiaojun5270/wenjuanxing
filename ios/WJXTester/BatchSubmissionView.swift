import SwiftUI

struct BatchSubmissionView: View {
    @StateObject private var model = BatchViewModel()
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if model.rawList.isEmpty {
                            Text("123456,张三\n李四")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $model.rawList)
                            .frame(minHeight: 150)
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
                    Text("每行填写“6位工号,姓名”；仅填写姓名时自动生成工号。")
                }

                Section("执行设置") {
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
                            Label("停止任务", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            isEditorFocused = false
                            model.requestStart()
                        } label: {
                            HStack {
                                Spacer()
                                Label("开始批量提交", systemImage: "paperplane.fill")
                                Spacer()
                            }
                        }
                        .disabled(!model.canStart)
                    }
                }

                if !model.items.isEmpty {
                    Section("进度") {
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
            .alert("确认批量提交", isPresented: $model.showsConfirmation) {
                Button("取消", role: .cancel) {}
                Button("确认提交") {
                    model.start()
                }
            } message: {
                Text("共 \(model.inputCount) 条，并发 \(model.concurrency)，等待 \(model.dwellSeconds) 秒。")
            }
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
                Text(item.entry.employeeID)
                    .font(.caption.monospacedDigit())
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
