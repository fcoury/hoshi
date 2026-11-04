import UIKit

/// The four-arrow pad shown under the finger during a long-press arrow drag.
///
/// Each arrow fills from the center outward as the drag approaches the send
/// threshold, then turns solid while keys are being sent.
final class ArrowPadOverlayView: UIView {
    static let size: CGFloat = 156
    private static let tileSize: CGFloat = 42
    private static let tileInset: CGFloat = 6

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let centerDot = UIView()
    private var tiles: [TerminalArrowDirection: ArrowTile] = [:]

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        alpha = 0

        background.frame = bounds
        background.layer.cornerRadius = Self.size / 2
        background.clipsToBounds = true
        addSubview(background)

        centerDot.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        centerDot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        centerDot.layer.cornerRadius = 5
        centerDot.backgroundColor = .secondaryLabel
        addSubview(centerDot)

        for direction in TerminalArrowDirection.allCases {
            let tile = ArrowTile(direction: direction)
            tile.frame = tileFrame(for: direction)
            addSubview(tile)
            tiles[direction] = tile
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        tiles.values.forEach { $0.tintColorDidChange() }
    }

    func show(at point: CGPoint, in container: CGRect) {
        let half = Self.size / 2
        center = CGPoint(
            x: min(max(point.x, container.minX + half), container.maxX - half),
            y: min(max(point.y, container.minY + half), container.maxY - half)
        )
        render(.idle)
        animate { self.alpha = 1; self.transform = .identity }
    }

    func hide() {
        animate { self.alpha = 0 }
    }

    func render(_ state: TerminalArrowJoystick.State) {
        for (direction, tile) in tiles {
            let isActive = state.direction == direction
            tile.update(fill: isActive ? state.fill : 0, engaged: isActive && state.gear > 0)
        }
    }

    private func animate(_ changes: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            changes()
        } else {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState], animations: changes)
        }
    }

    private func tileFrame(for direction: TerminalArrowDirection) -> CGRect {
        let tile = Self.tileSize
        let inset = Self.tileInset
        let mid = (Self.size - tile) / 2
        let origin: CGPoint = switch direction {
        case .up: CGPoint(x: mid, y: inset)
        case .down: CGPoint(x: mid, y: Self.size - tile - inset)
        case .left: CGPoint(x: inset, y: mid)
        case .right: CGPoint(x: Self.size - tile - inset, y: mid)
        }
        return CGRect(origin: origin, size: CGSize(width: tile, height: tile))
    }
}

private final class ArrowTile: UIView {
    private let direction: TerminalArrowDirection
    private let fillLayer = CALayer()
    private let chevron = UIImageView()
    private var fill: CGFloat = 0
    private var engaged = false

    init(direction: TerminalArrowDirection) {
        self.direction = direction
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.masksToBounds = true
        backgroundColor = UIColor.tertiarySystemFill
        layer.addSublayer(fillLayer)

        let name = switch direction {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
        chevron.image = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
        )
        chevron.contentMode = .center
        addSubview(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        chevron.frame = bounds
        layoutFill()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    func update(fill: CGFloat, engaged: Bool) {
        guard fill != self.fill || engaged != self.engaged else { return }
        self.fill = fill
        self.engaged = engaged
        layoutFill()
        applyColors()
    }

    /// Grows the fill from the pad's center side toward the arrow's outer edge.
    private func layoutFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width
        let h = bounds.height
        fillLayer.frame = switch direction {
        case .up: CGRect(x: 0, y: h * (1 - fill), width: w, height: h * fill)
        case .down: CGRect(x: 0, y: 0, width: w, height: h * fill)
        case .left: CGRect(x: w * (1 - fill), y: 0, width: w * fill, height: h)
        case .right: CGRect(x: 0, y: 0, width: w * fill, height: h)
        }
        CATransaction.commit()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = tintColor.withAlphaComponent(engaged ? 1 : 0.45).cgColor
        CATransaction.commit()
        chevron.tintColor = engaged || fill > 0.6 ? .white : .label
    }
}
