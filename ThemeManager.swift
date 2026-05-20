import SwiftUI

enum ThemeColor: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case grey      = "Grey"
    case purple    = "Purple"
    case yellow    = "Yellow"
    case red       = "Red"
    case blue      = "Blue"
    case lightBlue = "Light Blue"
    case green     = "Green"
    case orange    = "Orange"

    var id: String { rawValue }

    var color: Color? {
        switch self {
        case .default:   return nil
        case .grey:      return .gray
        case .purple:    return .purple
        case .yellow:    return .yellow
        case .red:       return .red
        case .blue:      return .blue
        case .lightBlue: return .cyan
        case .green:     return .green
        case .orange:    return .orange
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Liquid Glass Helper

struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var isSelected: Bool
    var prominent: Bool
    var tint: Color?
    var isHovered: Bool
    
    @AppStorage("isLiquidGlass") private var isLiquidGlass: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                if prominent {
                    // Prominent buttons handle their own solid background color elsewhere.
                    // We just apply a subtle glossy hover overlay here.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.2 : 0.05))
                        .allowsHitTesting(false)
                } else {
                    if isSelected {
                        // Clean, highly noticeable pill for selected items
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill((tint ?? Color.primary).opacity(0.3))
                    } else if isHovered {
                        // Subtle pill for hovered items
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill((tint ?? Color.primary).opacity(0.18))
                    }
                }
            }
            .overlay {
                if prominent {
                    // Bright, crisp border for primary actions
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                } else {
                    if isSelected {
                        // Clean border to emphasize the selected shape
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke((tint ?? Color.primary).opacity(0.25), lineWidth: 0.5)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke((tint ?? Color.primary).opacity(0.15), lineWidth: 0.5)
                    } else if isLiquidGlass {
                        // Thin line for unselected buttons in liquid glass mode
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    }
                }
            }
            .shadow(color: Color.black.opacity(isSelected ? 0.15 : (prominent ? 0.25 : 0.05)), 
                    radius: isSelected ? 2 : (prominent ? 2 : 1), 
                    x: 0, 
                    y: isSelected ? 1 : (prominent ? 1 : 0))
            .scaleEffect(isHovered && !isSelected && !prominent ? 1.02 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isSelected)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 12, isSelected: Bool = false, prominent: Bool = false, tint: Color? = nil, isHovered: Bool = false) -> some View {
        self.modifier(LiquidGlassModifier(cornerRadius: cornerRadius, isSelected: isSelected, prominent: prominent, tint: tint, isHovered: isHovered))
    }
}
