#if os(macOS)
import AppKit

final class ActionButton: NSButton {
    var actionBlock: (() -> Void)?
    init(_ title: String, key: String = "", action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; self.keyEquivalent = key; self.actionBlock = action
        bezelStyle = .rounded; target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?() }
}
final class ActionSlider: NSSlider {
    var actionBlock: ((Double) -> Void)?
    init(value: Double, min: Double, max: Double, action: @escaping (Double) -> Void) {
        super.init(frame: .zero)
        minValue = min; maxValue = max; doubleValue = value; actionBlock = action
        target = self; self.action = #selector(invoke); isContinuous = false
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?(doubleValue) }
}
final class ActionField: NSTextField {
    var actionBlock: ((String) -> Void)?
    init(_ value: String, action: @escaping (String) -> Void) {
        super.init(frame: .zero); stringValue = value; actionBlock = action
        target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?(stringValue) }
}
final class ActionPopUp: NSPopUpButton {
    var actionBlock: ((Int) -> Void)?
    init(items: [String], selected: Int = 0, action: @escaping (Int) -> Void) {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items); selectItem(at: selected); actionBlock = action
        target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?(indexOfSelectedItem) }
}
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
func label(_ text: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
    let result = NSTextField(labelWithString: text)
    result.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    result.textColor = .labelColor; return result
}
func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = vertical ? .vertical : .horizontal
    s.spacing = spacing; s.alignment = vertical ? .leading : .centerY
    s.translatesAutoresizingMaskIntoConstraints = false; return s
}
func fill(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
}
func scroll(_ view: NSView, height: CGFloat? = nil) -> NSScrollView {
    let s = NSScrollView(); s.hasVerticalScroller = true; s.drawsBackground = false
    s.documentView = view
    if let height { s.heightAnchor.constraint(equalToConstant: height).isActive = true }
    return s
}
#endif
