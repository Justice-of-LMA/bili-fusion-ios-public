import UIKit

/// Native fallback: remains usable even when WebKit or local page scripts cannot start.
@MainActor final class StartupOverlay: UIView {
    private let title = UILabel(), detail = UILabel(), version = UILabel()
    let retry = UIButton(type: .system)
    var onRetry: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.043, green: 0.071, blue: 0.125, alpha: 1)
        accessibilityIdentifier = "startup-overlay"
        title.text = "二路随行"; title.textColor = .white; title.font = .boldSystemFont(ofSize: 26)
        detail.textColor = UIColor(white: 0.82, alpha: 1); detail.font = .systemFont(ofSize: 16)
        detail.numberOfLines = 0; detail.accessibilityIdentifier = "startup-detail"
        let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        version.text = "v\(number) · iPadOS / iOS \(UIDevice.current.systemVersion)"
        version.textColor = .lightGray; version.font = .systemFont(ofSize: 12)
        [title, detail, version].forEach { $0.textAlignment = .center }
        retry.setTitle("重新加载首页", for: .normal)
        retry.titleLabel?.font = .boldSystemFont(ofSize: 17)
        retry.accessibilityIdentifier = "startup-retry"
        retry.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, detail, retry, version])
        stack.axis = .vertical; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        show("正在打开首页…", canRetry: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ text: String, canRetry: Bool) {
        detail.text = text; retry.isHidden = !canRetry; isHidden = false
    }
    @objc private func tapped() { onRetry?() }
}
