import AppKit
import Combine
import SwiftUI

@MainActor
final class UsagePopoverController: NSHostingController<UsagePopover> {
    private weak var popover: NSPopover?
    private var observations = Set<AnyCancellable>()

    init(model: UsageModel, notifications: ResetNotificationController,
         onClose: @escaping () -> Void = {}) {
        super.init(rootView: UsagePopover(model: model, notifications: notifications, onClose: onClose))
        // NSPopover follows this size as records and inline warnings appear/disappear.
        sizingOptions = [.preferredContentSize]
        // Schedule after @Published has applied its new value. This also keeps
        // the first opening correct when content changed while the panel was closed.
        Publishers.Merge(model.objectWillChange, notifications.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeToFit() }
            .store(in: &observations)
    }

    override var preferredContentSize: NSSize {
        didSet { synchronizeSize() }
    }

    func attach(to popover: NSPopover) {
        self.popover = popover
        popover.contentViewController = self
        resizeToFit()
    }

    private func resizeToFit() {
        preferredContentSize = sizeThatFits(in: NSSize(
            width: UsagePopover.panelWidth, height: UsagePopover.maximumHeight))
        synchronizeSize()
    }

    private func synchronizeSize() {
        let size = preferredContentSize
        guard let popover, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              abs(popover.contentSize.width - size.width) > 0.5
                || abs(popover.contentSize.height - size.height) > 0.5 else { return }
        popover.contentSize = size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard initialization is not supported")
    }
}
