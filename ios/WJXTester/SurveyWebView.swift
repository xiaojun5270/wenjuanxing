import SwiftUI
import WebKit
import Foundation

struct BrowserSheet: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL
    let answers: [Int: String]

    var body: some View {
        NavigationStack {
            SurveyWebView(url: url, answers: answers)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("浏览器验证")
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

struct SurveyWebView: UIViewRepresentable {
    let url: URL
    let answers: [Int: String]

    func makeCoordinator() -> Coordinator {
        Coordinator(answers: answers)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let answers: [Int: String]

        init(answers: [Int: String]) {
            self.answers = answers
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let answersJSON = Self.javascriptObject(answers)
            let script = """
            (() => {
              const answers = \(answersJSON);
              const setValue = (id, value) => {
                const element = document.getElementById(id);
                if (!element) return;
                element.value = value;
                element.dispatchEvent(new Event('input', { bubbles: true }));
                element.dispatchEvent(new Event('change', { bubbles: true }));
              };
              Object.entries(answers).forEach(([topic, value]) => setValue(`q${topic}`, value));
            })();
            """
            webView.evaluateJavaScript(script)
        }

        private static func javascriptObject(_ answers: [Int: String]) -> String {
            let object = Dictionary(uniqueKeysWithValues: answers.map { (String($0.key), $0.value) })
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let json = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return json
        }
    }
}
