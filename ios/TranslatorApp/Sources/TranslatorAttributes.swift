import ActivityKit
import Foundation

struct TranslatorAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var originalText: String
        var translatedText: String
        var detectedLanguage: String
    }

    var targetLanguage: String
}
