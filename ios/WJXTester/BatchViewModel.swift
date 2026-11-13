import Foundation
import Combine
import UIKit

struct RosterDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var employeeID: String
    var email: String

    init(id: UUID = UUID(), name: String = "", employeeID: String = "", email: String = "") {
        self.id = id
        self.name = name
        self.employeeID = employeeID
        self.email = email
    }
}

enum BatchStartMode: String, CaseIterable, Identifiable {
    case immediate = "立即"
    case scheduled = "定时"

    var id: Self { self }
}

enum BatchLogLevel {
    case info
    case success
    case warning
    case error
}

struct BatchLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: BatchLogLevel
    let message: String
}

struct BatchEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let employeeID: String
    let email: String
    let nameTopic: Int
    let employeeIDTopic: Int
    let emailTopic: Int

    var answers: [Int: String] {
        var values: [Int: String] = [:]
        values[nameTopic] = name
        values[employeeIDTopic] = employeeID
        values[emailTopic] = email
        return values
    }

    var logLabel: String {
        "\(name)（\(employeeID)）"
    }
}

enum BatchEntryState: Equatable, Sendable {
    case queued
    case running
    case success(String?)
    case verificationRequired(String)
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .queued, .running:
            return false
        case .success, .verificationRequired, .failed, .cancelled:
            return true
        }
    }
}

struct BatchItem: Identifiable, Equatable {
    let entry: BatchEntry
    var state: BatchEntryState

    var id: UUID { entry.id }
}

private enum BatchExecutionResult: Sendable {
    case outcome(SubmissionOutcome)
    case failed(String)
    case cancelled
}

private struct BatchCompletion: Sendable {
    let id: UUID
    let result: BatchExecutionResult
}

private enum BatchInputError: LocalizedError {
    case empty
    case tooMany(Int)
    case invalidRecord(Int, String)
    case duplicateTopics

    var errorDescription: String? {
        switch self {
        case .empty:
            return "请先增加并填写名单。"
        case .tooMany(let count):
            return "当前有 \(count) 份，隐藏浏览器模式单次最多处理 10 份。"
        case .invalidRecord(let index, let reason):
            return "名单 \(index) 格式错误：\(reason)"
        case .duplicateTopics:
            return "姓名、工号、邮箱的问卷题号不能重复。"
        }
    }
}

@MainActor
final class BatchViewModel: ObservableObject {
    @Published var surveyURLString: String {
        didSet { UserDefaults.standard.set(surveyURLString, forKey: "surveyURL") }
    }
    @Published var rosterEntries = [RosterDraft()] {
        didSet {
            if !isRunning {
                items = []
                errorMessage = nil
            }
        }
    }
    @Published var nameTopic = 2
    @Published var employeeIDTopic = 1
    @Published var emailTopic = 3
    @Published var startMode = BatchStartMode.immediate {
        didSet {
            if startMode == .scheduled && scheduledDate <= Date().addingTimeInterval(1) {
                scheduledDate = Date().addingTimeInterval(5 * 60)
            }
        }
    }
    @Published var scheduledDate = Date().addingTimeInterval(5 * 60)
    @Published private(set) var scheduledAt: Date?
    @Published var dwellSeconds = 6
    @Published var isAuthorized = false
    @Published var isRunning = false
    @Published var showsConfirmation = false
    @Published var items: [BatchItem] = []
    @Published private(set) var logs: [BatchLogEntry] = []
    @Published var errorMessage: String?

