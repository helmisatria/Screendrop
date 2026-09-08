import AppKit
import SwiftUI

struct RecordingCaptionTextEditor: NSViewRepresentable {
    let model: RecordingStudioModel
    let cue: RecordingSubtitleCue

    func makeNSView(context: Context) -> CaptionTextView {
        let view = CaptionTextView()
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 11, weight: .medium)
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.allowsUndo = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.setAccessibilityLabel("Caption text")
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: CaptionTextView, context: Context) {
        context.coordinator.parent = self
        view.model = model
        view.cueID = cue.id
        if view.string != cue.text {
            let selection = view.selectedRange()
            view.string = cue.text
            view.setSelectedRange(NSRange(location: min(selection.location, (cue.text as NSString).length), length: 0))
            view.invalidateIntrinsicContentSize()
        }
        if let focus = model.captionEditorFocus, focus.id == cue.id,
           context.coordinator.appliedFocus != focus.token {
            context.coordinator.appliedFocus = focus.token
            DispatchQueue.main.async { [weak view] in
                guard let view, model.captionEditorFocus?.token == focus.token else { return }
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: min(focus.offset, (view.string as NSString).length), length: 0))
                view.scrollRangeToVisible(view.selectedRange())
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CaptionTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 200)
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let container = nsView.textContainer, let layout = nsView.layoutManager {
            layout.ensureLayout(for: container)
            return CGSize(width: width, height: max(14, ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY))))
        }
        return nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RecordingCaptionTextEditor
        var appliedFocus: UUID?
        init(_ parent: RecordingCaptionTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.model.updateSubtitleText(id: parent.cue.id, text: view.string)
            view.invalidateIntrinsicContentSize()
        }
        func textDidBeginEditing(_ notification: Notification) {
            parent.model.seekToSubtitle(parent.cue)
        }
    }
}

final class CaptionTextView: NSTextView {
    weak var model: RecordingStudioModel?
    var cueID: UUID?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let cueID, let cue = model?.subtitleCues.first(where: { $0.id == cueID }) {
            model?.seekToSubtitle(cue)
        }
        return accepted
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
        } else if let cueID {
            model?.splitSubtitle(id: cueID, selection: selectedRange())
        }
    }

    override func insertLineBreak(_ sender: Any?) { super.insertNewline(sender) }

    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), selectedRange() == NSRange(location: 0, length: 0), let cueID {
            model?.mergeSubtitleWithPrevious(id: cueID)
        } else {
            super.deleteBackward(sender)
        }
    }

    @objc func undo(_ sender: Any?) { model?.undo() }
    @objc func redo(_ sender: Any?) { model?.redo() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "z", modifiers.contains(.command),
           !modifiers.contains(.option), !modifiers.contains(.control) {
            if modifiers.contains(.shift) { model?.redo() } else { model?.undo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
