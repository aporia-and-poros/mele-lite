import Foundation

/// 一通电话里的一轮，递给大脑的把手：切好的句子交给通话页；对面开口打断 / 挂了就停；存档只存真念出来的。
///
/// 两头各在各的线程上：大脑一边写一边切句子、写完存档；通话页随时可能说「打断了，只念到这几句」。
/// 存档和打断谁先谁后都得对得上——所以「拿去存的那一份」和「存好了」分两步，中间来的打断由存的那头补改。
public final class CallLink: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = CallSpeech.Splitter()
    private var _cut = false
    private var _spoken: [String]?
    private var _lines: [String] = []
    private var _userMessageID: Int?
    private var _assistantMessageID: Int?
    private var cutWhenTaken = false
    /// 切好一句（已洗过）：通话页拿去合成、排进时间线
    public let onLine: @Sendable (String) -> Void
    /// 这一轮没成（没 key、模型报错、什么都没说）：通话页显示一句
    public let onFail: @Sendable (String) -> Void
    /// 这一通电话的编号：同一通的几条消息都带着，点开「通话时长」那行按它取
    public let callID: String
    /// 这一轮自己的编号：打断、改字都指名是哪一轮（连着服务器时两个请求谁先到不一定，不指名会落到下一轮头上）
    public let turnID: String

    public init(callID: String, turnID: String = UUID().uuidString.lowercased(),
                onLine: @escaping @Sendable (String) -> Void, onFail: @escaping @Sendable (String) -> Void) {
        self.callID = callID
        self.turnID = turnID
        self.onLine = onLine
        self.onFail = onFail
    }

    public var isCut: Bool { lock.withLock { _cut } }
    /// 它这一轮切出来的全部句子
    public var lines: [String] { lock.withLock { _lines } }
    /// 被打断时通话页告诉的「念到了哪几句」；没打断是 nil
    public var spokenLines: [String]? { lock.withLock { _spoken } }
    public var userMessageID: Int? {
        get { lock.withLock { _userMessageID } }
        set { lock.withLock { _userMessageID = newValue } }
    }
    /// 它这一轮存下的那条（写完才有）
    public var assistantMessageID: Int? { lock.withLock { _assistantMessageID } }

    public func feed(_ chunk: String) { emit(lock.withLock { splitter.feed(chunk) }) }
    /// 已经切好的一句（服务器那边切好推来的）
    public func deliver(_ line: String) { if !line.isEmpty { emit([line]) } }
    public func flush() { emit(lock.withLock { splitter.finish() }) }

    /// 停：spoken = 已经念出来（或正念着）的那几句。
    /// 返回它这一轮已经存下的那条的编号（还没存 = nil）：有编号的话调用方去把存档改成念到的；没有的话存的那头自己会照 spoken 存。
    @discardableResult
    public func cut(spoken: [String]) -> Int? {
        lock.withLock {
            _cut = true
            _spoken = spoken
            return _assistantMessageID
        }
    }

    /// 要存档了：拿走这一轮该存的句子（被打断的只有念到的那几句）
    public func takeForSaving() -> (lines: [String], cut: Bool) {
        lock.withLock {
            cutWhenTaken = _cut
            return (_spoken ?? _lines, _cut)
        }
    }

    /// 存好了，记下是哪一条。正存着的那一会儿对面开口了（打断来时这条还没有编号，那头改不了）→ 返回念到的那几句，
    /// 调用方把刚存的整段改回来；没有这回事返回 nil。
    public func saved(as id: Int) -> [String]? {
        lock.withLock {
            _assistantMessageID = id
            return _cut && !cutWhenTaken ? _spoken : nil
        }
    }

    public func fail(_ message: String) { onFail(message) }

    private func emit(_ out: [String]) {
        guard !out.isEmpty else { return }
        let go = lock.withLock { () -> [String] in
            guard !_cut else { return [] }
            _lines += out
            return out
        }
        for l in go { onLine(l) }
    }
}
