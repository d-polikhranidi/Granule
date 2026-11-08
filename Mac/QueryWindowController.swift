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
    /// Beside the result: the focused cell's whole value and its row (View > Show Inspector).
    private let inspector = ResultInspector()
    private var inspectorItem: NSSplitViewItem?
    private var inspectorObservation: NSKeyValueObservation?
    /// Gingham doesn't say when its cursor moves: looked at after each key and click in the window.
    private var focusMonitor: Any?
    private let editor = SQLTextView()
    private let textOutput = NSTextView()
    private let planOutline = PlanOutline()
    /// Explain Pipeline: the processors and their streams, drawn.
    private let pipelineCanvas = PipelineCanvas(frame: .zero)
    private let pipelineScroll = NSScrollView()
    /// The result as a chart (View > Show Chart), its columns in the bar above it.
    private let chart = ChartController()
    private let chartBar = NSStackView()
    private let chartX = NSPopUpButton()
    private let chartY = NSPopUpButton(frame: .zero, pullsDown: true)
    private let chartKind = NSSegmentedControl(labels: [String(localized: "Automatic"), String(localized: "Line"), String(localized: "Bars")],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private var isShowingChart = false
    /// Over the result while a table's details show: its name and which detail.
    private let detailsBar = NSStackView()
    private let detailsTitle = NSTextField(labelWithString: "")
    private let detailsPicker = NSSegmentedControl(labels: TableDetail.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private var detailsTable: Schema.Table?
    private var textScroll: NSScrollView!
    private let editorScroll = NSScrollView()
    /// Where the result shows (the table, a text, a plan, a chart).
    private let resultsView = NSView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// The toolbar's middle: the server and what the window is doing.
    private lazy var activity = QueryActivityView(server: endpoint.database.isEmpty ? "\(endpoint.user)@\(endpoint.host)"
                                                      : "\(endpoint.user)@\(endpoint.host) · \(endpoint.database)",
                                                  environment: endpoint.environment)
    /// What the indicator says while no statement runs (the server, once connected).
    private var idleActivity = String(localized: "Connecting…")
    private weak var runToolbarItem: NSToolbarItem?
    private let searchField = NSSearchField()
    private var queries: QueryController!
    private let history: QueryHistory
    private var statusTimer: Timer?
    private var highlightPending = false
    /// The values last given to each parameter, offered again.
    private var parameterValues: [String: String] = [:]

    /// `client`: one already connected (the connections window's Connect), else its own.
    init(endpoint: CHEndpoint, password: String, tabNumber: Int = 0, client: CHClient? = nil) {
        self.endpoint = endpoint
        self.password = password
        self.tabNumber = tabNumber
        self.client = client ?? CHClient(endpoint: endpoint, password: password, identity: Connections.shared.clientIdentity(for: endpoint))
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
        queries = QueryController(client: self.client, table: table)
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
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 600
        // Hidden at first; then as the user leaves it (the split's autosave).
        inspectorItem.isCollapsed = true
        split.addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem
        inspectorObservation = inspectorItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateInspector() }
        }
        inspector.onPickColumn = { [weak self] index in self?.focusColumn(index) }
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            if let self, event.window === window {
                DispatchQueue.main.async { [weak self] in self?.updateInspector() }
            }
            return event
        }
        if #available(macOS 26.0, *) {
            // The filter over the schema, and the status under the result: the system's accessories.
            _ = sidebar.view
            let filter = NSSplitViewItemAccessoryViewController()
            filter.view = sidebar.filterBar
            sidebarItem.addTopAlignedAccessoryViewController(filter)
            let status = NSSplitViewItemAccessoryViewController()
            status.view = statusBar()
            paneItem.addBottomAlignedAccessoryViewController(status)
        }
        split.splitView.autosaveName = "QuerySplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 820))
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }

        let toolbar = NSToolbar(identifier: "Query")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.activityItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        sidebar.client = client
        sidebar.onShowRows = { [weak self] table, all in self?.showRows(of: table, all: all) }
        sidebar.onShowCreate = { [weak self] table in self?.showCreate(of: table) }
        sidebar.onInsert = { [weak self] text in self?.insert(text) }
        sidebar.onShowDetails = { [weak self] table in self?.showDetails(of: table, .overview) }
        sidebar.onChooseCluster = { [weak self] cluster in
            guard let self else { return }
            queries.cluster = cluster
            // The view shown, read again in its new scope.
            if let view = queries.view { sidebar.onShowView(view) }
        }
        sidebar.onShowView = { [weak self] view in
            self?.hideDetails()
            self?.messageLabel.isHidden = true
            self?.queries.show(view)
            self?.startStatusTimer()
        }

        queries.confirmStoppingWrite = { [weak self] proceed in self?.askToStopWrite(then: proceed) }
        queries.onScriptStep = { [weak self] index in self?.showScriptStatement(index, selecting: false) }
        queries.onChange = { [weak self] in
            self?.updateStatus()
            self?.updateInspector()
        }
        queries.onText = { [weak self] text in self?.showText(text) }
        queries.onKillFailure = { [weak self] error in
            guard let window = self?.window else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Not everything was killed")
            alert.informativeText = error.viewerDescription
            alert.beginSheetModal(for: window)
        }
    }

    private func buildPane() -> NSView {
        // The editor.
        editorScroll.hasVerticalScroller = true
        editorScroll.documentView = editor
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textStorage?.delegate = self
        editor.delegate = self
        editor.setAccessibilityLabel(String(localized: "SQL editor"))
        editor.string = UserDefaults.standard.string(forKey: editorKey) ?? (tabNumber == 0 ? "SELECT version(), uptime(), timezone()\n" : "")
        if let storage = editor.textStorage { SQLHighlighting.apply(to: storage) }

        // The result: the table, or a statement's text, or its error.
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(showValue(_:))
        table.allowsMultipleSelection = true
        table.navigatesByCell = true
        table.autosaveName = nil
        // (Then as the statement goes: `QueryController.updateEmptyState`.)
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

        let results = resultsView
        planOutline.isHidden = true
        chart.view.isHidden = true
        pipelineScroll.documentView = pipelineCanvas
        pipelineScroll.hasVerticalScroller = true
        pipelineScroll.hasHorizontalScroller = true
        pipelineScroll.isHidden = true
        for view in [table, textScroll!, planOutline, chart.view, pipelineScroll] as [NSView] {
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
        chartX.controlSize = .small
        chartX.target = self
        chartX.action = #selector(chartXChanged(_:))
        chartY.controlSize = .small
        chartKind.controlSize = .small
        chartKind.selectedSegment = 0
        chartKind.target = self
        chartKind.action = #selector(chartKindChanged(_:))
        chartBar.setViews([NSTextField(labelWithString: String(localized: "Along:")), chartX,
                           NSTextField(labelWithString: String(localized: "Measures:")), chartY, chartKind], in: .leading)
        chartBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 2, right: 10)
        chartBar.isHidden = true
        chart.onChange = { [weak self] in self?.updateChartMenus() }
        var bottomViews: [NSView] = [detailsBar, chartBar, messageLabel, results]
        // Before macOS 26 the status line is under the result here; after, the pane's bottom accessory.
        if #unavailable(macOS 26.0) { bottomViews.append(statusLabel) }
        let bottom = NSStackView(views: bottomViews)
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 4
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        if bottomViews.contains(statusLabel) { bottom.setCustomSpacing(6, after: results) } else { bottom.edgeInsets.bottom = 0 }
        results.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        detailsBar.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        chartBar.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        for label in bottomViews.contains(statusLabel) ? [messageLabel, statusLabel] : [messageLabel] {
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
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceDidChange(_:)), name: AppearanceSettings.didChange, object: nil)
        guard #available(macOS 26.0, *) else { return split }
        // Above the status accessory: the table doesn't read safe areas, so it ends where they begin.
        let container = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor),
        ])
        return container
    }

    @objc private func appearanceDidChange(_ notification: Notification) {
        applyAppearance()
    }

    /// Settings > Appearance on the editor and the result: the theme and sizes, dark
    /// backgrounds, and a production server's tint (it wins over the theme's background).
    private func applyAppearance() {
        if let storage = editor.textStorage {
            let selection = editor.selectedRanges
            SQLHighlighting.apply(to: storage, problems: underlined)
            editor.selectedRanges = selection
        }
        textOutput.font = SQLHighlighting.font
        let dark = AppearanceSettings.darkContent ? NSAppearance(named: .darkAqua) : nil
        editorScroll.appearance = dark
        resultsView.appearance = dark
        if endpoint.environment == .production {
            // So its statements aren't taken for a test server's.
            editor.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.24, green: 0.13, blue: 0.13, alpha: 1) : NSColor(srgbRed: 1, green: 0.955, blue: 0.95, alpha: 1)
            }
        } else {
            editor.backgroundColor = AppearanceSettings.theme.background ?? .textBackgroundColor
        }
        editor.insertionPointColor = AppearanceSettings.theme.text ?? .textColor
        var style = table.tableStyle
        style.fontSize = AppearanceSettings.resultFontSize
        table.tableStyle = style
        // Set again so the rows' height follows a new text size too.
        table.density = nil
        table.density = switch AppearanceSettings.resultDensity {
        case "compact": .compact
        case "spacious": .spacious
        default: .regular
        }
        table.usesAlternatingRowBackgroundColors = AppearanceSettings.alternatingRows
        inspector.applyAppearance()
    }

    /// The status line as the pane's bottom accessory (macOS 26 and later).
    private func statusBar() -> NSView {
        let bar = NSView()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -4),
            statusLabel.topAnchor.constraint(equalTo: bar.topAnchor, constant: 2),
            statusLabel.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -2),
        ])
        return bar
    }

    // MARK: Connecting

    func connect() {
        statusLabel.stringValue = endpoint.isCloud ? String(localized: "Connecting (a sleeping service takes a while to wake)…")
            : String(localized: "Connecting…")
        Task { [weak self] in
            guard let self else { return }
            do {
                // Connected already when the connections window checked it.
                let info: CHServerInfo
                if let known = client.serverInfo {
                    info = known
                } else {
                    if let bastion = endpoint.ssh {
                        statusLabel.stringValue = String(localized: "Connecting to the SSH server \(bastion.host)…")
                        try await Connections.shared.route(client, for: endpoint)
                        statusLabel.stringValue = String(localized: "Connecting…")
                    }
                    info = try await client.connect(timeout: endpoint.isCloud ? 120 : 20)
                }
                let via = endpoint.ssh.map { String(localized: " via \($0.host)") } ?? ""
                window?.subtitle = "ClickHouse \(info.version.text)\(via)"
                idleActivity = String(localized: "Connected · \(info.timeZone)")
                updateActivity()
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
                // `-ViewerChart YES`: the result as a chart.
                if UserDefaults.standard.bool(forKey: "ViewerChart") { toggleChart(nil) }
                // `-ViewerPipeline <SQL>`: its pipeline drawn.
                if let sql = UserDefaults.standard.string(forKey: "ViewerPipeline") {
                    editor.string = sql
                    showPipeline(of: sql)
                }
                // `-ViewerPlan <SQL>`: its plan shown (Explain Plan).
                if let sql = UserDefaults.standard.string(forKey: "ViewerPlan") {
                    editor.string = sql
                    showPlan(of: sql)
                }
                // `-ViewerShowRows <db.table>[,all]`: Show Rows (or Show All Rows) of that table.
                if let shown = UserDefaults.standard.string(forKey: "ViewerShowRows") {
                    let parts = shown.split(separator: ","), name = parts[0].split(separator: ".", maxSplits: 1)
                    if name.count == 2 {
                        showRows(of: Schema.Table(database: String(name[0]), name: String(name[1]), engine: "", rows: nil, bytes: nil, comment: ""),
                                 all: parts.count > 1 && parts[1] == "all")
                    }
                }
                // `-ViewerCluster <name>`: the views read across that cluster.
                if let cluster = UserDefaults.standard.string(forKey: "ViewerCluster") { queries.cluster = cluster }
                // `-ViewerView <name>`: a server view shown (processes, merges, …).
                if let name = UserDefaults.standard.string(forKey: "ViewerView"), let view = ServerView(rawValue: name) {
                    sidebar.onShowView(view)
                }
                if let sql = UserDefaults.standard.string(forKey: "ViewerRun") {
                    editor.string = sql
                    // `-ViewerRunAll YES`: its statements run one after another (Run All Statements).
                    if UserDefaults.standard.bool(forKey: "ViewerRunAll") { runAllStatements(nil) } else { run(sql) }
                }
                // `-ViewerSaveAs <name>`: the `-ViewerRun` statement saved by that name (with
                // `-ViewerSavedQueries <file>`, in a list of the check's own); `-ViewerLibrary saved|history`: the sheet.
                if let name = UserDefaults.standard.string(forKey: "ViewerSaveAs"), let sql = UserDefaults.standard.string(forKey: "ViewerRun") {
                    SavedQueries.shared.save(sql, as: name)
                }
                if let library = UserDefaults.standard.string(forKey: "ViewerLibrary") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showLibrary(library == "history" ? .history : .saved) }
                }
                FileHandle.standardError.write(Data("VIEWER-WINDOW \(window?.windowNumber ?? 0)\n".utf8))
                #endif
            } catch {
                idleActivity = String(localized: "Not connected")
                updateActivity()
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

    /// A live view waits while the window can't be seen (another tab, minimized, covered).
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        queries.isPaused = !window.occlusionState.contains(.visible)
    }

    func windowWillClose(_ notification: Notification) {
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
        focusMonitor = nil
        if Connections.shared.keeps(endpoint.id) {
            UserDefaults.standard.set(editor.string, forKey: editorKey)
        } else {
            // Removed while open, or never saved: nothing of it is kept (AppKit saves the window's place as it closes).
            let id = endpoint.id
            DispatchQueue.main.async { Connections.forget(id) }
        }
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
        confirmProduction(sql) { [weak self] in
            guard let self else { return }
            let parameters = CHSQL.parameters(of: sql)
            let go: ([String: String]) -> Void = { [weak self] values in
                self?.confirmLargeRead(sql, values: values) { self?.start(sql, values: values) }
            }
            if parameters.isEmpty { go([:]) } else { askForValues(of: parameters, then: go) }
        }
    }

    /// The estimate before a run, if one is asked for: a new run or Stop cancels it.
    private var estimate: Task<Void, Never>?

    /// Before a query the server estimates to read more rows than Settings › Queries allows:
    /// asked first, with a way not to be asked again.
    private func confirmLargeRead(_ sql: String, values: [String: String], then run: @escaping () -> Void) {
        estimate?.cancel()
        guard LargeReads.asks else { return run() }
        let starts = queries.starts
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = String(localized: "Estimating the rows it reads…")
        estimate = Task { [weak self] in
            guard let self else { return }
            let question = await queries.largeReadQuestion(for: sql, parameters: values)
            // Another run asked meanwhile, Stop, or something else ran (a view): this one doesn't.
            guard !Task.isCancelled, queries.starts == starts else { return }
            estimate = nil
            guard let question else { return run() }
            // Without a window to ask in, nothing runs.
            guard let window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = question.title
            alert.informativeText = question.detail
            alert.addButton(withTitle: String(localized: "Run"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.showsSuppressionButton = true
            // (Settings › Queries turns it on again.)
            alert.suppressionButton?.title = String(localized: "Don't ask again")
            alert.beginSheetModal(for: window) { [weak self] response in
                if alert.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: LargeReads.asksKey) }
                if response == .alertFirstButtonReturn { run() } else { self?.updateStatus() }
            }
        }
    }

    /// Before a statement that drops, deletes or rewrites data on a production server that
    /// isn't read only: its name typed, as GitHub asks before deleting a repository.
    private func confirmProduction(_ sql: String, then run: @escaping () -> Void) {
        confirmProduction(queries.productionQuestion(for: sql), then: run)
    }

    private func confirmProduction(_ question: (title: String, detail: String, name: String)?, then run: @escaping () -> Void) {
        guard let question else { return run() }
        // Without a window to ask in, nothing runs.
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = question.title
        alert.informativeText = question.detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = question.name
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Run"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let runButton = alert.buttons[0]
        runButton.hasDestructiveAction = true
        runButton.isEnabled = false
        let watcher = TextWatcher { text in runButton.isEnabled = text.trimmingCharacters(in: .whitespaces) == question.name }
        field.delegate = watcher
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            withExtendedLifetime(watcher) {}
            guard response == .alertFirstButtonReturn, field.stringValue.trimmingCharacters(in: .whitespaces) == question.name else { return }
            run()
        }
    }

    /// Before what runs next stops a statement that changes data halfway (`QueryController`
    /// asks for Run, server views and details alike): a killed write stays half done.
    private func askToStopWrite(then proceed: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "A statement that changes data is still running")
        alert.informativeText = String(localized: "Going on stops it, and what it already changed stays changed. Wait for it, or open a new tab (⌘T).")
        alert.addButton(withTitle: String(localized: "Stop It and Go On"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            proceed()
        }
    }

    /// Kill on rows: asked first (what a killed mutation leaves, across a cluster or not).
    /// The plan was read when the menu opened: a live view's rows move meanwhile.
    private func confirmKill(_ plan: QueryController.KillPlan) {
        guard let window else { return }
        let question = queries.killQuestion(for: plan)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: String(localized: "Kill"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.queries.kill(plan)
        }
    }

    /// Query > Run All Statements (⇧⌘↩): the selection's statements, or the editor's, one after
    /// another in this tab's session; the last one's rows shown, the first that fails stops them.
    @objc func runAllStatements(_ sender: Any?) {
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        let base = selection.length > 0 ? selection : NSRange(location: 0, length: text.length)
        let ranges = CHSQL.statements(text.substring(with: base)).map { NSRange(location: $0.location + base.location, length: $0.length) }
        guard !ranges.isEmpty else { return }
        let statements = ranges.map { text.substring(with: $0) }
        scriptRanges = ranges
        scriptText = editor.string
        confirmProduction(queries.productionQuestion(forScript: statements)) { [weak self] in
            guard let self else { return }
            var seen = Set<String>()
            let parameters = statements.flatMap(CHSQL.parameters(of:)).filter { seen.insert($0.name).inserted }
            let go: ([String: String]) -> Void = { [weak self] values in
                guard let self else { return }
                hideDetails()
                messageLabel.isHidden = true
                queries.runScript(statements, parameters: values)
                startStatusTimer()
            }
            if parameters.isEmpty { go([:]) } else { askForValues(of: parameters, then: go) }
        }
    }

    /// The editor's ranges of the script running, and its text then (typed over: not shown).
    private var scriptRanges: [NSRange] = []
    private var scriptText = ""

    /// The script's statement running, or the one it stopped at, shown in the editor.
    private func showScriptStatement(_ index: Int, selecting: Bool) {
        guard editor.string == scriptText, index < scriptRanges.count else { return }
        if selecting { editor.setSelectedRange(scriptRanges[index]) }
        editor.scrollRangeToVisible(scriptRanges[index])
        editor.showFindIndicator(for: scriptRanges[index])
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
        if estimate != nil {
            estimate?.cancel()
            estimate = nil
            updateStatus()
        }
        queries.cancel()
    }

    /// Query > Explain: the statement at the cursor (or the selection) as the
    /// server plans it (tag 0: PLAN with its indexes, 1: PIPELINE, 2: ESTIMATE, 3: SYNTAX).
    @objc func explainStatement(_ sender: Any?) {
        guard let sql = currentStatement() else { return }
        let kind = (sender as? NSMenuItem)?.tag ?? 0
        if kind == 0 { return showPlan(of: sql) }
        if kind == 1 { return showPipeline(of: sql) }
        let explain = switch kind {
        case 5: "EXPLAIN PIPELINE \(sql) FORMAT TSVRaw"
        case 4: "EXPLAIN PLAN indexes = 1 \(sql) FORMAT TSVRaw"
        case 1: "EXPLAIN PIPELINE \(sql) FORMAT TSVRaw"
        case 2: "EXPLAIN ESTIMATE \(sql)"
        case 3: "EXPLAIN SYNTAX \(sql) FORMAT TSVRaw"
        case 6: "EXPLAIN ANALYZE \(sql) FORMAT TSVRaw"
        default: "EXPLAIN PLAN indexes = 1 \(sql) FORMAT TSVRaw"
        }
        run(explain)
    }

    /// Explain Pipeline: its processors and streams drawn in the result's place.
    private func showPipeline(of sql: String) {
        statusLabel.stringValue = String(localized: "Explaining…")
        messageLabel.isHidden = true
        Task {
            do {
                let pipeline = try await client.pipeline(of: sql)
                pipelineCanvas.layout = PipelineLayout(pipeline)
                for view in [table, textScroll!, planOutline, chart.view] as [NSView] { view.isHidden = true }
                pipelineScroll.isHidden = false
                statusLabel.stringValue = String(localized: "The pipeline, not run: \(pipeline.nodes.count) processors")
            } catch {
                show(error)
                statusLabel.stringValue = ""
            }
        }
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
                pipelineScroll.isHidden = true
                chart.view.isHidden = true
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

    private func showRows(of table: Schema.Table, all: Bool) {
        Task {
            let sql = await Schema.previewStatement(of: table, client: client, all: all)
            preview = all ? nil : sql
            replaceEditorText(sql)
            run(sql)
        }
    }

    /// The Show Rows statement that read the first rows only: said under the editor when they fill it.
    private var preview: String?

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

    /// A statement's text output in place of the table (`nil`: the table, or the chart, again).
    private func showText(_ text: String?) {
        planOutline.isHidden = true
        pipelineScroll.isHidden = true
        textScroll.isHidden = text == nil
        table.isHidden = text != nil || isShowingChart
        chart.view.isHidden = text != nil || !isShowingChart
        textOutput.string = text ?? ""
    }

    private func show(_ error: Error) {
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = error.viewerDescription
        messageLabel.isHidden = false
    }

    // MARK: Chart

    /// View > Show Chart: the result as a chart in the table's place (and back).
    @objc func toggleChart(_ sender: Any?) {
        isShowingChart.toggle()
        planOutline.isHidden = true
        pipelineScroll.isHidden = true
        textScroll.isHidden = true
        table.isHidden = isShowingChart
        chart.view.isHidden = !isShowingChart
        chartBar.isHidden = !isShowingChart
        updateChart()
        window?.toolbar?.validateVisibleItems()
    }

    private func updateChart() {
        guard isShowingChart else { return }
        chart.update(source: queries.source, table: table, isRunning: queries.isRunning, timeZone: client.serverInfo?.zone ?? .gmt)
    }

    /// The bar's menus: the columns along x, the measures checked.
    private func updateChartMenus() {
        chartX.removeAllItems()
        for column in chart.columns {
            chartX.addItem(withTitle: column.name)
            chartX.lastItem?.tag = column.index
        }
        if let x = chart.x { chartX.selectItem(withTag: x) }
        chartY.removeAllItems()
        let measures = chart.columns.filter { $0.isNumber && $0.index != chart.x }
        chartY.addItem(withTitle: chart.ys.compactMap { y in chart.columns.first { $0.index == y }?.name }.joined(separator: ", "))
        for column in measures {
            let item = NSMenuItem(title: column.name, action: #selector(chartYToggled(_:)), keyEquivalent: "")
            item.target = self
            item.tag = column.index
            item.state = chart.ys.contains(column.index) ? .on : .off
            chartY.menu?.addItem(item)
        }
        chartY.isEnabled = !measures.isEmpty
        updateChart()
    }

    @objc private func chartXChanged(_ sender: NSPopUpButton) {
        chart.choose(x: sender.selectedTag())
    }

    @objc private func chartYToggled(_ sender: NSMenuItem) {
        chart.toggle(y: sender.tag)
    }

    @objc private func chartKindChanged(_ sender: NSSegmentedControl) {
        chart.kind = ChartModel.Kind.allCases[max(0, sender.selectedSegment)]
    }

    /// The toolbar's indicator and the Run button (Stop while a statement runs).
    private func updateActivity() {
        let running = queries?.isRunning ?? false
        activity.update(detail: queries?.briefStatus.isEmpty == false ? queries.briefStatus : idleActivity, running: running)
        guard let runToolbarItem else { return }
        runToolbarItem.label = running ? String(localized: "Stop") : String(localized: "Run")
        runToolbarItem.toolTip = running ? String(localized: "Stop (⌘.)") : String(localized: "Run (⌘↩)")
        runToolbarItem.image = NSImage(systemSymbolName: running ? "stop.fill" : "play.fill", accessibilityDescription: runToolbarItem.label)
    }

    @objc private func runOrStop(_ sender: Any?) {
        if queries.isRunning { stopQuery(sender) } else { runStatement(sender) }
    }

    private func updateStatus() {
        updateChart()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = queries.status
        updateActivity()
        if let error = queries.error {
            show(error)
            if let failed = queries.scriptFailure {
                showScriptStatement(failed, selecting: true)
                // Once: the cursor is the user's again.
                scriptRanges = []
            }
        }
        if !queries.isRunning {
            statusTimer?.invalidate()
            statusTimer = nil
            #if DEBUG
            debugStartActions()
            #endif
            // Query Details read too soon: the server writes its log every few seconds.
            if queries.isViewersOwn, case .finished(let stats) = queries.state, stats.rows == 0 {
                messageLabel.textColor = .secondaryLabelColor
                messageLabel.stringValue = String(localized: "The server hasn't written this run to its log yet: it does every few seconds. Try again in a moment.")
                messageLabel.isHidden = false
            }
            if case .finished(let stats) = queries.state, let preview, queries.statement == preview, stats.rows >= Schema.previewRows {
                messageLabel.textColor = .secondaryLabelColor
                messageLabel.stringValue = String(localized: "The first \(Schema.previewRows.formatted()) rows. Show All Rows in the table's menu reads them all.")
                messageLabel.isHidden = false
            }
            if case .finished(let stats) = queries.state, let sql = queries.statement, queries.isUsersStatement, !historySaved.contains(queries.starts) {
                // Once a run (a statement with its own FORMAT has no id the log knows: no Query Details for it).
                historySaved.insert(queries.starts)
                lastRun = history.add(sql, rows: stats.rows, seconds: QueryController.seconds(stats.elapsed),
                                      queryID: stats.queryID.isEmpty ? nil : stats.queryID)
            }
        }
        window?.toolbar?.validateVisibleItems()
    }

    /// The runs (`QueryController.starts`) already in the history.
    private var historySaved = Set<Int>()
    /// The last statement of the user's that finished here: Query Details shows it.
    private var lastRun: QueryHistory.Entry?

    /// Query > Query Details (⌥⌘D): the last statement's measures from the server's log
    /// (time, rows, bytes, memory, every ProfileEvent), beside its run before, if any.
    @objc func showQueryDetails(_ sender: Any?) {
        guard let run = lastRun, let id = run.queryID else { return }
        hideDetails()
        messageLabel.isHidden = true
        queries.runViewersOwn(QueryController.detailsSQL(of: id, comparedWith: run.previousQueryID))
        startStatusTimer()
    }

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

    /// Query > Format Statement (⌃⇧F): the selection, or the statement at the cursor, laid out
    /// by the server's own formatter. Edit > Undo takes it back (the formatter drops comments).
    @objc func formatStatement(_ sender: Any?) {
        var range = editor.selectedRange()
        if range.length == 0 {
            guard let statement = CHSQL.statement(at: range.location, in: editor.string) else { return }
            range = statement
        }
        let text = (editor.string as NSString).substring(with: range)
        let before = editor.string
        statusLabel.stringValue = String(localized: "Formatting…")
        Task {
            do {
                let formatted = try await client.format(text)
                // Typed over meanwhile: the place isn't the same text any more.
                guard editor.string == before else { return statusLabel.stringValue = "" }
                replace(range, with: formatted.text)
                editor.setSelectedRange(NSRange(location: range.location, length: (formatted.text as NSString).length))
                statusLabel.stringValue = formatted.droppedComments
                    ? String(localized: "Formatted. The server's formatter drops comments: Edit > Undo (⌘Z) brings them back.")
                    : String(localized: "Formatted.")
            } catch let error as CHServerError where error.code == 46 {
                statusLabel.stringValue = String(localized: "This server can't format statements: it has no formatQuery (newer ClickHouse versions do).")
            } catch {
                statusLabel.stringValue = String(localized: "Can't format: \(error.viewerSummary)")
            }
        }
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
        CellInspector.show(text, type: source.result.types[index], title: title, relativeTo: frame, of: table)
    }

    /// The inspector on the focused cell (or the selected row's first value), while it shows.
    private func updateInspector() {
        guard let inspectorItem, !inspectorItem.isCollapsed else { return }
        var row = -1, column = -1
        if let focused = table.focusedCell, let index = Int(focused.columnID) {
            row = focused.row
            column = index
        } else if table.selectedRow >= 0 {
            row = table.selectedRow
            column = 0
        }
        // The result's table only (not a statement's text, a plan or a chart).
        let source = table.isHidden ? nil : queries.source
        inspector.show(source, row: row, columnIndex: column)
    }

    /// A column picked in the inspector's row: its cell focused in the result, in view.
    private func focusColumn(_ index: Int) {
        let row = table.focusedCell?.row ?? table.selectedRow
        guard row >= 0 else { return }
        table.focusedCell = GHCellPosition(row: row, columnID: String(index))
        if let position = table.tableColumns.firstIndex(where: { $0.id == String(index) }) { table.scrollColumnToVisible(position) }
        updateInspector()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateInspector()
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
        // A number column: its cells as numbers, data bars or a heatmap.
        if let column, queries.holdsNumbers(column) {
            let name = column.title
            let looks = NSMenu()
            for look in QueryController.CellLook.allCases {
                let item = MenuAction(look.title) { [weak self] in self?.queries.setLook(look, ofColumn: name) }.item!
                item.state = queries.look(ofColumn: name) == look ? .on : .off
                looks.addItem(item)
            }
            let parent = NSMenuItem(title: String(localized: "Show “\(name)” As"), action: nil, keyEquivalent: "")
            parent.submenu = looks
            menu.addItem(parent)
        }
        if !rows.isEmpty {
            menu.addItem(MenuAction(rows.count == 1 ? String(localized: "Copy Row") : String(localized: "Copy \(rows.count.formatted()) Rows")) {
                [weak tableView] in
                guard let tableView else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tableView.copyText(forRows: rows), forType: .string)
            }.item)
            if let title = queries.killTitle, let plan = queries.killPlan(rows: rows) {
                menu.addItem(.separator())
                menu.addItem(MenuAction(rows.count == 1 ? title + "…" : "\(title) (\(rows.count.formatted()))…") { [weak self] in
                    self?.confirmKill(plan)
                }.item)
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    func tableViewDidChangeActivity(_ tableView: GHTableView) {
        if tableView === table { queries.tableActivityChanged() }
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
        // `-ViewerLook <name>=bars|heatmap,…`: those number columns' cells as data bars or a heatmap.
        if let looks = UserDefaults.standard.string(forKey: "ViewerLook") {
            for pair in looks.split(separator: ",") {
                let parts = pair.split(separator: "=").map(String.init)
                guard parts.count == 2 else { continue }
                queries.setLook(parts[1] == "heatmap" ? .heatmap : .dataBars, ofColumn: parts[0])
            }
        }
        // `-ViewerQueryDetails <seconds>`: Query Details of the statement run, that long after it.
        if let wait = UserDefaults.standard.string(forKey: "ViewerQueryDetails").flatMap(Double.init), queries.isUsersStatement {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.showQueryDetails(nil) }
        }
        // `-ViewerInspector <row>,<column>`: the inspector shown on that cell (result indexes).
        if let cell = UserDefaults.standard.string(forKey: "ViewerInspector") {
            let parts = cell.split(separator: ",").compactMap { Int($0) }
            if parts.count == 2 {
                table.focusedCell = GHCellPosition(row: parts[0], columnID: String(parts[1]))
                inspectorItem?.isCollapsed = false
                window?.makeFirstResponder(table)
                updateInspector()
            }
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
        // Export runs the statement again: a write would run twice.
        guard queries.canExport, let sql = queries.statement else { return }
        let formats: [(title: String, format: String, ext: String)] = [
            ("CSV", "CSVWithNames", "csv"), ("TSV", "TSVWithNames", "tsv"), ("Parquet", "Parquet", "parquet"),
            ("Arrow", "Arrow", "arrow"), (String(localized: "JSON lines"), "JSONEachRow", "jsonl"),
        ]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = queries.exportName + ".csv"
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: formats.map(\.title))
        let format = NSStackView(views: [NSTextField(labelWithString: String(localized: "Format:")), popUp])
        let note = NSTextField(wrappingLabelWithString: String(localized: "The server runs the statement again and writes all its rows: they may differ from those shown. File › Export Shown Rows… writes those."))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420
        let accessory = NSStackView(views: [format, note])
        accessory.orientation = .vertical
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
                        // (The export holds the window until it's done: so does this.)
                        Task { @MainActor in
                            self.statusLabel.stringValue = String(localized: "Exporting… \(Int64(written).formatted(.byteCount(style: .file)))")
                        }
                    }
                    self.statusLabel.stringValue = String(localized: "Exported \(Int64(bytes).formatted(.byteCount(style: .file))) to \(url.lastPathComponent).")
                } catch {
                    self.show(error)
                }
            }
        }
    }

    /// File > Export Shown Rows… (⌥⌘E): the rows as the table shows them (its sort, its search),
    /// as an Excel workbook or CSV, written by the table itself; nothing runs again.
    @objc func exportShownRows(_ sender: Any?) {
        table.exportFileName = queries.exportName
        table.exportDocument(sender)
    }

    /// Calls back as a field's text changes (the production question's Run button).
    private final class TextWatcher: NSObject, NSTextFieldDelegate {
        let changed: (String) -> Void

        init(_ changed: @escaping (String) -> Void) { self.changed = changed }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            changed(field.stringValue)
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
    private static let chartItem = NSToolbarItem.Identifier("chart")
    private static let activityItem = NSToolbarItem.Identifier("activity")

    // HIG: at most three groups, the main action prominent on the trailing edge, the state in the middle.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.historyItem, .flexibleSpace, Self.activityItem, .flexibleSpace,
         Self.chartItem, Self.exportItem, Self.searchItem, Self.runItem, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
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
        case Self.runItem:
            let item = button(String(localized: "Run"), "play.fill", #selector(runOrStop(_:)))
            item.toolTip = String(localized: "Run (⌘↩)")
            if #available(macOS 26.0, *) { item.style = .prominent }
            item.visibilityPriority = .high
            runToolbarItem = item
            return item
        case Self.activityItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Activity")
            item.view = activity
            item.visibilityPriority = .high
            return item
        case Self.stopItem: return button(String(localized: "Stop"), "stop.fill", #selector(stopQuery(_:)))
        case Self.exportItem: return button(String(localized: "Export"), "square.and.arrow.up", #selector(exportResult(_:)))
        case Self.chartItem: return button(String(localized: "Chart"), "chart.xyaxis.line", #selector(toggleChart(_:)))
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
        case Self.exportItem: queries.canExport
        default: true
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(stopQuery(_:)): queries.isRunning || estimate != nil
        case #selector(exportResult(_:)): queries.canExport
        case #selector(exportShownRows(_:)): queries.source != nil && table.numberOfRows > 0 && !table.isExporting
        case #selector(showValue(_:)): queries.source != nil
        case #selector(checkStatement(_:)), #selector(formatStatement(_:)): client.serverInfo != nil
        case #selector(showQueryDetails(_:)): lastRun?.queryID != nil && !queries.isRunning
        // Explain Analyze: 26.7 and later.
        case #selector(explainStatement(_:)): item.tag != 6 || queries.explainsAnalyze
        default: true
        }
    }

    /// The history menu: the last statements run, newest first.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The saved queries first, then the last statements run.
        let saved = SavedQueries.shared.queries
        if !saved.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Saved Queries")))
            for query in saved.prefix(20) {
                let item = NSMenuItem(title: query.name, action: #selector(chooseHistory(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = query.sql
                item.toolTip = query.sql
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        defer {
            menu.addItem(.separator())
            menu.addItem(MenuAction(String(localized: "Saved Queries and History…")) { [weak self] in self?.showLibrary(.history) }.item)
        }
        guard !history.entries.isEmpty else {
            menu.addItem(withTitle: String(localized: "No statements yet"), action: nil, keyEquivalent: "")
            return
        }
        menu.addItem(.sectionHeader(title: String(localized: "History")))
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

    /// Query > Save Query… (⌘S): the selection, or the statement at the cursor, kept by a
    /// name for every connection (Saved Queries and History, ⌘Y, finds it again).
    @objc func saveQuery(_ sender: Any?) {
        guard let sql = currentStatement(), let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Query")
        alert.informativeText = String(localized: "Saved queries are kept for every connection. Saved Queries and History (⌘Y) finds them.")
        let known = SavedQueries.shared.queries.first { $0.sql == sql }
        let field = NSTextField(string: known?.name ?? SavedQueries.suggestedName(for: sql))
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            if let existing = SavedQueries.shared.query(named: name), existing.sql != sql {
                let replace = NSAlert()
                replace.messageText = String(localized: "Replace “\(existing.name)”?")
                replace.informativeText = String(localized: "A saved query has this name already.")
                replace.addButton(withTitle: String(localized: "Replace"))
                replace.addButton(withTitle: String(localized: "Cancel"))
                replace.beginSheetModal(for: window) { [weak self] answer in
                    guard answer == .alertFirstButtonReturn else { return }
                    SavedQueries.shared.save(sql, as: name)
                    self?.statusLabel.stringValue = String(localized: "Saved as “\(name)”.")
                }
                return
            }
            SavedQueries.shared.save(sql, as: name)
            statusLabel.stringValue = String(localized: "Saved as “\(name)”.")
        }
    }

    /// Query > Saved Queries and History… (⌘Y).
    @objc func showQueryLibrary(_ sender: Any?) {
        showLibrary(.saved)
    }

    private func showLibrary(_ kind: QueryLibraryController.Kind) {
        let library = QueryLibraryController(history: history, kind: kind)
        library.onOpen = { [weak self] sql in
            guard let self else { return }
            replaceEditorText(sql)
            window?.makeFirstResponder(editor)
        }
        window?.contentViewController?.presentAsSheet(library)
    }

    @objc private func chooseHistory(_ sender: NSMenuItem) {
        guard let sql = sender.representedObject as? String else { return }
        replaceEditorText(sql)
        window?.makeFirstResponder(editor)
    }
}

/// Saved Queries and History (⌘Y): the queries saved by name and the statements this
/// connection ran, searched as typed. Open (or a double-click) puts one in the editor.
final class QueryLibraryController: NSViewController, GHTableViewDataSource, GHTableViewDelegate, NSSearchFieldDelegate {
    enum Kind: Int { case saved, history }

    /// The statement chosen, for the editor.
    var onOpen: (String) -> Void = { _ in }

    private let history: QueryHistory
    private var kind: Kind
    private let picker = NSSegmentedControl(labels: [String(localized: "Saved"), String(localized: "History")],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = GHTableView(frame: .zero)
    private let openButton = NSButton(title: String(localized: "Open"), target: nil, action: nil)
    private let renameButton = NSButton(title: String(localized: "Rename…"), target: nil, action: nil)
    private let deleteButton = NSButton(title: String(localized: "Delete…"), target: nil, action: nil)
    private var savedRows: [SavedQueries.Query] = []
    private var historyRows: [QueryHistory.Entry] = []

    init(history: QueryHistory, kind: Kind) {
        self.history = history
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 780, height: 460)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        picker.selectedSegment = kind.rawValue
        picker.target = self
        picker.action = #selector(pickKind(_:))
        search.placeholderString = String(localized: "Find in names and statements")
        search.delegate = self
        table.dataSource = self
        table.delegate = self
        table.sortsRows = true
        table.allowsMultipleSelection = false
        table.autosaveName = nil
        table.showsSummaryRow = false
        table.usesAlternatingRowBackgroundColors = false
        table.target = self
        table.doubleAction = #selector(open(_:))
        for button in [openButton, renameButton, deleteButton] { button.target = self }
        openButton.action = #selector(open(_:))
        openButton.keyEquivalent = "\r"
        renameButton.action = #selector(rename(_:))
        deleteButton.action = #selector(delete(_:))
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let top = NSStackView(views: [picker, search])
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [renameButton, deleteButton, NSView(), cancel, openButton])
        let stack = NSStackView(views: [top, table, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [top, table, bottom] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        table.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = stack
        showKind()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    @objc private func pickKind(_ sender: NSSegmentedControl) {
        kind = Kind(rawValue: sender.selectedSegment) ?? .saved
        showKind()
    }

    private func showKind() {
        table.columns = switch kind {
        case .saved: [
            .column(GHTableColumn("name", title: String(localized: "Name"), width: 200, minWidth: 80, maxWidth: 600)),
            .column(GHTableColumn("sql", title: String(localized: "Statement"), width: 380, minWidth: 120, maxWidth: 4_000)),
            .column(GHTableColumn("date", title: String(localized: "Saved.date", defaultValue: "Saved", comment: "When a query was saved"), width: 150, format: .date(includesTime: true))),
        ]
        case .history: [
            .column(GHTableColumn("date", title: String(localized: "Run"), width: 150, format: .date(includesTime: true))),
            .column(GHTableColumn("sql", title: String(localized: "Statement"), width: 400, minWidth: 120, maxWidth: 4_000)),
            .column(GHTableColumn("rows", title: String(localized: "Rows"), width: 80, alignment: .trailing, format: .number(fractionDigits: 0))),
            .column(GHTableColumn("seconds", title: String(localized: "Seconds"), width: 80, alignment: .trailing, format: .number(fractionDigits: 3))),
        ]
        }
        table.sortDescriptors = []
        filter()
    }

    private func filter() {
        let words = search.stringValue.lowercased().split(whereSeparator: \.isWhitespace)
        func matches(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return words.allSatisfy { lowered.contains($0) }
        }
        savedRows = SavedQueries.shared.queries.filter { matches($0.name + " " + $0.sql) }
        historyRows = history.entries.filter { matches($0.sql) }
        table.reloadData()
        if numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateButtons()
    }

    func controlTextDidChange(_ notification: Notification) { filter() }

    private func updateButtons() {
        let chosen = table.selectedRow >= 0
        openButton.isEnabled = chosen
        renameButton.isHidden = kind != .saved
        deleteButton.isHidden = kind != .saved
        renameButton.isEnabled = chosen
        deleteButton.isEnabled = chosen
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Rows

    func numberOfRows(in tableView: GHTableView) -> Int { kind == .saved ? savedRows.count : historyRows.count }

    func tableView(_ tableView: GHTableView, valueFor column: GHTableColumn, row: Int) -> GHCellValue {
        switch kind {
        case .saved:
            guard row < savedRows.count else { return .empty }
            let query = savedRows[row]
            return switch column.id {
            case "name": .text(query.name)
            case "sql": .text(SavedQueries.oneLine(query.sql))
            default: .date(query.date)
            }
        case .history:
            guard row < historyRows.count else { return .empty }
            let entry = historyRows[row]
            return switch column.id {
            case "date": .date(entry.date)
            case "sql": .text(SavedQueries.oneLine(entry.sql))
            case "rows": entry.rows.map { .number(Double($0)) } ?? .empty
            default: entry.seconds.map { .number($0) } ?? .empty
            }
        }
    }

    // MARK: Actions

    private var chosenSQL: String? {
        let row = table.selectedRow
        guard row >= 0 else { return nil }
        return kind == .saved ? (row < savedRows.count ? savedRows[row].sql : nil) : (row < historyRows.count ? historyRows[row].sql : nil)
    }

    @objc private func open(_ sender: Any?) {
        guard let sql = chosenSQL else { return }
        dismiss(nil)
        onOpen(sql)
    }

    @objc private func cancel(_ sender: Any?) { dismiss(nil) }

    @objc private func rename(_ sender: Any?) {
        guard kind == .saved, table.selectedRow >= 0, table.selectedRow < savedRows.count, let window = view.window else { return }
        let query = savedRows[table.selectedRow]
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename the Saved Query")
        let field = NSTextField(string: query.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if !SavedQueries.shared.rename(query.id, to: field.stringValue) {
                let taken = NSAlert()
                taken.messageText = String(localized: "Another saved query has this name.")
                taken.beginSheetModal(for: window)
            }
            self?.filter()
        }
    }

    @objc private func delete(_ sender: Any?) {
        guard kind == .saved, table.selectedRow >= 0, table.selectedRow < savedRows.count, let window = view.window else { return }
        let query = savedRows[table.selectedRow]
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(query.name)”?")
        alert.informativeText = String(localized: "It's gone for every connection.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            SavedQueries.shared.remove(query.id)
            self?.filter()
        }
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

/// The toolbar's middle, as Xcode shows a build: the server (its environment
/// as a colored tag) and what the window is doing, a spinner while it runs.
final class QueryActivityView: NSView {
    private let tagLabel = NSTextField(labelWithString: "")
    private let serverLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init(server: String, environment: CHEnvironment?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
        if let environment {
            let tag = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: environment.color])
            tag.append(NSAttributedString(string: environment.title.uppercased(), attributes: [.foregroundColor: environment.color]))
            tagLabel.attributedStringValue = tag
        }
        tagLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        tagLabel.isHidden = environment == nil
        serverLabel.stringValue = server
        serverLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        serverLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for label in [serverLabel, detailLabel] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let stack = NSStackView(views: [tagLabel, serverLabel, detailLabel, spinner])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(detail: String, running: Bool) {
        detailLabel.stringValue = detail
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        setAccessibilityLabel([tagLabel.isHidden ? nil : tagLabel.stringValue, serverLabel.stringValue, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

