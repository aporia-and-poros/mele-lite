"""分条发：模型写完整段以后，服务器再切成几条气泡（设计文档第五段，Aporia选的「写完再均匀切」）。

1. 按空行分段——它自己的排版一字不动。
2. 超过 250 字的段，在句号处再切成 120 字左右的小条（照之前自用的 App；长文模式下不细切）。
3. 只有标签、没有话的一条，并回上一条（之前自用的 App 08-14 教训）。
4. 条数超过「最多几条」时，按顺序合成那么多份：让最长的那份尽量短（各份字数接近），
   只在条和条之间合，不切半句话。「最多几条」管的是个数，不管字数——一个字都不丢。
5. 🎤 开头的段落是语音条（10-03）：原样自己一条，不细切、不跟别的合；只有文字的几段在剩下的条数里分。
"""
from __future__ import annotations

import re

LONG_PARA = 250
_LIST_LINE = re.compile(r"(?m)^\s*(?:[-*•]|\d+[.、]) ")
PIECE = 120
_ENDS = "。！？!?…～~"
_CLOSERS = "」』”’）)】"
_TAG_ONLY = re.compile(r"^\s*<(\w+)[^>]*>[^<]*</\1>\s*$")
_ASCII_TAIL = re.compile(r"[A-Za-z0-9,.;:!?'\"]$")


def sentences(p: str) -> list[str]:
    """按句末标点切句。连着的标点（？！）和跟在后面的引号括号（。」）算在同一句里。"""
    out: list[str] = []
    buf = ""
    for i, ch in enumerate(p):
        buf += ch
        nxt = p[i + 1] if i + 1 < len(p) else ""
        if nxt and (nxt in _ENDS or nxt in _CLOSERS):
            continue
        if ch in _ENDS or (ch in _CLOSERS and len(buf) >= 2 and buf[-2] in _ENDS):
            out.append(buf)
            buf = ""
        elif ch == "." and (nxt == "" or nxt.isspace()):
            out.append(buf)
            buf = ""
    if buf:
        out.append(buf)
    return [s.strip() for s in out if s.strip()]


def _join(a: str, b: str) -> str:
    return a + (" " if a and _ASCII_TAIL.search(a) else "") + b


def split_long(p: str) -> list[str]:
    """把一个长段按句子装成 PIECE 字左右的小条；单句本身超长的就让它自己一条（不切半句）。"""
    out: list[str] = []
    cur = ""
    for s in sentences(p):
        if cur and len(cur) + len(s) > PIECE:
            out.append(cur)
            cur = s
        else:
            cur = _join(cur, s)
    if cur:
        out.append(cur)
    return out


def balance(chunks: list[str], cap: int | None) -> list[str]:
    """按顺序把 chunks 合成 cap 份，让最长的那份尽量短。条数本来就不超的原样返回。"""
    if cap is None or len(chunks) <= cap:
        return list(chunks)
    n = len(chunks)
    pre = [0]
    for c in chunks:
        pre.append(pre[-1] + len(c))
    inf = float("inf")
    # best[k][i]：前 i 条合成 k 份时，最长一份的最小可能长度；cut[k][i]：最后一份从第几条开始
    best = [[inf] * (n + 1) for _ in range(cap + 1)]
    cut = [[0] * (n + 1) for _ in range(cap + 1)]
    best[0][0] = 0
    for k in range(1, cap + 1):
        for i in range(k, n + 1):
            for j in range(k - 1, i):
                v = max(best[k - 1][j], pre[i] - pre[j])
                if v < best[k][i]:
                    best[k][i], cut[k][i] = v, j
    groups: list[list[str]] = []
    i = n
    for k in range(cap, 0, -1):
        j = cut[k][i]
        groups.append(chunks[j:i])
        i = j
    return ["\n\n".join(g) for g in reversed(groups)]


VOICE = "🎤"


_SENT_END = "。！？!?…—～~：:."
_AUDIO_TAG = r"\[[^\[\]\n:：]{1,60}\]"     # 带冒号的是 [表情包：…] 这类标记，不是语气标签
_TAG_THEN_MARK = re.compile(f"(?:^|(?<=[{_SENT_END}]))[ \\t]*((?:{_AUDIO_TAG}[ \\t]*)*{_AUDIO_TAG})[ \\t]*{VOICE}[ \\t]*", re.M)
_BEFORE_MARK = re.compile(f"(?<=[{_SENT_END}])[ \\t]*{VOICE}|(?<=[^\\n])\\n[ \\t]*{VOICE}")


def tidy_voice(text: str) -> str:
    """🎤 写歪了也认（11-09 内测：前面多一句话或一个语气标签，整段就成了普通文字，还没提示）：
    [标签] 🎤 → 🎤 [标签]；跟在句末 / 换行后面的 🎤 另起一段。句子中间提到 🎤、代码块里的不动。"""
    if VOICE not in text or "```" in text:
        return text
    return _BEFORE_MARK.sub(f"\n\n{VOICE}", _TAG_THEN_MARK.sub(f"{VOICE} \\1 ", text))


def split_reply(text: str, cap: int | None = 6, long_mode: bool = False) -> list[str]:
    paras: list[str] = []
    for p in re.split(r"(\n\s*\n)", text or ""):
        if paras and paras[-1].count("```") % 2 == 1:   # 代码块里的空行不算分段（11-07）
            paras[-1] += p
        elif p.strip():
            paras.append(p)
    paras = [p.strip() for p in paras]
    chunks: list[str] = []
    for p in paras:
        keep = long_mode or len(p) <= LONG_PARA or p.startswith(VOICE) or "```" in p or _LIST_LINE.search(p)
        chunks.extend([p] if keep else split_long(p))   # 代码、列表切开就乱了（11-07）
    merged: list[str] = []
    for c in chunks:
        if merged and _TAG_ONLY.match(c) and not merged[-1].startswith(VOICE):
            merged[-1] = f"{merged[-1]} {c.strip()}"
        else:
            merged.append(c)
    if not any(c.startswith(VOICE) for c in merged):
        return balance(merged, cap)
    # 有语音条：语音条各占一条，文字按连着的几段分组，在剩下的条数里各自合
    runs: list[list[str] | str] = []
    for c in merged:
        if c.startswith(VOICE):
            runs.append(c)
        elif runs and isinstance(runs[-1], list):
            runs[-1].append(c)
        else:
            runs.append([c])
    text_runs = [r for r in runs if isinstance(r, list)]
    if cap is None:
        budget = {id(r): None for r in text_runs}
    else:
        room = max(cap - (len(runs) - len(text_runs)), len(text_runs))
        total = sum(len(r) for r in text_runs) or 1
        budget = {id(r): max(1, room * len(r) // total) for r in text_runs}
    out: list[str] = []
    for r in runs:
        out.extend([r] if isinstance(r, str) else balance(r, budget[id(r)]))
    return out


def typing_delay(text: str, base: float = 0.4, per_char: float = 0.03, cap: float = 2.5) -> float:
    """下一条推出去之前「正在输入」停多久：按字数算，有上限，不让人干等。"""
    return min(cap, base + per_char * len(text))
