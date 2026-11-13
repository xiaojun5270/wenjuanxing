import SwiftUI
import WebKit
import Foundation

struct BrowserSheet: View {
    @Environment(\.dismiss) private var dismiss

    let employeeID: String
    let name: String

    var body: some View {
        NavigationStack {
            SurveyWebView(url: SurveyService.pageURL, employeeID: employeeID, name: name)
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
    let employeeID: String
    let name: String

    func makeCoordinator() -> Coordinator {
        Coordinator(employeeID: employeeID, name: name)
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
        private let employeeID: String
        private let name: String

        init(employeeID: String, name: String) {
            self.employeeID = employeeID
            self.name = name
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let idJSON = Self.javascriptString(employeeID)
            let nameJSON = Self.javascriptString(name)
            let script = """
            (() => {
              const setValue = (id, value) => {
                const element = document.getElementById(id);
                if (!element) return;
                element.value = value;
                element.dispatchEvent(new Event('input', { bubbles: true }));
                element.dispatchEvent(new Event('change', { bubbles: true }));
              };
              setValue('q1', \(idJSON));
              setValue('q2', \(nameJSON));
            })();
            """
            webView.evaluateJavaScript(script)
        }

        private static func javascriptString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8),
                  json.count >= 2 else {
                return "\"\""
            }
            return String(json.dropFirst().dropLast())
        }
    }
}
