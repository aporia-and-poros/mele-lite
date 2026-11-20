import SwiftUI
import UIKit

/// 换掉 SwiftUI 的 TextEditor（11-20 内测：表情包描述、设定里打拼音，第一个字母直接被定在原位，后面的字母跑到全文最后）。
/// 拼音还没选字时（markedText），页面一重画，TextEditor 会把整段字重新塞回去：没选的字母被当成定稿，光标跳到末尾。
/// 这里自己管 UITextView：有没选完的字就不碰它；外面真改了内容才写回去，并且尽量留住光标。
struct IMETextEditor: UIViewRepresentable {
    @Binding var text: String
    var size: CGFloat = 17

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.font = .systemFont(ofSize: size)
        v.textColor = .label
        v.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        v.textContainer.lineFragmentPadding = 4
        v.alwaysBounceVertical = false
        v.keyboardDismissMode = .interactive
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        if v.font?.pointSize != size { v.font = .systemFont(ofSize: size) }
        guard v.markedTextRange == nil, v.text != text else { return }
        let sel = v.selectedRange
        v.text = text
        let n = (text as NSString).length
        v.selectedRange = NSRange(location: min(sel.location, n), length: 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: UITextView, context: Context) -> CGSize? {
        // 跟 TextEditor 一样占满给它的宽；没给宽（问理想大小）时也报一个正的宽，不然在 VStack 里会被压成 0 宽、点不进去
        let given = proposal.width ?? 0
        let w = given.isFinite && given > 0 ? given : max(v.bounds.width, 240)
        let fit = v.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        // 高度：给了确定的高就占满（外面 .frame(minHeight:) 摆放时会把定下来的高递进来，整块都能点；字多了在里面滑）；
        // 没给（问理想大小）就报内容的高，外面的 frame 再夹到最小 / 最大之间
        if let ph = proposal.height, ph.isFinite, ph > 0 { return CGSize(width: w, height: ph) }
        return CGSize(width: w, height: max(fit.height, 36))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IMETextEditor
        init(_ p: IMETextEditor) { parent = p }

        func textViewDidChange(_ v: UITextView) {
            guard v.markedTextRange == nil else { return }     // 拼音还在选：等选完再交出去
            if parent.text != v.text { parent.text = v.text }
        }

        func textViewDidEndEditing(_ v: UITextView) {
            if parent.text != v.text { parent.text = v.text }
        }
    }
}
