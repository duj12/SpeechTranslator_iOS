import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct TranslatorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranslatorAttributes.self) { context in
            // Lock screen / banner presentation
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundColor(.purple)
                        Text(context.state.detectedLanguage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("同声传译")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if !context.state.originalText.isEmpty {
                        Text(context.state.originalText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    if !context.state.translatedText.isEmpty {
                        Text(context.state.translatedText)
                            .font(.body)
                            .fontWeight(.semibold)
                            .lineLimit(3)
                    }
                }
                .padding()
            }
            .background(Color(white: 0.12))
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded presentation
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .foregroundColor(.purple)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.targetLanguage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    if !context.state.translatedText.isEmpty {
                        Text(context.state.translatedText)
                            .font(.caption)
                            .lineLimit(3)
                    } else if !context.state.originalText.isEmpty {
                        Text(context.state.originalText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.originalText.isEmpty && !context.state.translatedText.isEmpty {
                        Text(context.state.originalText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .font(.caption2)
            } compactTrailing: {
                if !context.state.translatedText.isEmpty {
                    Text(context.state.translatedText)
                        .font(.caption2)
                        .lineLimit(1)
                }
            } minimal: {
                Image(systemName: "waveform")
            }
        }
    }
}

@available(iOS 16.1, *)
struct TranslatorWidgetPreviews: PreviewProvider {
    static var previews: some View {
        Text("Translator Widget Preview")
    }
}
