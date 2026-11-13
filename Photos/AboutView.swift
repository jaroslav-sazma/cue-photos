import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var licensesShown = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(verbatim: "Cue: Pick & Place")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("This app is a native interface on top of the official Google Photos website. You sign in to Google yourself, right here in the app, and everything you do — browsing, sorting into albums, downloading — happens inside that session, exactly as if you clicked through photos.google.com by hand.")
                Text("Your photos and your login never leave the connection between this Mac and Google. The app collects nothing, sends nothing anywhere else and keeps no copies beyond a local thumbnail cache, your current selection and your album labels.")
                Text("Built on the MIT-licensed Google Photos Toolkit. Released under GPL-3.0-or-later.")
                    .foregroundStyle(.secondary)
                Text("Not affiliated with, endorsed by, or sponsored by Google. Google Photos is a trademark of Google LLC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: 360, alignment: .leading)

            HStack {
                Button("Licenses") {
                    licensesShown = true
                }
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 440)
        .sheet(isPresented: $licensesShown) {
            LicensesView()
        }
    }
}

private struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return content
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(width: 560, height: 420)
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, 12)
        }
    }
}
