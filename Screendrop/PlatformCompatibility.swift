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
    func compatibleDragSessionUpdated(
        onBegan: @escaping () -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        if #available(macOS 26.0, *) {
            onDragSessionUpdated { session in
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
                LegacyDragSessionModifier(
                    onBegan: onBegan,
                    onEnded: onEnded
                )
            )
        }
    }
}

private struct LegacyDragSessionModifier: ViewModifier {
    let onBegan: () -> Void
    let onEnded: () -> Void

    @State private var isDragging = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    guard !isDragging else { return }
                    isDragging = true
                    onBegan()
                }
                .onEnded { _ in
                    guard isDragging else { return }
                    isDragging = false
                    onEnded()
                }
        )
    }
}
