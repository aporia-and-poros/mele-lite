"""重复（10-13 内测：一上午每句都是「汤」、后来每句都是「等天黑去河边」）。跟 MeleLiteCore/Repeats.swift 同一份意思。

真因在账本的腔调样本：卷上下文时原来直接取被卷掉的最后 6 句原话，每轮放进 system 写着「照这个接着说」，
DeepSeek 不是学腔调，是把那几句抄回来；而最后 6 句恰恰是重复得最凶的那几句。
① 挑样本时去掉长得像的、从头到尾散着挑；② 回话里跟它最近说过的几乎一样的气泡，丢掉。"""
from __future__ import annotations

import re

_TOKEN = re.compile(r"[A-Za-z0-9]+|[^\W_]")


def tokens(text: str) -> set[str]:
    """中文一个字一个词、英文一个单词一个词，去掉标点"""
    return {t.lower() for t in _TOKEN.findall(text or "")}


def similarity(a: str, b: str) -> float:
    """重叠占短的那句的比例（换了说法的同一句也抓得到）"""
    x, y = tokens(a), tokens(b)
    if not x or not y:
        return 1.0 if a == b else 0.0
    return len(x & y) / min(len(x), len(y))


def pick_samples(lines: list[str], limit: int = 6, min_chars: int = 8) -> list[str]:
    """腔调样本：太短的不要，长得像的（≥ 0.6）只留一句，从头到尾散着取而不是只取最后几句"""
    distinct: list[str] = []
    for line in (x.strip() for x in lines):
        if len(line) >= min_chars and not any(similarity(d, line) >= 0.6 for d in distinct):
            distinct.append(line)
    if len(distinct) <= limit or limit <= 0:
        return distinct
    n = len(distinct)
    return [distinct[round(i * (n - 1) / (limit - 1))] for i in range(limit)]


def drop_repeated(bubbles: list[str], recent: list[str], threshold: float = 0.75) -> list[str]:
    """回话里跟它最近说过的几乎一样（≥ threshold）的气泡丢掉；全丢光了留第一句。语音条不丢（11-09：短语音跟不相干的长话也算像，被悄悄吞掉）"""
    kept = [b for b in bubbles if b.lstrip().startswith("🎤") or not any(similarity(r, b) >= threshold for r in recent)]
    return kept or bubbles[:1]
