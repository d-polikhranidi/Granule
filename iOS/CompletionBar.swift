import UIKit

/// The bar above the keyboard: completions of the word being typed (tap one
/// to put it in), and Run.
final class CompletionBar: UIInputView {
    var onChoose: (String) -> Void = { _ in }
    var onRun: () -> Void = {}
    private let stack = UIStackView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        var run = UIButton.Configuration.filled()
        run.image = UIImage(systemName: "play.fill")
        run.cornerStyle = .capsule
        let runButton = UIButton(configuration: run, primaryAction: UIAction { [weak self] _ in self?.onRun() })
        runButton.translatesAutoresizingMaskIntoConstraints = false
        runButton.accessibilityLabel = String(localized: "Run")
        addSubview(scroll)
        addSubview(runButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
            runButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            runButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The completions shown (the first ones, the best).
    func show(_ words: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for word in words.prefix(20) {
            var configuration = UIButton.Configuration.gray()
            configuration.title = word
            configuration.cornerStyle = .capsule
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes.font = SQLHighlighting.font
                return attributes
            }
            stack.addArrangedSubview(UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onChoose(word) }))
        }
    }
}
