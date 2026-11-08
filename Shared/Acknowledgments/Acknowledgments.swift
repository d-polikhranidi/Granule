#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Software the app is built with, its authors and license: Help › Acknowledgments on the
/// Mac, Settings › Acknowledgments on the iPad and iPhone. The texts are the packages' own
/// license and NOTICE files (Apache 2.0 asks for the NOTICE), resources beside this file;
/// `Tools/acknowledgments.sh` copies them again after the packages are updated.
struct Acknowledgment: Identifiable, Hashable {
    let name: String
    /// What it does in the app.
    let use: String
    let authors: String
    let url: URL
    let license: String
    /// The texts shown, in this order: their headings and resources' names (`.txt`).
    let texts: [Part]

    struct Part: Hashable {
        let heading: String
        let resource: String
    }

    var id: String { name }

    private static let apache = Part(heading: String(localized: "Apache License 2.0"), resource: "Apache-2.0")
    private static let runtimeException = Part(heading: String(localized: "Apache License 2.0 with the Runtime Library Exception"),
                                               resource: "Apache-2.0-Runtime-Library-Exception")

    static let all: [Acknowledgment] = [
        Acknowledgment(name: "Gingham", use: String(localized: "Shows the results."), authors: "Dalis Polikhranidi",
                       url: URL(string: "https://github.com/digitalglobeby/Gingham")!, license: String(localized: "Gingham License"), texts: []),
        Acknowledgment(name: "SwiftNIO", use: String(localized: "Networking for SSH tunnels."), authors: "Apple Inc. and the SwiftNIO project authors",
                       url: URL(string: "https://github.com/apple/swift-nio")!, license: apache.heading,
                       texts: [Part(heading: "NOTICE", resource: "swift-nio-NOTICE"), apache]),
        Acknowledgment(name: "SwiftNIO SSH", use: String(localized: "SSH tunnels."), authors: "Apple Inc. and the SwiftNIO project authors",
                       url: URL(string: "https://github.com/apple/swift-nio-ssh")!, license: apache.heading, texts: [apache]),
        Acknowledgment(name: "Swift Crypto", use: String(localized: "SSH tunnels' keys."), authors: "Apple Inc. and the SwiftCrypto project authors",
                       url: URL(string: "https://github.com/apple/swift-crypto")!, license: apache.heading,
                       texts: [Part(heading: "NOTICE", resource: "swift-crypto-NOTICE"), apache]),
        Acknowledgment(name: "Swift Atomics", use: String(localized: "Used by SwiftNIO."), authors: "Apple Inc. and the Swift project authors",
                       url: URL(string: "https://github.com/apple/swift-atomics")!, license: apache.heading, texts: [runtimeException]),
        Acknowledgment(name: "Swift Collections", use: String(localized: "Used by SwiftNIO."), authors: "Apple Inc. and the Swift project authors",
                       url: URL(string: "https://github.com/apple/swift-collections")!, license: apache.heading, texts: [runtimeException]),
        Acknowledgment(name: "Zstandard", use: String(localized: "Reads results compressed with ZSTD."), authors: "Meta Platforms, Inc. and affiliates",
                       url: URL(string: "https://github.com/facebook/zstd")!, license: String(localized: "BSD License"),
                       texts: [Part(heading: String(localized: "BSD License"), resource: "zstd-LICENSE")]),
        Acknowledgment(name: "Ryu", use: String(localized: "Writes floating-point numbers in their shortest digits."), authors: "Ulf Adams",
                       url: URL(string: "https://github.com/ulfjack/ryu")!, license: String(localized: "Boost Software License 1.0"),
                       texts: [Part(heading: String(localized: "Boost Software License 1.0"), resource: "Ryu-LICENSE-Boost")]),
    ]

    /// A text's paragraphs (nothing if it's missing).
    static func paragraphs(of text: Part) -> [String] {
        guard let url = Bundle.main.url(forResource: text.resource, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return paragraphs(contents)
    }

    /// A license's lines joined again into paragraphs: the files wrap them at 80 columns, too
    /// wide for a phone and ragged in a proportional font. List items and centered titles keep
    /// lines of their own; rules of `=` or `-` go.
    static func paragraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        func end() {
            if !current.isEmpty { paragraphs.append(current) }
            current = ""
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "=" || $0 == "-" }) {
                end()
                continue
            }
            let isCentered = line.prefix { $0 == " " }.count >= 12
            if isCentered || startsItem(trimmed) { end() }
            current = current.isEmpty ? trimmed : current + " " + trimmed
            if isCentered { end() }
        }
        end()
        return paragraphs
    }

    /// `* `, `- `, `1.`, `(a)`: a list's item.
    private static func startsItem(_ line: String) -> Bool {
        if line.hasPrefix("* ") || line.hasPrefix("- ") { return true }
        let first = line.prefix { $0 != " " }
        if first.count <= 5, first.hasPrefix("("), first.hasSuffix(")") { return true }
        return first.count >= 2 && first.hasSuffix(".") && first.dropLast().allSatisfy(\.isNumber)
    }
}

/// The list of acknowledgments: the Mac's window (a sidebar and the one selected), the iPad's
/// and iPhone's Settings page (each pushed).
struct AcknowledgmentsView: View {
    #if os(macOS)
    @State private var selection: Acknowledgment.ID? = Acknowledgment.all.first?.id

    var body: some View {
        NavigationSplitView {
            List(Acknowledgment.all, selection: $selection) { item in
                row(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            if let item = Acknowledgment.all.first(where: { $0.id == selection }) {
                AcknowledgmentView(item: item)
                    .id(item.id)
            }
        }
    }
    #else
    var body: some View {
        List {
            Section {
                ForEach(Acknowledgment.all) { item in
                    NavigationLink {
                        AcknowledgmentView(item: item)
                    } label: {
                        row(item)
                    }
                }
            } footer: {
                Text("The app is built with this software. Thanks to its authors.")
            }
        }
        .navigationTitle("Acknowledgments")
    }
    #endif

    private func row(_ item: Acknowledgment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
            Text(item.license)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One acknowledgment: what it does in the app, its authors, where it lives, its license.
struct AcknowledgmentView: View {
    let item: Acknowledgment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                Text(item.name)
                    .font(.title2.bold())
                #endif
                Text(item.use)
                Text("© \(item.authors)")
                    .foregroundStyle(.secondary)
                Link(item.url.host().map { $0 + item.url.path() } ?? item.url.absoluteString, destination: item.url)
                if item.texts.isEmpty {
                    Text("Used under the terms of its license, on its page.")
                        .foregroundStyle(.secondary)
                }
                ForEach(item.texts, id: \.self) { text in
                    Text(text.heading)
                        .font(.headline)
                        .padding(.top, 12)
                    ForEach(Self.paragraphs(of: text)) { paragraph in
                        Text(paragraph.text)
                            .font(.callout)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private struct Paragraph: Identifiable {
        /// Its text's and its place: the NOTICE's paragraphs aren't the license's (with the
        /// offset alone, the license showed the NOTICE again).
        let id: String
        let text: String
    }

    /// A text's paragraphs, without its title where it starts with it (zstd's).
    private static func paragraphs(of part: Acknowledgment.Part) -> [Paragraph] {
        Acknowledgment.paragraphs(of: part).enumerated()
            .filter { $0.offset > 0 || $0.element != part.heading }
            .map { Paragraph(id: "\(part.resource) \($0.offset)", text: $0.element) }
    }
}
