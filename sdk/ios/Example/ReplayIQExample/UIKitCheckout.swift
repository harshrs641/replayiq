import ReplayIQ
import SwiftUI
import UIKit

/// A UIKit checkout screen: tracked automatically as `navigate`
/// ("UIKitCheckoutViewController"), fields masked by default.
struct UIKitCheckout: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: UIKitCheckoutViewController())
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

final class UIKitCheckoutViewController: UIViewController {
    private let email = UITextField()
    private let password = UITextField()
    private let address = UITextView()
    private let promo = UILabel()

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit Checkout"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        email.placeholder = "Email"
        email.borderStyle = .roundedRect
        email.keyboardType = .emailAddress
        password.placeholder = "Password"
        password.borderStyle = .roundedRect
        password.isSecureTextEntry = true
        address.text = "1 Infinite Loop\nCupertino"
        address.font = .preferredFont(forTextStyle: .body)
        address.layer.borderColor = UIColor.separator.cgColor
        address.layer.borderWidth = 1
        address.layer.cornerRadius = 6
        address.heightAnchor.constraint(equalToConstant: 80).isActive = true

        // A view the app marks sensitive.
        promo.text = "Member #88-1234-5678 · Gold tier"
        promo.textAlignment = .center
        promo.backgroundColor = .systemYellow.withAlphaComponent(0.3)
        promo.heightAnchor.constraint(equalToConstant: 44).isActive = true
        promo.replayIQMasked = true

        let place = UIButton(configuration: .filled(), primaryAction: UIAction(title: "Place order") { [weak self] _ in
            ReplayIQ.track("uikit_order_placed", properties: nil)
            ReplayIQ.log("UIKit order placed")
            self?.view.endEditing(true)
            self?.dismiss(animated: true)
        })
        let info = UILabel()
        info.text = "Fields above are masked in the replay."
        info.font = .preferredFont(forTextStyle: .footnote)
        info.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [email, password, address, promo, place, info])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
}
