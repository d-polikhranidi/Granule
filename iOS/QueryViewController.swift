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
    /// Over the result while a table's details show: its name and a menu of its details.
    private let detailsBar = UIStackView()
    private let detailsButton = UIButton(configuration: .gray())
    private var detailsTable: Schema.Table?
    /// The result as a chart (More > Show Chart), its columns in the bar's menus.
    private let chart = ChartController()
    private let chartBar = UIStackView()
    private var isShowingChart = false
    /// The server's clusters (the views can read across one).
    private var clusters: [String] = []

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
        if #available(iOS 26.0, *) {
            navigationItem.subtitle = [endpoint.environment?.title, endpoint.database.isEmpty ? nil : endpoint.database]
                .compactMap { $0 }.joined(separator: " · ")
        }
        let run = UIBarButtonItem(title: String(localized: "Run"), image: UIImage(systemName: "play.fill"),
                                  primaryAction: UIAction { [weak self] _ in self?.runStatement() })
        let stop = UIBarButtonItem(title: String(localized: "Stop"), image: UIImage(systemName: "stop.fill"),
                                   primaryAction: UIAction { [weak self] _ in self?.queries.cancel() })
        // The main action, on its own; Run and Stop are the last to go to the overflow menu.
        if #available(iOS 26.0, *) { run.style = .prominent }
        if #available(iOS 27.0, *) {
            run.visibilityPriority = .high
            stop.visibilityPriority = .high
        }
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
        // A production server's editor is tinted, so its statements aren't taken for a test one's.
        editor.backgroundColor = endpoint.environment == .production
            ? UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.24, green: 0.13, blue: 0.13, alpha: 1) : UIColor(red: 1, green: 0.955, blue: 0.95, alpha: 1) }
            : AppearanceSettings.theme.background ?? .secondarySystemBackground
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
        chart.view.isHidden = true
        for content in [table, textOutput, chart.view] as [UIView] {
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
        checker.database = { [weak self] in
            guard let self else { return nil }
            return queries.currentDatabase ?? (endpoint.database.isEmpty ? nil : endpoint.database)
        }
        detailsButton.showsMenuAsPrimaryAction = true
        detailsButton.changesSelectionAsPrimaryAction = false
        detailsBar.addArrangedSubview(detailsButton)
        detailsBar.addArrangedSubview(UIView())
        detailsBar.isLayoutMarginsRelativeArrangement = true
        detailsBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 12)
        detailsBar.isHidden = true
        chartBar.spacing = 8
        chartBar.isLayoutMarginsRelativeArrangement = true
        chartBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 12)
        chartBar.isHidden = true
        chart.onChange = { [weak self] in self?.updateChartBar() }
        let stack = UIStackView(arrangedSubviews: [editor, checkBar, detailsBar, chartBar, messageLabel, results, statusLabel])
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
        queries.onKillFailure = { [weak self] error in
            let alert = UIAlertController(title: String(localized: "Not everything was killed"), message: error.viewerDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            self?.present(alert, animated: true)
        }
        connect()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveEditor()
    }

    /// The editor's text kept for its connection (not for one removed or never saved).
    private func saveEditor() {
        guard Connections.shared.keeps(endpoint.id) else { return }
        UserDefaults.standard.set(editor.text, forKey: "Editor \(endpoint.id.uuidString)")
    }

    private func connect() {
        statusLabel.text = endpoint.isCloud ? String(localized: "Connecting (a sleeping service takes a while to wake)…") : String(localized: "Connecting…")
        Task {
            do {
                // Connected already when the list checked it.
                let info: CHServerInfo
                if let known = client.serverInfo {
                    info = known
                } else {
                    if let bastion = endpoint.ssh {
                        statusLabel.text = String(localized: "Connecting to the SSH server \(bastion.host)…")
                        try await Connections.shared.route(client, for: endpoint)
                        statusLabel.text = String(localized: "Connecting…")
                    }
                    info = try await client.connect(timeout: endpoint.isCloud ? 120 : 20)
                }
                statusLabel.text = String(localized: "Connected to ClickHouse \(info.version.text) (\(info.timeZone)).")
                onConnected()
                Task { [weak self, client] in self?.clusters = await ServerView.clusters(client) }
                Task { [weak self, client] in
                    let completions = await Completions.load(client)
                    self?.completions = completions
                    #if DEBUG
                    // `-ViewerComplete <text>`: the text typed, the editor focused (its completions in the bar).
                    if let self, let name = UserDefaults.standard.string(forKey: "ViewerDetails"), name.contains(".") {
                        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
                        self.showDetails(of: Schema.Table(database: parts[0], name: parts[1], engine: "", rows: nil, bytes: nil, comment: ""),
                                         TableDetail(rawValue: UserDefaults.standard.string(forKey: "ViewerDetail") ?? "") ?? .overview)
                    }
                    if let self, UserDefaults.standard.bool(forKey: "ViewerChart") { self.toggleChart() }
                    if let self, let sql = UserDefaults.standard.string(forKey: "ViewerPlan") {
                        self.editor.text = sql
                        self.showPlan(of: sql)
                    }
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
        saveEditor()
        onClose()
    }

    // MARK: Keyboard

    // The menu bar's commands (`AppDelegate.buildMenu`): they reach this screen through the responder chain.
    @objc func runCommand(_ sender: Any?) { runStatement() }
    @objc func stopCommand(_ sender: Any?) { queries.cancel() }
    @objc func checkCommand(_ sender: Any?) { checker.checkNow(text: editor.text, cursor: editor.selectedRange.location) }
    @objc func findCommand(_ sender: Any?) { navigationItem.searchController?.searchBar.becomeFirstResponder() }
    @objc func explainCommand(_ sender: Any?) {
        guard let sql = currentStatement() else { return }
        showPlan(of: sql)
    }
    @objc func chartCommand(_ sender: Any?) { toggleChart() }

    /// Stop only while a statement runs (dimmed in the menu bar otherwise, not hidden).
    override func validate(_ command: UICommand) {
        super.validate(command)
        if command.action == #selector(stopCommand(_:)) {
            command.attributes = queries.isRunning ? [] : [.disabled]
        }
    }

    // MARK: Running

    private func runStatement() {
        guard let sql = currentStatement() else { return }
        editor.resignFirstResponder()
        run(sql)
    }

    /// Explain Plan: the plan's steps, each read with the granules its indexes leave, in a sheet.
    private func showPlan(of sql: String) {
        statusLabel.text = String(localized: "Explaining…")
        Task {
            do {
                let plan = try await client.plan(of: sql)
                statusLabel.text = PlanItem.summary(of: plan)
                present(UINavigationController(rootViewController: PlanViewController(plan: plan)), animated: true)
            } catch {
                show(error)
            }
        }
    }

    /// Explain Pipeline: its processors and streams drawn, in a sheet.
    private func showPipeline(of sql: String) {
        statusLabel.text = String(localized: "Explaining…")
        Task {
            do {
                let pipeline = try await client.pipeline(of: sql)
                statusLabel.text = String(localized: "The pipeline, not run: \(pipeline.nodes.count) processors")
                let controller = UIViewController()
                controller.title = String(localized: "Pipeline")
                let scroll = UIScrollView()
                let canvas = PipelineCanvas(frame: .zero)
                canvas.backgroundColor = .systemBackground
                canvas.layout = PipelineLayout(pipeline)
                scroll.addSubview(canvas)
                scroll.contentSize = canvas.layout.size
                scroll.backgroundColor = .systemBackground
                controller.view = scroll
                controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak controller] _ in
                    controller?.dismiss(animated: true)
                })
                present(UINavigationController(rootViewController: controller), animated: true)
            } catch {
                show(error)
            }
        }
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
        detailsBar.isHidden = true
        detailsTable = nil
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
        detailsBar.isHidden = true
        messageLabel.isHidden = true
        queries.show(view)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        showSecondary()
    }

    /// A table's details over the result, the detail chosen in the bar's menu.
    func showDetails(of table: Schema.Table, _ detail: TableDetail) {
        detailsTable = table
        var configuration = detailsButton.configuration ?? .gray()
        configuration.title = "\(table.qualifiedName) · \(detail.title)"
        configuration.image = UIImage(systemName: "chevron.up.chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        detailsButton.configuration = configuration
        detailsButton.menu = UIMenu(children: TableDetail.allCases.map { other in
            UIAction(title: other.title, state: other == detail ? .on : .off) { [weak self] _ in self?.showDetails(of: table, other) }
        })
        detailsBar.isHidden = false
        messageLabel.isHidden = true
        queries.run(detail.sql(database: table.database, table: table.name))
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
        table.isHidden = text != nil || isShowingChart
        chart.view.isHidden = text != nil || !isShowingChart
        textOutput.text = text ?? ""
    }

    private func show(_ error: Error) {
        messageLabel.text = error.viewerDescription
        messageLabel.isHidden = false
    }

    // MARK: Chart

    private func toggleChart() {
        isShowingChart.toggle()
        textOutput.isHidden = true
        table.isHidden = isShowingChart
        chart.view.isHidden = !isShowingChart
        chartBar.isHidden = !isShowingChart
        updateChartBar()
    }

    private func updateChart() {
        guard isShowingChart else { return }
        chart.update(source: queries.source, table: table, isRunning: queries.isRunning, timeZone: client.serverInfo?.zone ?? .gmt)
    }

    /// The bar's menus: the column along x, the measures, the kind.
    private func updateChartBar() {
        chartBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func button(_ title: String, _ menu: UIMenu) -> UIButton {
            var configuration = UIButton.Configuration.gray()
            configuration.title = title
            configuration.buttonSize = .small
            configuration.cornerStyle = .capsule
            configuration.image = UIImage(systemName: "chevron.up.chevron.down")
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 4
            let button = UIButton(configuration: configuration)
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
            return button
        }
        let xName = chart.columns.first { $0.index == chart.x }?.name ?? "—"
        let along = UIMenu(children: chart.columns.map { column in
            UIAction(title: column.name, state: column.index == chart.x ? .on : .off) { [weak self] _ in self?.chart.choose(x: column.index) }
        })
        let measures = chart.columns.filter { $0.isNumber && $0.index != chart.x }
        let yNames = chart.ys.compactMap { y in chart.columns.first { $0.index == y }?.name }.joined(separator: ", ")
        let measureMenu = UIMenu(children: measures.map { column in
            UIAction(title: column.name, state: chart.ys.contains(column.index) ? .on : .off) { [weak self] _ in self?.chart.toggle(y: column.index) }
        })
        let kinds: [(ChartModel.Kind, String)] = [(.automatic, String(localized: "Automatic")), (.line, String(localized: "Line")), (.bars, String(localized: "Bars"))]
        let kindMenu = UIMenu(children: kinds.map { kind, title in
            UIAction(title: title, state: chart.kind == kind ? .on : .off) { [weak self] _ in self?.chart.kind = kind }
        })
        chartBar.addArrangedSubview(button(xName, along))
        chartBar.addArrangedSubview(button(yNames.isEmpty ? "—" : yNames, measureMenu))
        chartBar.addArrangedSubview(button(kinds.first { $0.0 == chart.kind }?.1 ?? "", kindMenu))
        chartBar.addArrangedSubview(UIView())
        updateChart()
    }

    private func updateStatus() {
        updateChart()
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
        let plan = UIAction(title: String(localized: "Explain Plan")) { [weak self] _ in
            guard let self, let sql = currentStatement() else { return }
            showPlan(of: sql)
        }
        let pipeline = UIAction(title: String(localized: "Explain Pipeline")) { [weak self] _ in
            guard let self, let sql = currentStatement() else { return }
            showPipeline(of: sql)
        }
        let explains: [(String, String)] = [
            (String(localized: "Explain Plan as Text"), "EXPLAIN PLAN indexes = 1 %@ FORMAT TSVRaw"),
            (String(localized: "Explain Pipeline as Text"), "EXPLAIN PIPELINE %@ FORMAT TSVRaw"),
            (String(localized: "Explain Estimate"), "EXPLAIN ESTIMATE %@"),
            (String(localized: "Explain Syntax"), "EXPLAIN SYNTAX %@ FORMAT TSVRaw"),
        ]
        let explain = UIMenu(title: String(localized: "Explain"), image: UIImage(systemName: "list.bullet.indent"), children: [plan, pipeline] + explains.map { title, form in
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
        let scopes = [nil] + clusters
        let scope = UIMenu(title: String(localized: "Server Views"), image: UIImage(systemName: "server.rack"), children: scopes.map { cluster in
            UIAction(title: cluster.map { String(localized: "Of cluster \($0)") } ?? String(localized: "Of this server"),
                     state: queries.cluster == cluster ? .on : .off) { [weak self] _ in
                guard let self else { return }
                queries.cluster = cluster
                if let view = queries.view { show(view) }
            }
        })
        let chartAction = UIAction(title: isShowingChart ? String(localized: "Show Table") : String(localized: "Show Chart"),
                                   image: UIImage(systemName: isShowingChart ? "tablecells" : "chart.xyaxis.line")) { [weak self] _ in self?.toggleChart() }
        return [chartAction, historyMenu, check, explain, export] + (clusters.isEmpty ? [] : [scope]) + [editorSize]
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
