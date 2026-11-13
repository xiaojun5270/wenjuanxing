import Foundation
import Combine

@MainActor
final class SurveyViewModel: ObservableObject {
    @Published var employeeID = ""
    @Published var name = ""
    @Published var dwellSeconds = 6
    @Published var isAuthorized = false
    @Published var isSubmitting = false
    @Published var outcome: SubmissionOutcome?
    @Published var errorMessage: String?
    @Published var showsConfirmation = false
    @Published var showsBrowser = false

    private let service = SurveyService()
    private let testNames = ["测试甲", "测试乙", "测试丙", "测试丁", "测试戊", "测试己"]

    var canSubmit: Bool {
        employeeID.count == 6 && employeeID.allSatisfy(\.isNumber)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isAuthorized
            && !isSubmitting
    }

    func randomize() {
        employeeID = String(Int.random(in: 100_000...999_999))
        name = testNames.randomElement() ?? "测试用户"
        outcome = nil
        errorMessage = nil
    }

    func requestSubmission() {
        guard canSubmit else { return }
        showsConfirmation = true
    }

    func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        outcome = nil
        errorMessage = nil
        let submittedID = employeeID
        let submittedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedDwell = dwellSeconds

        Task {
            do {
                outcome = try await service.submit(
                    employeeID: submittedID,
                    name: submittedName,
                    dwellSeconds: submittedDwell
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}
