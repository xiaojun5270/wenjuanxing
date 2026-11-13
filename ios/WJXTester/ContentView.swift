import SwiftUI

struct ContentView: View {
    @StateObject private var model = SurveyViewModel()
    @FocusState private var focusedField: Field?

    private enum Field {
        case employeeID
        case name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("问卷") {
                        Text(SurveyService.surveyID)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("状态") {
                        Label("测试环境", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("目标")
                }

                Section("答卷") {
                    TextField("6 位工号", text: $model.employeeID)
                        .keyboardType(.numberPad)
                        .textContentType(.username)
                        .focused($focusedField, equals: .employeeID)
                        .onChange(of: model.employeeID) { newValue in
                            model.employeeID = String(newValue.filter(\.isNumber).prefix(6))
                        }

                    TextField("姓名", text: $model.name)
                        .textContentType(.name)
                        .focused($focusedField, equals: .name)

                    Button {
                        focusedField = nil
                        model.randomize()
                    } label: {
                        Label("生成测试数据", systemImage: "dice.fill")
                    }
                }

                Section("提交设置") {
                    Stepper("等待时间：\(model.dwellSeconds) 秒", value: $model.dwellSeconds, in: 5...15)
                    Toggle("我已获授权测试此问卷", isOn: $model.isAuthorized)
                }

                Section {
                    Button {
                        focusedField = nil
                        model.requestSubmission()
                    } label: {
                        HStack {
                            Spacer()
                            if model.isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在提交")
                            } else {
                                Label("提交测试答卷", systemImage: "paperplane.fill")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!model.canSubmit)

                    Button {
                        focusedField = nil
                        model.showsBrowser = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("在浏览器中填写", systemImage: "safari.fill")
                            Spacer()
                        }
                    }
                    .disabled(model.employeeID.count != 6 || model.name.isEmpty)
                }

                statusSection
            }
            .navigationTitle("问卷测试")
            .tint(.green)
            .alert("确认提交", isPresented: $model.showsConfirmation) {
                Button("取消", role: .cancel) {}
                Button("确认提交") {
                    model.submit()
                }
            } message: {
                Text("工号：\(model.employeeID)\n姓名：\(model.name)")
            }
            .sheet(isPresented: $model.showsBrowser) {
                BrowserSheet(employeeID: model.employeeID, name: model.name)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let outcome = model.outcome {
            Section("结果") {
                switch outcome {
                case .success(let answerNumber, let resultURL):
                    Label(
                        answerNumber.map { "提交成功，答卷号 \($0)" } ?? "提交成功",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    if let resultURL {
                        Link("打开结果页", destination: resultURL)
                    }
                case .verificationRequired(let message):
                    Label(message, systemImage: "person.badge.shield.checkmark.fill")
                        .foregroundStyle(.orange)
                    Button("打开浏览器验证") {
                        model.showsBrowser = true
                    }
                case .failure(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        } else if let message = model.errorMessage {
            Section("错误") {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    ContentView()
}
