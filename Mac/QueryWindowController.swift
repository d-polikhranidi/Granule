import AppKit
import ClickHouseCore
import Gingham

/// A window of queries on one server: its schema in the sidebar, the editor
/// above, the result below (Gingham's table, or the text of a statement that
/// writes its own format), the status under it. ⌘↩ runs the statement at the
/// cursor (or the selection), ⌘. stops it.
final class QueryWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextStorageDelegate,
    NSTextViewDelegate, GHTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let endpoint: CHEndpoint
    let client: CHClient
    let password: String
    var onClose: () -> Void = {}
    /// A new tab on the same server asked for (File > New Tab, the tab bar's +).
    var onNewTab: (QueryWindowController) -> Void = { _ in }
    /// Which of the server's tabs it is (its editor's text is kept by it).
    var tabNumber = 0
    private var completions: Completions?
    private lazy var checker = StatementChecker(client: client, isAutomatic: !endpoint.isCloud)
    /// Under the editor: the problem at the cursor, with the names the server suggests.
    private let checkBar = NSStackView()
    private let checkLabel = NSTextField(labelWithString: "")
    private let checkIcon = NSImageView()
    /// The problems underlined now (the text is colored again only when they change).
    private var underlined: [EditorProblem] = []

    private let table = GHTableView(frame: .zero)
    private let sidebar = SchemaSidebar()
    private let editor = SQLTextView()
    private let textOutput = NSTextView()
    private let planOutline = PlanOutline()
    /// Over the result while a table's details show: its name and which detail.
    private let detailsBar = NSStackView()
    private let detailsTitle = NSTextField(labelWithString: "")
    private let detailsPicker = NSSegmentedControl(labels: TableDetail.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private var detailsTable: Schema.Table?
    private var textScroll: NSScrollView!
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private var queries: QueryController!
    private let history: QueryHistory
    private var statusTimer: Timer?
    private var highlightPending = false
    /// The values last given to each parameter, offered again.
    private var parameterValues: [String: String] = [:]

    init(endpoint: CHEndpoint, password: String, tabNumber: Int = 0) {
        self.endpoint = endpoint
        self.password = password
        self.tabNumber = tabNumber
        client = CHClient(endpoint: endpoint, password: password)
        history = QueryHistory(endpoint: endpoint)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = endpoint.title
        window.subtitle = "\(endpoint.host):\(endpoint.port)"
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("Query \(endpoint.id.uuidString)")
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        queries = QueryController(client: client, table: table)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    private func build() {
        guard let window else { return }
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 230
        sidebarItem.maximumThickness = 420
        split.addSplitViewItem(sidebarItem)
        let pane = NSViewController()
        pane.view = buildPane()
        let paneItem = NSSplitViewItem(viewController: pane)
        paneItem.minimumThickness = 480
        split.addSplitViewItem(paneItem)
        split.splitView.autosaveName = "QuerySplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 820))
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }

        let toolbar = NSToolbar(identifier: "Query")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        sidebar.client = client
        sidebar.onShowRows = { [weak self] table in self?.showRows(of: table) }
        sidebar.onShowCreate = { [weak self] table in self?.showCreate(of: table) }
        sidebar.onInsert = { [weak self] text in self?.insert(text) }
        sidebar.onShowDetails = { [weak self] table in self?.showDetails(of: table, .overview) }
        sidebar.onShowView = { [weak self] view in
            self?.hideDetails()
            self?.messageLabel.isHidden = true
            self?.queries.show(view)
            self?.startStatusTimer()
        }

        queries.onChange = { [weak self] in self?.updateStatus() }
        queries.onText = { [weak self] text in self?.showText(text) }
    }

    private func buildPane() -> NSView {
        // The editor.
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.documentView = editor
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textStorage?.delegate = self
        editor.delegate = self
        editor.string = UserDefaults.standard.string(forKey: editorKey) ?? (tabNumber == 0 ? "SELECT version(), uptime(), timezone()\n" : "")
        if let storage = editor.textStorage { SQLHighlighting.apply(to: storage) }

        // The result: the table, or a statement's text, or its error.
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(showValue(_:))
        table.allowsMultipleSelection = true
        table.navigatesByCell = true
        table.autosaveName = nil
        table.emptyStateText = String(localized: "Run a statement (⌘↩) to see its rows here.")
        table.exportOptions = GHExportOptions()
        textOutput.isEditable = false
        textOutput.font = SQLHighlighting.font
        textOutput.textContainerInset = NSSize(width: 8, height: 8)
        textOutput.isVerticallyResizable = true
        textOutput.autoresizingMask = [.width]
        textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.hasHorizontalScroller = true
        textScroll.documentView = textOutput
        textScroll.isHidden = true
        messageLabel.textColor = .systemRed
        messageLabel.isSelectable = true
        messageLabel.isHidden = true
        messageLabel.maximumNumberOfLines = 6
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail

        let results = NSView()
        planOutline.isHidden = true
        for view in [table, textScroll!, planOutline] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            results.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: results.leadingAnchor), view.trailingAnchor.constraint(equalTo: results.trailingAnchor),
                view.topAnchor.constraint(equalTo: results.topAnchor), view.bottomAnchor.constraint(equalTo: results.bottomAnchor),
            ])
        }
        detailsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        detailsTitle.lineBreakMode = .byTruncatingMiddle
        detailsTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailsPicker.target = self
        detailsPicker.action = #selector(pickDetail(_:))
        detailsPicker.segmentStyle = .automatic
        detailsBar.setViews([detailsTitle, detailsPicker], in: .leading)
        detailsBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 2, right: 10)
        detailsBar.isHidden = true
        let bottom = NSStackView(views: [detailsBar, messageLabel, results, statusLabel])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 4
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        bottom.setCustomSpacing(6, after: results)
        results.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        detailsBar.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        for label in [messageLabel, statusLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 10).isActive = true
            label.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -10).isActive = true
        }
        messageLabel.setContentHuggingPriority(.required, for: .vertical)
        results.setContentHuggingPriority(.defaultLow, for: .vertical)

        // The editor and, under it, its check's bar.
        checkLabel.lineBreakMode = .byTruncatingTail
        checkLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checkLabel.isSelectable = true
        checkLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkIcon.setContentHuggingPriority(.required, for: .horizontal)
        checkBar.addArrangedSubview(checkIcon)
        checkBar.addArrangedSubview(checkLabel)
        checkBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        checkBar.spacing = 6
        checkBar.isHidden = true
        let editorPane = NSStackView(views: [editorScroll, checkBar])
        editorPane.orientation = .vertical
        editorPane.spacing = 0
        editorScroll.widthAnchor.constraint(equalTo: editorPane.widthAnchor).isActive = true
        checkBar.widthAnchor.constraint(equalTo: editorPane.widthAnchor).isActive = true
        checker.onChange = { [weak self] in self?.showProblems() }
        checker.database = { [weak self] in
            guard let self else { return nil }
            return queries.currentDatabase ?? (endpoint.database.isEmpty ? nil : endpoint.database)
        }

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(editorPane)
        split.addArrangedSubview(bottom)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)
        split.autosaveName = "EditorSplit \(endpoint.id.uuidString)"
        editorPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        // The editor a few lines high at first (then as the user leaves it).
        DispatchQueue.main.async { [weak split] in
            guard let split, split.arrangedSubviews.count == 2 else { return }
            let height = split.arrangedSubviews[0].frame.height
            if height < 120 || height > split.bounds.height * 0.6 { split.setPosition(220, ofDividerAt: 0) }
        }
        return split
    }

    // MARK: Connecting

    func connect() {
        statusLabel.stringValue = endpoint.isCloud ? String(localized: "Connecting (a sleeping service takes a while to wake)…")
            : String(localized: "Connecting…")
        Task {
            do {
                let info = try await client.connect(timeout: endpoint.isCloud ? 120 : 20)
                window?.subtitle = "\(endpoint.host) · ClickHouse \(info.version.text) · \(info.user)"
                statusLabel.stringValue = String(localized: "Connected to ClickHouse \(info.version.text) (\(info.timeZone)).")
                sidebar.reload()
                window?.makeFirstResponder(editor)
                Task { [weak self, client] in
                    let completions = await Completions.load(client)
                    self?.completions = completions
                    self?.editor.completions = completions
                    #if DEBUG
                    // `-ViewerComplete <text>`: the text typed and its completions shown.
                    if let self, let text = UserDefaults.standard.string(forKey: "ViewerComplete") {
                        self.editor.string = text
                        self.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                        completions.loadColumns(of: text, client: self.client, database: "") { [weak self] in self?.editor.complete(nil) }
                    }
                    #endif
                }
                #if DEBUG
                // `-ViewerText <text>`: the editor's text (checked as if typed).
                // (A "‸" in it: the cursor's place.)
                if var text = UserDefaults.standard.string(forKey: "ViewerText") {
                    var cursor = (text as NSString).length
                    if let mark = text.range(of: "‸") {
                        cursor = text.utf16.distance(from: text.startIndex, to: mark.lowerBound)
                        text.removeSubrange(mark)
                    }
                    editor.string = text
                    editor.setSelectedRange(NSRange(location: cursor, length: 0))
                    checker.update(text: text, cursor: cursor)
                }
                // `-ViewerDetails <database.table>`: that table's details.
                if let name = UserDefaults.standard.string(forKey: "ViewerDetails") {
                    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        showDetails(of: Schema.Table(database: parts[0], name: parts[1], engine: "", rows: nil, bytes: nil, comment: ""),
                                    TableDetail(rawValue: UserDefaults.standard.string(forKey: "ViewerDetail") ?? "") ?? .overview)
                    }
                }
                // `-ViewerPlan <SQL>`: its plan shown (Explain Plan).
                if let sql = UserDefaults.standard.string(forKey: "ViewerPlan") {
                    editor.string = sql
                    showPlan(of: sql)
                }
                // `-ViewerView <name>`: a server view shown (processes, merges, …).
                if let name = UserDefaults.standard.string(forKey: "ViewerView"), let view = ServerView(rawValue: name) {
                    sidebar.onShowView(view)
                }
                if let sql = UserDefaults.standard.string(forKey: "ViewerRun") {
                    editor.string = sql
                    run(sql)
                }
                FileHandle.standardError.write(Data("VIEWER-WINDOW \(window?.windowNumber ?? 0)\n".utf8))
                #endif
            } catch {
                statusLabel.stringValue = String(localized: "Not connected: \(error.viewerDescription)")
                statusLabel.textColor = .systemRed
            }
        }
    }

    /// Where the editor's text is kept between launches.
    private var editorKey: String { "Editor \(endpoint.id.uuidString)" + (tabNumber == 0 ? "" : " \(tabNumber)") }

    override func newWindowForTab(_ sender: Any?) {
        onNewTab(self)
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(editor.string, forKey: editorKey)
        queries.cancel()
        statusTimer?.invalidate()
        onClose()
    }

    // MARK: Running

    /// Query > Run Statement (⌘↩): the selection, or the statement at the cursor.
    @objc func runStatement(_ sender: Any?) {
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        var range = selection
        if selection.length == 0 {
            guard let statement = CHSQL.statement(at: selection.location, in: editor.string) else { return }
            range = statement
            editor.showFindIndicator(for: statement)
        }
        let sql = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        guard !sql.isEmpty else { return }
        run(sql)
    }

    private func run(_ sql: String) {
        let parameters = CHSQL.parameters(of: sql)
        guard !parameters.isEmpty else { return start(sql, values: [:]) }
        askForValues(of: parameters) { [weak self] values in self?.start(sql, values: values) }
    }

    private func start(_ sql: String, values: [String: String]) {
        hideDetails()
        messageLabel.isHidden = true
        queries.run(sql, parameters: values)
        startStatusTimer()
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        window?.toolbar?.validateVisibleItems()
    }

    @objc func stopQuery(_ sender: Any?) {
        queries.cancel()
    }

    /// Query > Explain: the statement at the cursor (or the selection) as the
    /// server plans it (tag 0: PLAN with its indexes, 1: PIPELINE, 2: ESTIMATE, 3: SYNTAX).
    @objc func explainStatement(_ sender: Any?) {
        guard let sql = currentStatement() else { return }
        let kind = (sender as? NSMenuItem)?.tag ?? 0
        if kind == 0 { return showPlan(of: sql) }
        let explain = switch kind {
        case 4: "EXPLAIN PLAN indexes = 1 \(sql) FORMAT TSVRaw"
        case 1: "EXPLAIN PIPELINE \(sql) FORMAT TSVRaw"
        case 2: "EXPLAIN ESTIMATE \(sql)"
        case 3: "EXPLAIN SYNTAX \(sql) FORMAT TSVRaw"
        default: "EXPLAIN PLAN indexes = 1 \(sql) FORMAT TSVRaw"
        }
        run(explain)
    }

    /// Explain Plan: the plan's steps as an outline in the result's place,
    /// each read with the granules its indexes leave.
    private func showPlan(of sql: String) {
        statusLabel.stringValue = String(localized: "Explaining…")
        messageLabel.isHidden = true
        Task {
            do {
                let plan = try await client.plan(of: sql)
                planOutline.show(plan)
                table.isHidden = true
                textScroll.isHidden = true
                planOutline.isHidden = false
                statusLabel.stringValue = String(localized: "The plan, not run: \(PlanItem.summary(of: plan))")
            } catch {
                show(error)
                statusLabel.stringValue = ""
            }
        }
    }

    /// The selection, or the statement at the cursor (without its semicolon).
    private func currentStatement() -> String? {
        let text = editor.string as NSString
        var range = editor.selectedRange()
        if range.length == 0 {
            guard let statement = CHSQL.statement(at: range.location, in: editor.string) else { return nil }
            range = statement
        }
        let sql = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        return sql.isEmpty ? nil : sql
    }

    // MARK: Completion

    func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                  indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        let partial = (textView.string as NSString).substring(with: charRange)
        let statement = CHSQL.statement(at: charRange.location, in: textView.string).map { (textView.string as NSString).substring(with: $0) } ?? ""
        return completions?.matches(partial, in: statement) ?? []
    }

    /// Values for a statement's `{name:Type}` parameters, in a sheet.
    private func askForValues(of parameters: [CHSQL.Parameter], then run: @escaping ([String: String]) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Values of the parameters")
        alert.informativeText = String(localized: "As text, as the server reads them (an array: [1, 2]).")
        alert.addButton(withTitle: String(localized: "Run"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        var fields: [NSTextField] = []
        let grid = NSGridView(views: parameters.map { parameter in
            let field = NSTextField()
            field.stringValue = parameterValues[parameter.name] ?? ""
            field.placeholderString = parameter.type
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            fields.append(field)
            return [NSTextField(labelWithString: "\(parameter.name):"), field]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(parameters.count) * 30)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = fields.first
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var values: [String: String] = [:]
            for (parameter, field) in zip(parameters, fields) { values[parameter.name] = field.stringValue }
            parameterValues.merge(values) { $1 }
            run(values)
        }
    }

    private func showRows(of table: Schema.Table) {
        let sql = Schema.previewStatement(of: table)
        replaceEditorText(sql)
        run(sql)
    }

    /// A table's details over the result: the detail chosen, run as a result of its own.
    private func showDetails(of table: Schema.Table, _ detail: TableDetail) {
        detailsTable = table
        detailsTitle.stringValue = table.qualifiedName
        detailsPicker.selectedSegment = TableDetail.allCases.firstIndex(of: detail) ?? 0
        detailsBar.isHidden = false
        messageLabel.isHidden = true
        queries.run(detail.sql(database: table.database, table: table.name))
        startStatusTimer()
    }

    @objc private func pickDetail(_ sender: NSSegmentedControl) {
        guard let table = detailsTable, TableDetail.allCases.indices.contains(sender.selectedSegment) else { return }
        showDetails(of: table, TableDetail.allCases[sender.selectedSegment])
    }

    private func hideDetails() {
        detailsBar.isHidden = true
        detailsTable = nil
    }

    private func showCreate(of table: Schema.Table) {
        Task {
            do {
                showText(try await Schema.createStatement(of: table, client: client))
                statusLabel.stringValue = table.qualifiedName
            } catch {
                show(error)
            }
        }
    }

    /// A statement's text output in place of the table (`nil`: the table again).
    private func showText(_ text: String?) {
        planOutline.isHidden = true
        textScroll.isHidden = text == nil
        table.isHidden = text != nil
        textOutput.string = text ?? ""
    }

    private func show(_ error: Error) {
        messageLabel.stringValue = error.viewerDescription
        messageLabel.isHidden = false
    }

    private func updateStatus() {
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = queries.status
        if let error = queries.error {
            show(error)
        }
        if !queries.isRunning {
            statusTimer?.invalidate()
            statusTimer = nil
            #if DEBUG
            debugStartActions()
            #endif
            if case .finished(let stats) = queries.state, let sql = queries.statement, !historySaved.contains(stats.queryID) {
                historySaved.insert(stats.queryID)
                history.add(sql, rows: stats.rows, seconds: QueryController.seconds(stats.elapsed))
            }
        }
        window?.toolbar?.validateVisibleItems()
    }

    private var historySaved = Set<String>()

    // MARK: Editing

    private func insert(_ text: String) {
        window?.makeFirstResponder(editor)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func replaceEditorText(_ text: String) {
        let whole = NSRange(location: 0, length: (editor.string as NSString).length)
        if editor.shouldChangeText(in: whole, replacementString: text) {
            editor.replaceCharacters(in: whole, with: text)
            editor.didChangeText()
        }
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// Colors once per change, after it (a paste of a long script: once).
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !highlightPending else { return }
        highlightPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = editor.textStorage else { return }
            highlightPending = false
            underlined = checker.problems
            SQLHighlighting.apply(to: storage, problems: underlined)
            loadStatementColumns()
            checker.update(text: editor.string, cursor: editor.selectedRange().location)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        checker.update(text: editor.string, cursor: editor.selectedRange().location)
        showProblems()
    }

    /// Query > Check Statement (⌘B): the server's verdict on the statement at
    /// the cursor now (on ClickHouse Cloud the only way: no checks while typing).
    @objc func checkStatement(_ sender: Any?) {
        checker.checkNow(text: editor.string, cursor: editor.selectedRange().location)
    }

    /// The problems underlined, the one at the cursor in the bar with its suggestions.
    private func showProblems() {
        guard let storage = editor.textStorage, storage.string == editor.string else { return }
        if underlined != checker.problems {
            underlined = checker.problems
            let selection = editor.selectedRanges
            SQLHighlighting.apply(to: storage, problems: underlined)
            editor.selectedRanges = selection
        }
        while checkBar.arrangedSubviews.count > 2 { checkBar.arrangedSubviews.last?.removeFromSuperview() }
        guard let problem = checker.problem(at: editor.selectedRange().location) else {
            checkBar.isHidden = !checker.isChecking
            checkIcon.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            checkIcon.contentTintColor = .secondaryLabelColor
            checkLabel.stringValue = String(localized: "Checking…")
            checkLabel.textColor = .secondaryLabelColor
            return
        }
        checkBar.isHidden = false
        checkIcon.image = NSImage(systemSymbolName: problem.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        checkIcon.contentTintColor = problem.isError ? .systemRed : .systemOrange
        let others = checker.problems.count - 1
        checkLabel.stringValue = problem.message + (others > 0 ? "  " + String(localized: "(\(others) more)") : "")
        checkLabel.textColor = .labelColor
        checkLabel.toolTip = problem.message
        for suggestion in problem.suggestions.prefix(3) {
            guard let range = problem.range else { break }
            let button = NSButton(title: suggestion, target: nil, action: nil)
            button.bezelStyle = .push
            button.controlSize = .small
            button.toolTip = String(localized: "Replace with \(suggestion)")
            let fix = MenuAction(suggestion) { [weak self] in self?.replace(range, with: suggestion) }
            button.target = fix
            button.action = #selector(MenuAction.perform(_:))
            objc_setAssociatedObject(button, &MenuAction.key, fix, .OBJC_ASSOCIATION_RETAIN)
            checkBar.addArrangedSubview(button)
        }
    }

    /// A name the server suggested put in place of the wrong one.
    private func replace(_ range: NSRange, with text: String) {
        guard NSMaxRange(range) <= (editor.string as NSString).length, editor.shouldChangeText(in: range, replacementString: text) else { return }
        editor.replaceCharacters(in: range, with: text)
        editor.didChangeText()
        window?.makeFirstResponder(editor)
    }

    /// The columns of the tables the statement at the cursor reads, for completion.
    private func loadStatementColumns() {
        guard let completions, let range = CHSQL.statement(at: editor.selectedRange().location, in: editor.string) else { return }
        let statement = (editor.string as NSString).substring(with: range)
        completions.loadColumns(of: statement, client: client, database: endpoint.database) {}
    }

    // MARK: The table

    /// Query > Show Value (double-click a cell): the whole value in a popover.
    @objc func showValue(_ sender: Any?) {
        guard let source = queries.source else { return }
        var row = table.clickedRow, columnID: String?
        if row >= 0, table.clickedColumn >= 0, table.clickedColumn < table.tableColumns.count {
            columnID = table.tableColumns[table.clickedColumn].id
        } else if let focused = table.focusedCell {
            row = focused.row
            columnID = focused.columnID
        }
        guard let columnID, let index = Int(columnID), let text = source.fullText(row: row, columnIndex: index),
              let frame = table.frameOfCell(row: row, columnID: columnID) else { return }
        let title = source.result.names[index] + ": " + source.result.typeNames[index]
        CellInspector.show(text, title: title, relativeTo: frame, of: table)
    }

    /// A right-click on rows: the value, and killing what the rows are (in Running Queries, Mutations).
    func tableView(_ tableView: GHTableView, menuForRows rows: IndexSet, clickedRow: Int?, column: GHTableColumn?) -> NSMenu? {
        guard let source = queries.source else { return nil }
        let menu = NSMenu()
        if let row = clickedRow, let column, let index = Int(column.id), let text = source.fullText(row: row, columnIndex: index) {
            menu.addItem(MenuAction(String(localized: "Show Value")) { [weak self] in self?.showValue(nil) }.item)
            menu.addItem(MenuAction(String(localized: "Copy Value")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }.item)
        }
        if !rows.isEmpty {
            menu.addItem(MenuAction(rows.count == 1 ? String(localized: "Copy Row") : String(localized: "Copy \(rows.count.formatted()) Rows")) {
                [weak tableView] in
                guard let tableView else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tableView.copyText(forRows: rows), forType: .string)
            }.item)
            if let title = queries.killTitle {
                menu.addItem(.separator())
                menu.addItem(MenuAction(rows.count == 1 ? title : "\(title) (\(rows.count.formatted()))") { [weak self] in
                    self?.queries.kill(rows: rows)
                }.item)
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    func tableViewDidChangeActivity(_ tableView: GHTableView) {
        updateStatus()
        #if DEBUG
        debugActivityChanged()
        #endif
    }

    #if DEBUG
    /// `-ViewerSort <column>[,desc]` and `-ViewerSearch <text>` once the result is
    /// in; their times as `VIEWER-ACTION` lines on stderr.
    private var debugActions: [String] = []
    private var debugStarted: ContinuousClock.Instant?
    private var debugActionsStarted = false

    private func debugStartActions() {
        guard !debugActionsStarted, case .finished(let stats) = queries.state else { return }
        debugActionsStarted = true
        FileHandle.standardError.write(Data("VIEWER-ACTION result \(stats.rows) rows in \(QueryController.seconds(stats.elapsed)) s, first rows \(stats.firstRows.map(QueryController.seconds) ?? 0) s\n".utf8))
        // `-ViewerKillAll YES`: every row of the view shown killed (Running Queries, Mutations).
        if UserDefaults.standard.bool(forKey: "ViewerKillAll"), let count = queries.source?.result.rowCount, count > 0 {
            FileHandle.standardError.write(Data("VIEWER-ACTION killing \(count) rows\n".utf8))
            queries.kill(rows: IndexSet(0..<count))
        }
        if let sort = UserDefaults.standard.string(forKey: "ViewerSort") { debugActions.append("sort:" + sort) }
        if let search = UserDefaults.standard.string(forKey: "ViewerSearch") { debugActions.append("search:" + search) }
        debugNextAction()
    }

    private func debugNextAction() {
        guard !debugActions.isEmpty else { return }
        let action = debugActions.removeFirst()
        debugStarted = ContinuousClock.now
        if action.hasPrefix("sort:") {
            let parts = action.dropFirst(5).split(separator: ",")
            guard let name = parts.first, let index = queries.source?.result.names.firstIndex(of: String(name)) else { return }
            table.sortDescriptors = [NSSortDescriptor(key: String(index), ascending: parts.count < 2)]
        } else {
            searchField.stringValue = String(action.dropFirst(7))
            queries.search(searchField.stringValue)
        }
        if !table.isBusy { debugActivityChanged() }
    }

    private func debugActivityChanged() {
        guard let started = debugStarted, !table.isSortingRows, !table.isSearchingRows else { return }
        debugStarted = nil
        FileHandle.standardError.write(Data("VIEWER-ACTION done in \(QueryController.seconds(ContinuousClock.now - started)) s, \(table.numberOfRows) rows shown\n".utf8))
        DispatchQueue.main.async { self.debugNextAction() }
    }
    #endif

    /// Edit > Copy: Gingham's Copy in the table; the text's elsewhere.
    @objc func copyRows(_ sender: Any?) {
        let responder = window?.firstResponder as? NSView
        guard let responder, responder === table || responder.isDescendant(of: table) else {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
            return
        }
        table.copy(sender)
    }

    @objc func showSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    @objc func refreshSchema(_ sender: Any?) {
        sidebar.reload()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        queries.search(searchField.stringValue)
    }

    // MARK: Export

    /// File > Export…: the statement run again by the server, written in a
    /// format it makes (CSV, TSV, Parquet, Arrow, JSON lines) into a file:
    /// all its rows, not only those kept here.
    @objc func exportResult(_ sender: Any?) {
        guard let sql = queries.statement, CHSQL.formatClause(of: sql) == nil else { return }
        let formats: [(title: String, format: String, ext: String)] = [
            ("CSV", "CSVWithNames", "csv"), ("TSV", "TSVWithNames", "tsv"), ("Parquet", "Parquet", "parquet"),
            ("Arrow", "Arrow", "arrow"), (String(localized: "JSON lines"), "JSONEachRow", "jsonl"),
        ]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "result.csv"
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: formats.map(\.title))
        let accessory = NSStackView(views: [NSTextField(labelWithString: String(localized: "Format:")), popUp])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        let chooser = FormatChooser(panel: panel, formats: formats.map(\.ext))
        popUp.target = chooser
        popUp.action = #selector(FormatChooser.chose(_:))
        panel.beginSheetModal(for: window!) { [weak self] response in
            _ = chooser
            guard let self, response == .OK, let url = panel.url else { return }
            let format = formats[max(0, popUp.indexOfSelectedItem)].format
            statusLabel.stringValue = String(localized: "Exporting…")
            Task {
                do {
                    let bytes = try await self.client.download(sql, format: format, to: url, parameters: self.parameterValues) { written in
                        Task { @MainActor [weak self] in
                            self?.statusLabel.stringValue = String(localized: "Exporting… \(ByteCountFormatter.string(fromByteCount: Int64(written), countStyle: .file))")
                        }
                    }
                    self.statusLabel.stringValue = String(localized: "Exported \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) to \(url.lastPathComponent).")
                } catch {
                    self.show(error)
                }
            }
        }
    }

    /// Keeps the save panel's extension in step with the chosen format.
    private final class FormatChooser: NSObject {
        let panel: NSSavePanel
        let formats: [String]

        init(panel: NSSavePanel, formats: [String]) {
            self.panel = panel
            self.formats = formats
        }

        @objc func chose(_ sender: NSPopUpButton) {
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = name + "." + formats[max(0, sender.indexOfSelectedItem)]
        }
    }

    // MARK: Toolbar

    private static let runItem = NSToolbarItem.Identifier("run")
    private static let stopItem = NSToolbarItem.Identifier("stop")
    private static let historyItem = NSToolbarItem.Identifier("history")
    private static let exportItem = NSToolbarItem.Identifier("export")
    private static let searchItem = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.runItem, Self.stopItem, Self.historyItem, .flexibleSpace, Self.exportItem, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = title
            item.toolTip = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch identifier {
        case Self.runItem: return button(String(localized: "Run"), "play.fill", #selector(runStatement(_:)))
        case Self.stopItem: return button(String(localized: "Stop"), "stop.fill", #selector(stopQuery(_:)))
        case Self.exportItem: return button(String(localized: "Export"), "square.and.arrow.up", #selector(exportResult(_:)))
        case Self.historyItem:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "History")
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: item.label)
            item.showsIndicator = true
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            return item
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = searchField
            searchField.placeholderString = String(localized: "Find in result")
            searchField.delegate = self
            return item
        default:
            return nil
        }
    }

    @objc func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.stopItem: queries.isRunning
        case Self.exportItem: queries.statement != nil
        default: true
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(stopQuery(_:)): queries.isRunning
        case #selector(exportResult(_:)): queries.statement != nil
        case #selector(showValue(_:)): queries.source != nil
        case #selector(checkStatement(_:)): client.serverInfo != nil
        default: true
        }
    }

    /// The history menu: the last statements run, newest first.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !history.entries.isEmpty else {
            menu.addItem(withTitle: String(localized: "No statements yet"), action: nil, keyEquivalent: "")
            return
        }
        for entry in history.entries.prefix(40) {
            let oneLine = entry.sql.split(whereSeparator: \.isNewline).joined(separator: " ")
            let title = oneLine.count > 90 ? String(oneLine.prefix(90)) + "…" : oneLine
            let item = NSMenuItem(title: title, action: #selector(chooseHistory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.sql
            item.toolTip = entry.sql
            menu.addItem(item)
        }
    }

    @objc private func chooseHistory(_ sender: NSMenuItem) {
        guard let sql = sender.representedObject as? String else { return }
        replaceEditorText(sql)
        window?.makeFirstResponder(editor)
    }
}

/// A menu item that runs a closure (kept alive by the item).
final class MenuAction: NSObject {
    private let body: () -> Void
    private(set) var item: NSMenuItem!

    init(_ title: String, _ body: @escaping () -> Void) {
        self.body = body
        super.init()
        item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = self
    }

    nonisolated(unsafe) static var key = 0

    @objc private func run(_ sender: Any?) { body() }

    @objc func perform(_ sender: Any?) { body() }
}

/// The editor: SQL as typed, no smart quotes or substitutions.
final class SQLTextView: NSTextView {
    convenience init() {
        self.init(frame: .zero)
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        font = SQLHighlighting.font
        textContainerInset = NSSize(width: 6, height: 8)
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }

    /// The words completed (once loaded).
    var completions: Completions?
    private var isInsertingCompletion = false
    private var completesAfterChange = false

    /// The name being typed: letters, digits, `_` and `$` back from the cursor.
    override var rangeForUserCompletion: NSRange {
        Completions.partialWord(in: string as NSString, before: selectedRange().location)
    }

    /// Typing a name's second letter (or more) offers its completions.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard !isInsertingCompletion, let typed = string as? String, typed.count == 1,
              let scalar = typed.unicodeScalars.first, Completions.isNameCharacter(scalar), selectedRange().length == 0 else { return }
        let partial = rangeForUserCompletion
        guard partial.length >= 2, let completions, !completions.matches((self.string as NSString).substring(with: partial)).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.complete(nil)
        }
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        isInsertingCompletion = true
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        isInsertingCompletion = false
    }

    /// Typing keeps the editor's font and color (the highlighting adds the rest).
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { [.font: SQLHighlighting.font, .foregroundColor: SQLHighlighting.textColor] }
        set {}
    }
}
