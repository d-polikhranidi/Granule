#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// Settings' panes: Queries and Appearance (the Mac's Settings window, iOS's sheet).

/// Settings › Queries: what's asked before a query runs.
struct QuerySettingsSection: View {
    @AppStorage(LargeReads.asksKey) private var asks = true
    @AppStorage(LargeReads.rowsKey) private var rows = LargeReads.defaultRows

    var body: some View {
        Section {
            Toggle(isOn: $asks) {
                Text("Ask before a query reads many rows")
                Text("By the server's estimate from its indexes (MergeTree tables), before the query runs. A query that stops at its LIMIT isn't asked about.")
            }
            Picker("More than", selection: $rows) {
                Text("100 million rows").tag(1e8)
                Text("1 billion rows").tag(1e9)
                Text("10 billion rows").tag(1e10)
                Text("100 billion rows").tag(1e11)
            }
            .disabled(!asks)
        } header: {
            Text("Before Running")
        }
    }
}

#if os(macOS)
/// The Mac's Queries pane.
struct QuerySettingsView: View {
    var body: some View {
        Form { QuerySettingsSection() }
            .formStyle(.grouped)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif

/// Settings › Appearance: the Mac's Settings window pane, a sheet on the iPad and iPhone (with
/// the Queries section and the acknowledgments there).
struct AppearanceSettingsView: View {
    /// All of Settings in one (iOS's sheet): the Queries section above, Acknowledgments below.
    var isWhole = false
    @AppStorage("EditorTheme") private var theme = EditorTheme.standard.rawValue
    @AppStorage("EditorFontSize") private var editorFontSize = Double(AppearanceSettings.defaultEditorFontSize)
    @AppStorage("ResultFontSize") private var resultFontSize = 0.0
    @AppStorage("ResultDensity") private var density = "regular"
    @AppStorage("ResultAlternatingRows") private var alternatingRows = true
    @AppStorage("DarkContentBackground") private var darkContent = false
    @Environment(\.colorScheme) private var colorScheme

    private static let sample = "SELECT country, count() AS visits -- this month\nFROM events\nWHERE event_time >= {since:DateTime} AND url LIKE '%/page/%'\nGROUP BY country ORDER BY visits DESC LIMIT 10"

    var body: some View {
        Form {
            if isWhole { QuerySettingsSection() }
            Section {
                Toggle(isOn: $darkContent) {
                    Text("Dark background for the editor and results")
                    #if os(macOS)
                    Text("The windows themselves follow System Settings › Appearance (Light, Dark or Auto).")
                    #else
                    Text("The app itself follows Settings › Display & Brightness (Light, Dark or Automatic).")
                    #endif
                }
            }
            Section("Editor") {
                Picker("Theme", selection: $theme) {
                    ForEach(EditorTheme.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Stepper(value: $editorFontSize, in: 10...24, step: 1) {
                    LabeledContent("Font size", value: String(localized: "\(Int(editorFontSize)) pt"))
                }
                preview
            }
            Section("Results") {
                Picker("Text size", selection: $resultFontSize) {
                    Text("System").tag(0.0)
                    ForEach([11.0, 12, 13, 14, 15, 16, 18], id: \.self) { Text(String(localized: "\(Int($0)) pt")).tag($0) }
                }
                Picker("Rows", selection: $density) {
                    Text("Compact").tag("compact")
                    Text("Regular").tag("regular")
                    Text("Spacious").tag("spacious")
                }
                .pickerStyle(.segmented)
                Toggle("Alternating row backgrounds", isOn: $alternatingRows)
            }
            #if os(iOS)
            if isWhole {
                Section {
                    NavigationLink("Acknowledgments") { AcknowledgmentsView() }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        .onChange(of: theme) { changed() }
        .onChange(of: editorFontSize) { changed() }
        .onChange(of: resultFontSize) { changed() }
        .onChange(of: density) { changed() }
        .onChange(of: alternatingRows) { changed() }
        .onChange(of: darkContent) { changed() }
    }

    /// The theme on a statement, as the editor will show it.
    private var preview: some View {
        let storage = NSTextStorage(string: Self.sample)
        SQLHighlighting.apply(to: storage)
        let background = EditorTheme(rawValue: theme)?.background
        #if os(macOS)
        let fallback = Color(nsColor: .textBackgroundColor)
        let text = AttributedString(storage)
        #else
        let fallback = Color(uiColor: .secondarySystemBackground)
        let text = (try? AttributedString(storage, including: \.uiKit)) ?? AttributedString(storage.string)
        #endif
        return Text(text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(background.map { Color($0) } ?? fallback, in: .rect(cornerRadius: 6))
            .environment(\.colorScheme, darkContent ? .dark : colorScheme)
            .id("\(theme)\(editorFontSize)\(darkContent)")
    }

    private func changed() {
        NotificationCenter.default.post(name: AppearanceSettings.didChange, object: nil)
    }
}

private extension Color {
    init(_ color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

#if os(iOS)
/// The iPad's and iPhone's Settings: one sheet, its pages pushed inside it.
struct SettingsSheet: View {
    let done: () -> Void

    var body: some View {
        NavigationStack {
            AppearanceSettingsView(isWhole: true)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        if #available(iOS 26.0, *) {
                            Button(role: .confirm, action: done)
                        } else {
                            Button("Done", action: done)
                        }
                    }
                }
        }
    }
}
#endif
