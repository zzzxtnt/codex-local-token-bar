import AppKit
import Combine
import SwiftUI

@MainActor
final class UsagePopoverController: NSHostingController<UsagePopover> {
    private weak var popover: NSPopover?
    private var observations = Set<AnyCancellable>()

    init(model: UsageModel, notifications: ResetNotificationController,
         updater: UpdateController = UpdateController(),
         onClose: @escaping () -> Void = {}) {
        super.init(rootView: UsagePopover(model: model, notifications: notifications, updater: updater, onClose: onClose))
        // Measure the actual unscrolled content; ViewThatFits' proposed size can
        // include spare height on newer SDKs. Keep one sizing owner, not two.
        sizingOptions = []
        // Schedule after @Published has applied its new value. This also keeps
        // the first opening correct when content changed while the panel was closed.
        Publishers.Merge3(model.objectWillChange, notifications.objectWillChange, updater.objectWillChange)
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
        let content = NSHostingView(rootView: rootView.content.frame(width: UsagePopover.panelWidth))
        preferredContentSize = NSSize(width: UsagePopover.panelWidth,
            height: min(content.fittingSize.height, UsagePopover.maximumHeight))
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
