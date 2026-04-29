import ActivityKit
import Foundation

@available(iOS 16.1, *)
class LiveActivityManager {
    private var activity: Activity<TranslatorAttributes>?

    func startActivity(targetLanguage: String, initialText: String = "") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = TranslatorAttributes(targetLanguage: targetLanguage)
        let state = TranslatorAttributes.ContentState(
            originalText: initialText,
            translatedText: "",
            detectedLanguage: ""
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            print("Live Activity start error: \(error)")
        }
    }

    func updateTranslation(original: String, translated: String, language: String) {
        guard let activity = activity else { return }
        let state = TranslatorAttributes.ContentState(
            originalText: original,
            translatedText: translated,
            detectedLanguage: language
        )
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func endActivity() {
        guard let currentActivity = activity else { return }
        Task {
            await currentActivity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }
}
