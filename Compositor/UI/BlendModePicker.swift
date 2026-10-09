import SwiftUI
import AppKit

struct BlendModePicker: NSViewRepresentable {
    let session: EditorSession
    @Environment(\.locale) private var locale
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        // Grouped as Photoshop groups them — darkening, lightening, contrast, comparative, component —
        // with a line between, so a long list stays readable.
        for (index, group) in LayerBlendMode.groups.enumerated() {
            if index > 0 { button.menu?.addItem(.separator()) }
            for mode in group {
                button.addItem(withTitle: localizedBlendMode(mode.rawValue, locale: context.environment.locale))
                button.lastItem?.representedObject = mode.rawValue
            }
        }
        button.menu?.delegate = context.coordinator
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setAccessibilityLabel(localizedBlendMode("Blend mode", locale: context.environment.locale))
        // A capsule like the SwiftUI buttons and menus (`roundedControls`), which don't reach this AppKit pop-up.
        button.borderShape = .capsule
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = session.canEditAppearance
        for item in button.itemArray {
            guard let rawValue = item.representedObject as? String else { continue }
            item.title = localizedBlendMode(rawValue, locale: context.environment.locale)
        }
        button.setAccessibilityLabel(localizedBlendMode("Blend mode", locale: context.environment.locale))
        if !context.coordinator.tracking {
            let selected = (session.activeLayer?.blendMode ?? .normal).rawValue
            if let index = button.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) {
                button.selectItem(at: index)
            }
        }
    }
    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        if coordinator.tracking { coordinator.session.previewBlendMode(nil, for: nil) }
        button.menu?.delegate = nil
    }
    final class Coordinator: NSObject, NSMenuDelegate {
        let session: EditorSession
        var tracking = false
        private var layerID: UUID?
        private var highlightedMode: LayerBlendMode?
        init(session: EditorSession) { self.session = session }
        func menuWillOpen(_ menu: NSMenu) {
            tracking = true
            layerID = session.activeLayerID
            highlightedMode = nil
        }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            // AppKit briefly reports no highlighted item while dismissing the menu.
            // Keep the last preview alive until the selection action has committed so
            // the canvas never flashes back to the layer's previous mode.
            guard let rawValue = item?.representedObject as? String,
                  let mode = LayerBlendMode(rawValue: rawValue) else { return }
            highlightedMode = mode
            session.previewBlendMode(mode, for: layerID)
        }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            // A chosen item's action runs as the menu finishes closing. Clearing on the
            // next turn lets that action replace the preview with the committed mode;
            // when the menu was cancelled, this simply restores the original mode.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.tracking else { return }
                self.session.previewBlendMode(nil, for: nil)
            }
        }
        @objc func choose(_ button: NSPopUpButton) {
            guard session.activeLayerID == layerID,
                  let mode = highlightedMode ?? button.selectedItem.flatMap({
                      ($0.representedObject as? String).flatMap(LayerBlendMode.init(rawValue:))
                  }) else { return }
            session.setLayerBlendMode(mode)
            if let index = button.itemArray.firstIndex(where: { ($0.representedObject as? String) == mode.rawValue }) {
                button.selectItem(at: index)
            }
            highlightedMode = nil
            session.refreshCanvasPreview?()
        }
    }
}

private func localizedBlendMode(_ key: String, locale: Locale) -> String {
    let language = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
    guard UserDefaults.standard.string(forKey: "interface.language") != "system" else {
        return InterfaceLocalization.string(key)
    }
    return language == "zh-Hans" ? InterfaceLocalization.string(key) : key
}
