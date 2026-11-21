import SwiftUI
import UIKit
import ScriberShared

/// UIKit shell: hosts the SwiftUI keyboard, owns the height constraint, forwards text-context
/// callbacks, and opens the containing app.
final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel!
    private var host: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?

    /// Close to the system keyboard (keys + suggestion bar) in each orientation.
    static let portraitHeight: CGFloat = 176
    static let landscapeHeight: CGFloat = 140

    override func viewDidLoad() {
        super.viewDidLoad()
        model = KeyboardModel(controller: self)

        let host = UIHostingController(rootView: KeyboardRootView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        let height = view.heightAnchor.constraint(equalToConstant: currentHeight)
        height.priority = UILayoutPriority(999) // the system's own constraint wins during rotation
        height.isActive = true
        heightConstraint = height

        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in
            self.updateHeight()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateHeight()
        model.refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model.didAppear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.keyboardWillDisappear()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        model.memoryWarning()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.updateHeight() })
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.textContextChanged()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        model.textContextChanged()
    }

    private var isLandscape: Bool {
        traitCollection.verticalSizeClass == .compact
    }

    private var currentHeight: CGFloat {
        isLandscape ? Self.landscapeHeight : Self.portraitHeight
    }

    private func updateHeight() {
        heightConstraint?.constant = currentHeight
        model?.setLandscape(isLandscape)
    }

    // MARK: Opening the containing app

    /// Keyboards cannot call `UIApplication.shared`, but the `UIApplication` instance is on the
    /// responder chain, and `open(_:options:completionHandler:)` is not extension-unavailable.
    /// This is the pattern Apple DTS posted for "keyboard opens its container app" (forums
    /// thread 812091) and what works on iOS 18+, where the old `perform(openURL:)` selector
    /// trick returns false. Requires Full Access on iOS 26+. `extensionContext.open` is the
    /// fallback (historically ignored for keyboards, kept in case a future iOS honours it).
    func openContainingApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:]) { [weak self] opened in
                    if opened {
                        completion(true)
                    } else if let context = self?.extensionContext {
                        context.open(url) { ok in DispatchQueue.main.async { completion(ok) } }
                    } else {
                        completion(false)
                    }
                }
                return
            }
            responder = current.next
        }
        if let context = extensionContext {
            context.open(url) { ok in DispatchQueue.main.async { completion(ok) } }
        } else {
            completion(false)
        }
    }
}
