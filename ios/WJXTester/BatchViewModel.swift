import Foundation
import Combine
import UIKit

struct BatchEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let employeeID: String
    let name: String
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
    case invalidLine(Int, String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "请先输入名单。"
        case .tooMany(let count):
            return "当前有 \(count) 条，单次最多处理 500 条。"
        case .invalidLine(let line, let reason):
            return "第 \(line) 行格式错误：\(reason)"
        }
    }
}

@MainActor
final class BatchViewModel: ObservableObject {
    @Published var rawList = ""
    @Published var dwellSeconds = 6
    @Published var concurrency = 3
    @Published var isAuthorized = false
    @Published var isRunning = false
    @Published var showsConfirmation = false
    @Published var items: [BatchItem] = []
    @Published var errorMessage: String?

    private let service = SurveyService()
    private var executionTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var inputCount: Int {
        normalizedLines.count
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
        inputCount > 0 && inputCount <= 500 && isAuthorized && !isRunning
    }

    func loadExample() {
        var used = Set<String>()
        rawList = (1...10).map { index in
            let employeeID = makeUniqueEmployeeID(used: &used)
            used.insert(employeeID)
            return "\(employeeID),测试\(String(format: "%03d", index))"
        }.joined(separator: "\n")
        items = []
        errorMessage = nil
    }

    func clear() {
        guard !isRunning else { return }
        rawList = ""
        items = []
        errorMessage = nil
    }

    func requestStart() {
        guard canStart else { return }
        do {
            _ = try parseEntries()
            errorMessage = nil
            showsConfirmation = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func start() {
        guard canStart else { return }
        let entries: [BatchEntry]
        do {
            entries = try parseEntries()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        items = entries.map { BatchItem(entry: $0, state: .queued) }
        errorMessage = nil
        isRunning = true
        beginBackgroundExecution()

        let selectedConcurrency = concurrency
        let selectedDwell = dwellSeconds
        executionTask = Task { [weak self] in
            guard let self else { return }
            await run(entries: entries, concurrency: selectedConcurrency, dwellSeconds: selectedDwell)
        }
    }

    func cancel() {
        executionTask?.cancel()
    }

    private func run(entries: [BatchEntry], concurrency: Int, dwellSeconds: Int) async {
        await withTaskGroup(of: BatchCompletion.self) { group in
            var nextIndex = 0
            let initialCount = min(concurrency, entries.count)

            for _ in 0..<initialCount {
                let entry = entries[nextIndex]
                nextIndex += 1
                mark(entry.id, as: .running)
                add(entry, dwellSeconds: dwellSeconds, to: &group)
            }

            while let completion = await group.next() {
                apply(completion)

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                if nextIndex < entries.count {
                    let entry = entries[nextIndex]
                    nextIndex += 1
                    mark(entry.id, as: .running)
                    add(entry, dwellSeconds: dwellSeconds, to: &group)
                }
            }
        }

        if Task.isCancelled {
            for index in items.indices where !items[index].state.isFinished {
                items[index].state = .cancelled
            }
        }
        isRunning = false
        executionTask = nil
        endBackgroundExecution()
    }

    private func add(
        _ entry: BatchEntry,
        dwellSeconds: Int,
        to group: inout TaskGroup<BatchCompletion>
    ) {
        let service = service
        group.addTask {
            if Task.isCancelled {
                return BatchCompletion(id: entry.id, result: .cancelled)
            }
            do {
                let outcome = try await service.submit(
                    employeeID: entry.employeeID,
                    name: entry.name,
                    dwellSeconds: dwellSeconds
                )
                return BatchCompletion(id: entry.id, result: .outcome(outcome))
            } catch is CancellationError {
                return BatchCompletion(id: entry.id, result: .cancelled)
            } catch {
                return BatchCompletion(id: entry.id, result: .failed(error.localizedDescription))
            }
        }
    }

    private func apply(_ completion: BatchCompletion) {
        switch completion.result {
        case .outcome(.success(let answerNumber, _)):
            mark(completion.id, as: .success(answerNumber))
        case .outcome(.verificationRequired(let message)):
            mark(completion.id, as: .verificationRequired(message))
        case .outcome(.failure(let message)), .failed(let message):
            mark(completion.id, as: .failed(message))
        case .cancelled:
            mark(completion.id, as: .cancelled)
        }
    }

    private func mark(_ id: UUID, as state: BatchEntryState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private var normalizedLines: [String] {
        rawList
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseEntries() throws -> [BatchEntry] {
        let lines = normalizedLines
        guard !lines.isEmpty else { throw BatchInputError.empty }
        guard lines.count <= 500 else { throw BatchInputError.tooMany(lines.count) }

        var usedIDs = Set<String>()
        var entries: [BatchEntry] = []
        let separators = ",，\t"

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            let employeeID: String
            let name: String

            if let separatorIndex = line.firstIndex(where: { separators.contains($0) }) {
                employeeID = String(line[..<separatorIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                name = String(line[line.index(after: separatorIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard employeeID.count == 6, employeeID.allSatisfy(\.isNumber) else {
                    throw BatchInputError.invalidLine(lineNumber, "工号必须是 6 位数字")
                }
            } else {
                name = line
                employeeID = makeUniqueEmployeeID(used: &usedIDs)
            }

            guard !name.isEmpty else {
                throw BatchInputError.invalidLine(lineNumber, "姓名不能为空")
            }
            guard !usedIDs.contains(employeeID) else {
                throw BatchInputError.invalidLine(lineNumber, "工号 \(employeeID) 重复")
            }

            usedIDs.insert(employeeID)
            entries.append(BatchEntry(id: UUID(), employeeID: employeeID, name: name))
        }
        return entries
    }

    private func makeUniqueEmployeeID(used: inout Set<String>) -> String {
        var value: String
        repeat {
            value = String(Int.random(in: 100_000...999_999))
        } while used.contains(value)
        return value
    }

    private func beginBackgroundExecution() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Batch survey submission") {
            Task { @MainActor [weak self] in
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
