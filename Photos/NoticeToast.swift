import SwiftUI

// Bottom-center toast above the action bars: result messages appear where the action
// happened, in the standard floating-HUD look
struct NoticeToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(notice)
                    .font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