    private let browserEngine = HeadlessBrowserEngine()
    private var executionTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        surveyURLString = UserDefaults.standard.string(forKey: "surveyURL")
            ?? SurveyTarget.defaultURLString
    }

    var surveyURL: URL? {
        SurveyTarget.parse(surveyURLString)
    }

    func reloadSurveyURL() {
        guard !isRunning,
              let saved = UserDefaults.standard.string(forKey: "surveyURL"),
              saved != surveyURLString else { return }
        surveyURLString = saved
    }

    var inputCount: Int {
        rosterEntries.count
    }

    var completedCount: Int {
        items.filter { $0.state.isFinished }.count
    }

    var successCount: Int {
        items.filter {
            if case .success = $0.state { return true }
            return false
        }.count
    }

    var canStart: Bool {
        surveyURL != nil
            && inputCount > 0 && inputCount <= 10
            && topicsAreValid
            && rosterEntries.allSatisfy { validationIssues(for: $0).isEmpty }
            && isAuthorized && !isRunning
    }

    var topicsAreValid: Bool {
        let topics = [nameTopic, employeeIDTopic, emailTopic]
        return topics.allSatisfy { (1...200).contains($0) }
            && Set(topics).count == topics.count
    }

    var isWaitingForSchedule: Bool {
        isRunning && scheduledAt != nil
    }

    func addRosterEntry() {
        guard !isRunning, rosterEntries.count < 10 else { return }
        rosterEntries.append(RosterDraft())
    }

    func removeRosterEntry(_ id: UUID) {
        guard !isRunning else { return }
        rosterEntries.removeAll(where: { $0.id == id })
    }

    func clearRoster() {
        guard !isRunning else { return }
        rosterEntries = []
    }

    func ordinal(for id: UUID) -> Int {
        (rosterEntries.firstIndex(where: { $0.id == id }) ?? 0) + 1
    }

    func validationIssues(for entry: RosterDraft) -> [String] {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let employeeID = entry.employeeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [String] = []

        if name.isEmpty { issues.append("缺少姓名") }
        if employeeID.isEmpty { issues.append("缺少工号") }
        if email.isEmpty {
            issues.append("缺少邮箱")
        } else if !isValidEmail(email) {
            issues.append("邮箱格式无效")
        }
        if name.count > 100 { issues.append("姓名过长") }
        if employeeID.count > 100 { issues.append("工号过长") }
        if email.count > 254 { issues.append("邮箱过长") }
        if !employeeID.isEmpty,
           rosterEntries.filter({
               $0.employeeID.trimmingCharacters(in: .whitespacesAndNewlines) == employeeID
           }).count > 1 {
            issues.append("工号重复")
        }
        if !email.isEmpty,
           rosterEntries.filter({
               $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                   == email.lowercased()
           }).count > 1 {
            issues.append("邮箱重复")
        }
        return issues
    }

    func clearLogs() {
        logs = []
    }

    func requestStart() {
        guard canStart else { return }
        if startMode == .scheduled && scheduledDate <= Date().addingTimeInterval(1) {
            errorMessage = "定时时间必须晚于当前时间。"
            appendLog(.warning, errorMessage ?? "定时时间无效")
            return
        }
        do {
            _ = try parseEntries()
            errorMessage = nil
            showsConfirmation = true
        } catch {
            errorMessage = error.localizedDescription
            appendLog(.error, error.localizedDescription)
        }
    }

    func start() {
        guard canStart else { return }
        if startMode == .scheduled && scheduledDate <= Date() {
            errorMessage = "定时时间已过，请重新选择。"
            appendLog(.warning, errorMessage ?? "定时时间已过")
            return
        }
        guard let selectedSurveyURL = surveyURL else {
            errorMessage = "请输入有效的 HTTPS 问卷地址。"
            appendLog(.error, errorMessage ?? "问卷地址无效")
            return
        }
        let entries: [BatchEntry]
        do {
            entries = try parseEntries()
        } catch {
            errorMessage = error.localizedDescription
            appendLog(.error, error.localizedDescription)
            return
        }

        items = entries.map { BatchItem(entry: $0, state: .queued) }
        errorMessage = nil
        isRunning = true

        let selectedDwell = dwellSeconds
        if startMode == .scheduled {
            let fireDate = scheduledDate
            scheduledAt = fireDate
            appendLog(
                .info,
                "已设置定时任务：\(entries.count) 份，计划 \(fireDate.formatted(date: .abbreviated, time: .shortened)) 开始"
            )
            executionTask = Task { [weak self] in
                guard let self else { return }
                let delay = max(0, fireDate.timeIntervalSinceNow)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                scheduledAt = nil
                appendLog(.info, "定时时间已到，开始提交")
                beginBackgroundExecution()
                await run(
                    entries: entries,
                    surveyURL: selectedSurveyURL,
                    dwellSeconds: selectedDwell
                )
            }
            return
        }

        scheduledAt = nil
        appendLog(.info, "同时启动 \(entries.count) 个独立隐藏浏览器")
        beginBackgroundExecution()
        executionTask = Task { [weak self] in
            guard let self else { return }
            await run(
                entries: entries,
                surveyURL: selectedSurveyURL,
                dwellSeconds: selectedDwell
            )
        }
    }

    func cancel() {
        appendLog(.warning, isWaitingForSchedule ? "定时任务已取消" : "已请求停止运行任务")
        executionTask?.cancel()
        browserEngine.cancelAll()
        if scheduledAt != nil {
            for index in items.indices where !items[index].state.isFinished {
                items[index].state = .cancelled
            }
            scheduledAt = nil
            isRunning = false
            executionTask = nil
        }
    }

    private func run(
        entries: [BatchEntry],
        surveyURL: URL,
        dwellSeconds: Int
    ) async {
        let submissionGate = BrowserSubmissionGate(participants: entries.count)
        await withTaskGroup(of: BatchCompletion.self) { group in
            for entry in entries {
                mark(entry.id, as: .running)
                appendLog(.info, "\(entry.logLabel)：隐藏浏览器已启动")
                add(
                    entry,
                    surveyURL: surveyURL,
                    dwellSeconds: dwellSeconds,
                    gate: submissionGate,
                    to: &group
                )
            }

            while let completion = await group.next() {
                apply(completion)
                if Task.isCancelled {
                    group.cancelAll()
                }
            }
        }

        if Task.isCancelled {
            let responseCount = items.filter {
                switch $0.state {
                case .success, .verificationRequired, .failed:
                    return true
                case .queued, .running, .cancelled:
                    return false
                }
            }.count
            for index in items.indices where !items[index].state.isFinished {
                items[index].state = .cancelled
            }
            appendLog(
                .warning,
                "任务已停止：收到响应 \(responseCount) / \(items.count)，成功 \(successCount)"
            )
        } else {
            appendLog(.success, "批量任务完成：成功 \(successCount) / \(items.count)")
        }
        isRunning = false
        scheduledAt = nil
        executionTask = nil
        endBackgroundExecution()
    }

    private func add(
        _ entry: BatchEntry,
        surveyURL: URL,
        dwellSeconds: Int,
        gate: BrowserSubmissionGate,
        to group: inout TaskGroup<BatchCompletion>
    ) {
        let browserEngine = browserEngine
        group.addTask {
            if Task.isCancelled {
                return BatchCompletion(id: entry.id, result: .cancelled)
            }
            let outcome = await browserEngine.submit(
                id: entry.id,
                surveyURL: surveyURL,
                answers: entry.answers,
                dwellSeconds: dwellSeconds,
                gate: gate
            )
            if Task.isCancelled {
                return BatchCompletion(id: entry.id, result: .cancelled)
            }
            return BatchCompletion(id: entry.id, result: .outcome(outcome))
        }
    }

    private func apply(_ completion: BatchCompletion) {
        let entry = items.first(where: { $0.id == completion.id })?.entry
        let prefix = entry?.logLabel ?? "记录"
        switch completion.result {
        case .outcome(.success(let answerNumber, _)):
            mark(completion.id, as: .success(answerNumber))
            let suffix = answerNumber.map { "，答卷号 \($0)" } ?? ""
            appendLog(.success, "\(prefix)：提交成功\(suffix)")
        case .outcome(.verificationRequired(let message)):
            mark(completion.id, as: .verificationRequired(message))
            appendLog(.warning, "\(prefix)：需要安全验证，\(message)")
        case .outcome(.failure(let message)), .failed(let message):
            mark(completion.id, as: .failed(message))
            appendLog(.error, "\(prefix)：提交失败，\(message)")
        case .cancelled:
            mark(completion.id, as: .cancelled)
            appendLog(.warning, "\(prefix)：已取消")
        }
    }

    private func appendLog(_ level: BatchLogLevel, _ message: String) {
        logs.insert(
            BatchLogEntry(timestamp: Date(), level: level, message: message),
            at: 0
        )
        if logs.count > 500 {
            logs.removeLast(logs.count - 500)
        }
    }

    private func mark(_ id: UUID, as state: BatchEntryState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private func parseEntries() throws -> [BatchEntry] {
        guard !rosterEntries.isEmpty else { throw BatchInputError.empty }
        guard rosterEntries.count <= 10 else {
            throw BatchInputError.tooMany(rosterEntries.count)
        }
        guard topicsAreValid else { throw BatchInputError.duplicateTopics }

        var entries: [BatchEntry] = []

        for (offset, draft) in rosterEntries.enumerated() {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let employeeID = draft.employeeID.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
            let issues = validationIssues(for: draft)
            guard issues.isEmpty else {
                throw BatchInputError.invalidRecord(offset + 1, issues.joined(separator: "、"))
            }
            entries.append(
                BatchEntry(
                    id: draft.id,
                    name: name,
                    employeeID: employeeID,
                    email: email,
                    nameTopic: nameTopic,
                    employeeIDTopic: employeeIDTopic,
                    emailTopic: emailTopic
                )
            )
        }
        return entries
    }

    private func isValidEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix(".") else {
            return false
        }
        return true
    }

    private func beginBackgroundExecution() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Batch survey submission") {
            Task { @MainActor [weak self] in
                self?.appendLog(.warning, "系统后台执行时间已用尽，任务即将停止")
                self?.cancel()
            }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
