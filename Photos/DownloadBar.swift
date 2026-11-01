import SwiftUI

struct DownloadBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.downloads.isActive, let progress = model.downloads.progress {
            HStack(spacing: 12) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 180)
                Text("\(progress.done)/\(progress.total) · \(model.downloads.percent) %")
                    .font(.callout)
                    .monospacedDigit()
                if let name = model.downloads.currentFileName {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180)
                }
                Button("Cancel") {
                    model.downloads.cancel()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
    }
}
