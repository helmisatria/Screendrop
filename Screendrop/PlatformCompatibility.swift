import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func compatibleGlassEffect(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                glassEffect(.regular.interactive())
            } else {
                glassEffect()
            }
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func compatibleGlassEffect<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                glassEffect(.regular.interactive(), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func compatibleDraggable<Preview: View>(
        _ url: URL,
        onBegan: @escaping () -> Void,
        onEnded: @escaping () -> Void,
        @ViewBuilder preview: @escaping () -> Preview
    ) -> some View {
        if #available(macOS 26.0, *) {
            draggable(url, preview: preview)
                .onDragSessionUpdated { session in
                    switch session.phase {
                    case .active:
                        onBegan()
                    case .ended:
                        onEnded()
                    default:
                        break
                    }
                }
        } else {
            modifier(
                LegacyFileDragModifier(
                    url: url,
                    onBegan: onBegan,
                    onEnded: onEnded,
                    preview: preview
                )
            )
        }
    }
}

private struct LegacyFileDragModifier<Preview: View>: ViewModifier {
    let url: URL
    let onBegan: () -> Void
    let onEnded: () -> Void
    let preview: () -> Preview

    @State private var isDragging = false
    @State private var completionTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onDrag {
                beginDrag()
                return NSItemProvider(object: url as NSURL)
            } preview: {
                preview()
            }
            .onDisappear {
                completionTask?.cancel()
                completionTask = nil
                isDragging = false
            }
    }

    private func beginDrag() {
        guard !isDragging else { return }

        isDragging = true
        onBegan()

        completionTask?.cancel()
        completionTask = Task { @MainActor in
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
            }

            finishDrag()
        }
    }

    private func finishDrag() {
        guard isDragging else { return }

        completionTask = nil
        isDragging = false
        onEnded()
    }
}
