import ClickHouseCore
import Gingham
import UIKit

/// The editor above, the result below (Gingham's table, or a statement's
/// text), the status in the navigation bar. Run (⌘↩) runs the statement at
/// the cursor or the selection; Stop (⌘.) stops it; the search bar keeps
/// the rows with its words.
final class QueryViewController: UIViewController, UITextViewDelegate, UISearchResultsUpdating, GHTableViewDelegate,
    UISplitViewControllerDelegate {
    let endpoint: CHEndpoint
    let client: CHClient
    var onClose: () -> Void = {}
    var onConnected: () -> Void = {}

    private let editor = UITextView()
    private let table = GHTableView(frame: .zero)
    private let textOutput = UITextView()
    private let messageLabel = UILabel()
    private let statusLabel = UILabel()
    private lazy var queries = QueryController(client: client, table: table)
    private lazy var history = QueryHistory(endpoint: endpoint)
    private var statusTimer: Timer?
    private var editorHeight: NSLayoutConstraint!
    private var parameterValues: [String: String] = [:]
    private var historySaved = Set<String>()
    private var completions: Completions?
    private let completionBar = CompletionBar()
    private lazy var checker = StatementChecker(client: client, isAutomatic: !endpoint.isCloud)
    /// Under the editor: the problem at the cursor, with the names the server suggests.
    private let checkBar = UIStackView()
    private let checkLabel = UILabel()
    private let checkIcon = UIImageView()
    private var underlined: [EditorProblem] = []

    init(endpoint: CHEndpoint, client: CHClient) {
        self.endpoint = endpoint
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = endpoint.title
        navigationItem.largeTitleDisplayMode = .never
        let run = UIBarButtonItem(title: String(localized: "Run"), image: UIImage(systemName: "play.fill"),
                                  primaryAction: UIAction { [weak self] _ in self?.runStatement() })
        let stop = UIBarButtonItem(title: String(localized: "Stop"), image: UIImage(systemName: "stop.fill"),
                                   primaryAction: UIAction { [weak self] _ in self?.queries.cancel() })
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.menuElements() ?? []) }])
        let more = UIBarButtonItem(title: String(localized: "More"), image: UIImage(systemName: "ellipsis"), menu: menu)
        navigationItem.rightBarButtonItems = [more, stop, run]
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Find in result")
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        editor.font = SQLHighlighting.font
        editor.autocapitalizationType = .none
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.keyboardType = .asciiCapable
        editor.delegate = self
        editor.backgroundColor = .secondarySystemBackground
        editor.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        editor.text = UserDefaults.standard.string(forKey: "Editor \(endpoint.id.uuidString)") ?? "SELECT version(), uptime(), timezone()\n"
        SQLHighlighting.apply(to: editor.textStorage)
        editor.inputAccessoryView = completionBar
        completionBar.onRun = { [weak self] in self?.runStatement() }
        completionBar.onChoose = { [weak self] word in self?.complete(with: word) }

        table.delegate = self
        table.allowsMultipleSelection = true
        table.emptyStateText = String(localized: "Run a statement to see its rows here.")
        textOutput.isEditable = false
        textOutput.font = SQLHighlighting.font
        textOutput.isHidden = true
        messageLabel.textColor = .systemRed
        messageLabel.numberOfLines = 5
        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.isHidden = true
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontForContentSizeCategory = true

        let results = UIView()
        for content in [table, textOutput] as [UIView] {
            content.translatesAutoresizingMaskIntoConstraints = false
            results.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: results.leadingAnchor), content.trailingAnchor.constraint(equalTo: results.trailingAnchor),
                content.topAnchor.constraint(equalTo: results.topAnchor), content.bottomAnchor.constraint(equalTo: results.bottomAnchor),
            ])
        }
        checkLabel.font = .preferredFont(forTextStyle: .footnote)
        checkLabel.numberOfLines = 2
        checkLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkIcon.setContentHuggingPriority(.required, for: .horizontal)
        checkIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        checkBar.addArrangedSubview(checkIcon)
        checkBar.addArrangedSubview(checkLabel)
        checkBar.spacing = 6
        checkBar.alignment = .center
        checkBar.isLayoutMarginsRelativeArrangement = true
        checkBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        checkBar.backgroundColor = .secondarySystemBackground
        checkBar.isHidden = true
        checker.onChange = { [weak self] in self?.showProblems() }
        let stack = UIStackView(arrangedSubviews: [editor, checkBar, messageLabel, results, statusLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(0, after: editor)
        view.addSubview(stack)
        editorHeight = editor.heightAnchor.constraint(equalToConstant: 150)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            editorHeight,
        ])
        messageLabel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        statusLabel.textAlignment = .center

        queries.onChange = { [weak self] in self?.updateStatus() }
        queries.onText = { [weak self] text in self?.showText(text) }
        connect()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UserDefaults.standard.set(editor.text, forKey: "Editor \(endpoint.id.uuidString)")
    }

    private func connect() {
        statusLabel.text = endpoint.isCloud ? String(localized: "Connecting (a sleeping service takes a while to wake)…") : String(localized: "Connecting…")
        Task {
            do {
                let info = try await client.connect(timeout: endpoint.isCloud ? 120 : 20)
                statusLabel.text = String(localized: "Connected to ClickHouse \(info.version.text) (\(info.timeZone)).")
                onConnected()
                Task { [weak self, client] in
                    let completions = await Completions.load(client)
                    self?.completions = completions
                    #if DEBUG
                    // `-ViewerComplete <text>`: the text typed, the editor focused (its completions in the bar).
                    if let self, let text = UserDefaults.standard.string(forKey: "ViewerText") {
                        self.editor.text = text
                        self.textViewDidChange(self.editor)
                    }
                    if let self, let text = UserDefaults.standard.string(forKey: "ViewerComplete") {
                        self.editor.text = text
                        SQLHighlighting.apply(to: self.editor.textStorage)
                        self.editor.becomeFirstResponder()
                        self.editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                        self.updateCompletions()
                    }
                    #endif
                }
                #if DEBUG
                if let sql = UserDefaults.standard.string(forKey: "ViewerRun") {
                    editor.text = sql
                    SQLHighlighting.apply(to: editor.textStorage)
                    run(sql)
                }
                #endif
            } catch {
                statusLabel.text = String(localized: "Not connected: \(error.viewerDescription)")
                statusLabel.textColor = .systemRed
            }
        }
    }

    private func close() {
        queries.cancel()
        statusTimer?.invalidate()
        UserDefaults.standard.set(editor.text, forKey: "Editor \(endpoint.id.uuidString)")
        onClose()
    }

    // MARK: Keyboard

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: String(localized: "Run Statement"), action: #selector(runCommand(_:)), input: "\r", modifierFlags: .command),
         UIKeyCommand(title: String(localized: "Stop"), action: #selector(stopCommand(_:)), input: ".", modifierFlags: .command),
         UIKeyCommand(title: String(localized: "Check Statement"), action: #selector(checkCommand(_:)), input: "b", modifierFlags: .command),
         UIKeyCommand(title: String(localized: "Find in Result"), action: #selector(findCommand(_:)), input: "f", modifierFlags: .command)]
    }

    @objc private func runCommand(_ sender: Any?) { runStatement() }
    @objc private func stopCommand(_ sender: Any?) { queries.cancel() }
    @objc private func checkCommand(_ sender: Any?) { checker.checkNow(text: editor.text, cursor: editor.selectedRange.location) }
    @objc private func findCommand(_ sender: Any?) { navigationItem.searchController?.searchBar.becomeFirstResponder() }

    // MARK: Running

    private func runStatement() {
        guard let sql = currentStatement() else { return }
        editor.resignFirstResponder()
        run(sql)
    }

    /// The selection, or the statement at the cursor (without its semicolon).
    private func currentStatement() -> String? {
        let text = editor.text as NSString
        var range = editor.selectedRange
        if range.length == 0 {
            guard let statement = CHSQL.statement(at: range.location, in: editor.text) else { return nil }
            range = statement
        }
        let sql = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        return sql.isEmpty ? nil : sql
    }

    private func run(_ sql: String) {
        let parameters = CHSQL.parameters(of: sql)
        guard !parameters.isEmpty else { return start(sql, values: [:]) }
        let alert = UIAlertController(title: String(localized: "Values of the parameters"),
                                      message: String(localized: "As text, as the server reads them."), preferredStyle: .alert)
        for parameter in parameters {
            alert.addTextField { [parameterValues] field in
                field.placeholder = "\(parameter.name): \(parameter.type)"
                field.text = parameterValues[parameter.name]
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Run"), style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields else { return }
            var values: [String: String] = [:]
            for (parameter, field) in zip(parameters, fields) { values[parameter.name] = field.text ?? "" }
            parameterValues.merge(values) { $1 }
            start(sql, values: values)
        })
        present(alert, animated: true)
    }

    private func start(_ sql: String, values: [String: String]) {
        messageLabel.isHidden = true
        queries.run(sql, parameters: values)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
    }

    func showRows(of table: Schema.Table) {
        let sql = Schema.previewStatement(of: table)
        editor.text = sql
        SQLHighlighting.apply(to: editor.textStorage)
        run(sql)
        showSecondary()
    }

    /// A view of the server (Running Queries, Merges, …), refreshed while live.
    func show(_ view: ServerView) {
        messageLabel.isHidden = true
        queries.show(view)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        showSecondary()
    }

    func showCreate(of table: Schema.Table) {
        Task {
            do {
                showText(try await Schema.createStatement(of: table, client: client))
            } catch {
                show(error)
            }
        }
        showSecondary()
    }

    func insert(_ text: String) {
        editor.becomeFirstResponder()
        editor.insertText(text)
        showSecondary()
    }

    /// The editor and result in front (on an iPhone, the schema goes).
    private func showSecondary() {
        splitViewController?.show(.secondary)
    }

    private func showText(_ text: String?) {
        textOutput.isHidden = text == nil
        table.isHidden = text != nil
        textOutput.text = text ?? ""
    }

    private func show(_ error: Error) {
        messageLabel.text = error.viewerDescription
        messageLabel.isHidden = false
    }

    private func updateStatus() {
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = queries.status
        if let error = queries.error { show(error) }
        if !queries.isRunning {
            statusTimer?.invalidate()
            statusTimer = nil
            if case .finished(let stats) = queries.state, let sql = queries.statement, !historySaved.contains(stats.queryID) {
                historySaved.insert(stats.queryID)
                history.add(sql, rows: stats.rows, seconds: QueryController.seconds(stats.elapsed))
            }
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        let selection = textView.selectedRange
        underlined = checker.problems
        SQLHighlighting.apply(to: textView.textStorage, problems: underlined)
        textView.selectedRange = selection
        updateCompletions()
        checker.update(text: textView.text, cursor: textView.selectedRange.location)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        updateCompletions()
        checker.update(text: textView.text, cursor: textView.selectedRange.location)
        showProblems()
    }

    // MARK: Checking

    /// The problems underlined, the one at the cursor under the editor with the names suggested.
    private func showProblems() {
        guard editor.textStorage.string == editor.text else { return }
        if underlined != checker.problems {
            underlined = checker.problems
            let selection = editor.selectedRange
            SQLHighlighting.apply(to: editor.textStorage, problems: underlined)
            editor.selectedRange = selection
        }
        while checkBar.arrangedSubviews.count > 2 { checkBar.arrangedSubviews.last?.removeFromSuperview() }
        let problem = checker.problem(at: editor.selectedRange.location)
        let hidden = problem == nil
        if checkBar.isHidden != hidden { checkBar.isHidden = hidden }
        guard let problem else { return }
        checkIcon.image = UIImage(systemName: problem.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
        checkIcon.tintColor = problem.isError ? .systemRed : .systemOrange
        let others = checker.problems.count - 1
        checkLabel.text = problem.message + (others > 0 ? "  " + String(localized: "(\(others) more)") : "")
        for suggestion in problem.suggestions.prefix(2) {
            guard let range = problem.range else { break }
            var configuration = UIButton.Configuration.gray()
            configuration.title = suggestion
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.replace(range, with: suggestion) })
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            checkBar.addArrangedSubview(button)
        }
    }

    /// A name the server suggested put in place of the wrong one.
    private func replace(_ range: NSRange, with text: String) {
        guard NSMaxRange(range) <= (editor.text as NSString).length,
              let start = editor.position(from: editor.beginningOfDocument, offset: range.location),
              let end = editor.position(from: start, offset: range.length), let textRange = editor.textRange(from: start, to: end) else { return }
        editor.replace(textRange, withText: text)
    }

    // MARK: Completion

    /// The statement at the cursor.
    private var statementAtCursor: String {
        CHSQL.statement(at: editor.selectedRange.location, in: editor.text).map { (editor.text as NSString).substring(with: $0) } ?? ""
    }

    /// The bar's completions of the word before the cursor (the columns of the statement's tables first).
    private func updateCompletions() {
        guard let completions else { return completionBar.show([]) }
        let partial = Completions.partialWord(in: editor.text as NSString, before: editor.selectedRange.location)
        guard partial.length >= 1 else { return completionBar.show([]) }
        let statement = statementAtCursor
        completions.loadColumns(of: statement, client: client, database: endpoint.database) { [weak self] in self?.updateCompletions() }
        completionBar.show(completions.matches((editor.text as NSString).substring(with: partial), in: statement))
    }

    private func complete(with word: String) {
        let partial = Completions.partialWord(in: editor.text as NSString, before: editor.selectedRange.location)
        guard let start = editor.position(from: editor.beginningOfDocument, offset: partial.location),
              let end = editor.position(from: start, offset: partial.length), let range = editor.textRange(from: start, to: end) else { return }
        editor.replace(range, withText: word)
    }

    func updateSearchResults(for searchController: UISearchController) {
        queries.search(searchController.searchBar.text ?? "")
    }

    func tableViewDidChangeActivity(_ tableView: GHTableView) {
        updateStatus()
    }

    // MARK: Menus

    private func menuElements() -> [UIMenuElement] {
        let historyItems = history.entries.prefix(25).map { entry in
            let oneLine = entry.sql.split(whereSeparator: \.isNewline).joined(separator: " ")
            return UIAction(title: oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine) { [weak self] _ in
                guard let self else { return }
                editor.text = entry.sql
                SQLHighlighting.apply(to: editor.textStorage)
            }
        }
        let historyMenu = UIMenu(title: String(localized: "History"), image: UIImage(systemName: "clock.arrow.circlepath"),
                                 children: historyItems.isEmpty ? [UIAction(title: String(localized: "No statements yet"), attributes: .disabled) { _ in }]
                                     : historyItems)
        let formats: [(String, String, String)] = [("CSV", "CSVWithNames", "csv"), ("TSV", "TSVWithNames", "tsv"), ("Parquet", "Parquet", "parquet"),
                                                   ("Arrow", "Arrow", "arrow"), (String(localized: "JSON lines"), "JSONEachRow", "jsonl")]
        let canExport = queries.statement.map { CHSQL.formatClause(of: $0) == nil } ?? false
        let export = UIMenu(title: String(localized: "Export"), image: UIImage(systemName: "square.and.arrow.up"), children: formats.map { title, format, ext in
            UIAction(title: title, attributes: canExport ? [] : .disabled) { [weak self] _ in self?.export(format: format, extension: ext) }
        })
        let explains: [(String, String)] = [
            (String(localized: "Explain Plan"), "EXPLAIN PLAN indexes = 1 %@ FORMAT TSVRaw"),
            (String(localized: "Explain Pipeline"), "EXPLAIN PIPELINE %@ FORMAT TSVRaw"),
            (String(localized: "Explain Estimate"), "EXPLAIN ESTIMATE %@"),
            (String(localized: "Explain Syntax"), "EXPLAIN SYNTAX %@ FORMAT TSVRaw"),
        ]
        let explain = UIMenu(title: String(localized: "Explain"), image: UIImage(systemName: "list.bullet.indent"), children: explains.map { title, form in
            UIAction(title: title) { [weak self] _ in
                guard let self, let sql = currentStatement() else { return }
                run(form.replacingOccurrences(of: "%@", with: sql))
            }
        })
        let editorSize = UIMenu(title: String(localized: "Editor"), options: .displayInline, children: [
            UIAction(title: String(localized: "Larger Editor"), image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in self?.resizeEditor(by: 120) },
            UIAction(title: String(localized: "Smaller Editor"), image: UIImage(systemName: "arrow.up.to.line")) { [weak self] _ in self?.resizeEditor(by: -120) },
        ])
        let check = UIAction(title: String(localized: "Check Statement"), image: UIImage(systemName: "checkmark.seal")) { [weak self] _ in
            guard let self else { return }
            checker.checkNow(text: editor.text, cursor: editor.selectedRange.location)
        }
        return [historyMenu, check, explain, export, editorSize]
    }

    private func resizeEditor(by delta: CGFloat) {
        editorHeight.constant = min(max(60, editorHeight.constant + delta), view.bounds.height * 0.7)
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    /// The statement run again by the server in a format it makes, into a file to share or save.
    private func export(format: String, extension ext: String) {
        guard let sql = queries.statement else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "result.\(ext)")
        statusLabel.text = String(localized: "Exporting…")
        Task {
            do {
                let bytes = try await client.download(sql, format: format, to: file, parameters: parameterValues) { written in
                    Task { @MainActor [weak self] in
                        self?.statusLabel.text = String(localized: "Exporting… \(ByteCountFormatter.string(fromByteCount: Int64(written), countStyle: .file))")
                    }
                }
                statusLabel.text = String(localized: "Exported \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).")
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                share.popoverPresentationController?.sourceItem = navigationItem.rightBarButtonItems?.first
                present(share, animated: true)
            } catch {
                show(error)
            }
        }
    }

    /// A long press on cells: the value shown whole, copied, or the rows copied.
    func tableView(_ tableView: GHTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: GHTableColumn?) -> UIMenu? {
        guard let source = queries.source else { return nil }
        var items: [UIMenuElement] = []
        if let row = clickedRow, let column, let index = Int(column.id), let text = source.fullText(row: row, columnIndex: index) {
            let title = source.result.names[index] + ": " + source.result.typeNames[index]
            items.append(UIAction(title: String(localized: "Show Value"), image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
                let inspector = UINavigationController(rootViewController: CellInspectorController(text: text, title: title))
                self?.present(inspector, animated: true)
            })
            items.append(UIAction(title: String(localized: "Copy Value"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            })
        }
        if !rows.isEmpty {
            items.append(UIAction(title: String(localized: "Copy \(rows.count.formatted()) Rows"), image: UIImage(systemName: "doc.on.clipboard")) { _ in
                UIPasteboard.general.string = tableView.copyText(forRows: rows)
            })
            if let title = queries.killTitle {
                items.append(UIAction(title: rows.count == 1 ? title : "\(title) (\(rows.count.formatted()))", image: UIImage(systemName: "xmark.octagon"),
                                      attributes: .destructive) { [weak self] _ in self?.queries.kill(rows: rows) })
            }
        }
        return UIMenu(children: items)
    }

    // MARK: UISplitViewControllerDelegate

    /// On an iPhone the editor and result come first (the schema is back).
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column)
        -> UISplitViewController.Column {
        .secondary
    }
}

/// A cell's whole value: JSON laid out, selectable, with Copy.
final class CellInspectorController: UIViewController {
    private let text: String
    private let heading: String

    init(text: String, title: String) {
        self.text = text
        heading = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = heading
        view.backgroundColor = .systemBackground
        let textView = UITextView()
        textView.isEditable = false
        textView.font = SQLHighlighting.font
        textView.text = Self.prettyJSON(text) ?? text
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor), textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor), textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localized: "Copy"), primaryAction: UIAction { [text] _ in UIPasteboard.general.string = text })
    }

    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
