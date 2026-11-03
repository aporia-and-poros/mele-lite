"""正文里的小标记（10-31）：「说了就算、不用看结果」的动作不走工具，它在回复里写一个标记，这边解出来照办。
省掉的是工具说明（每轮都带）和一来一回（每回都把整段上下文再送一遍）。Lite 的同一套在 mele-lite Chat/Markers.swift。

- 发表情包：`[表情包：#12]`（编号照「你的表情包」那张表）/ 旧写法 `[表情包：描述]` / `[sticker: #12]`
- 立里程碑：`⟪里程碑：标题⟫` / `⟪milestone: …⟫`

可以夹在句子中间，拿掉以后正文不留痕；括号写歪了（【】［］《》〈〉）也认；写坏了的（没闭合、少了冒号）
解不出来也一律剥掉——标记绝不能漏进气泡、通知、电话里念的话。"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

_OPEN = r"[\[【［⟪《〈<]"
_CLOSE = r"[\]】］⟫》〉>]"
_BODY = r"\s*[:：]\s*([^\]】］⟫》〉>\n]+?)\s*"
STICKER = re.compile(_OPEN + r"\s*(?:表情包|表情|sticker)" + _BODY + _CLOSE, re.I)
MILESTONE = re.compile(_OPEN + r"\s*(?:里程碑|milestone)" + _BODY + _CLOSE, re.I)
# 兜底：写坏了的。没闭合的吃到行尾（后面那截多半也是标记里的字）；闭合了但没冒号的整个拿掉
BROKEN = re.compile(_OPEN + r"\s*(?:表情包|sticker|里程碑|milestone|想查手机|peek)(?:[^\]】］⟫》〉>\n]*" + _CLOSE + r"|[^\n]*)", re.I)
_HOLE = "\x01"                 # 拿掉一个标记先占个位，最后按左右的空白收拾
_FILL = re.compile(r"([ \t　]*)\x01+([ \t　]*)")


@dataclass
class Parsed:
    text: str
    stickers: list[str] = field(default_factory=list)
    milestones: list[str] = field(default_factory=list)


def _pull(rx: re.Pattern, text: str) -> tuple[list[str], str]:
    found = [m.group(1) for m in rx.finditer(text) if m.lastindex]
    return found, rx.sub(_HOLE, text)


def _fill(text: str) -> str:
    """占位那里：左右都有空白 → 留一个空格；否则什么都不留。"""
    return _FILL.sub(lambda m: " " if m.group(1) and m.group(2) else "", text)


def _tidy(text: str) -> str:
    """每行去掉首尾空格，连着的空段并成一个空行，首尾空白去掉。"""
    paras = ["\n".join(l.strip() for l in p.split("\n") if l.strip()) for p in re.split(r"\n\s*\n", text)]
    return "\n\n".join(p for p in paras if p)


def parse(text: str) -> Parsed:
    if not text or not BROKEN.search(text):
        return Parsed(text)
    stickers, t = _pull(STICKER, text)
    milestones, t = _pull(MILESTONE, t)
    _, t = _pull(BROKEN, t)
    return Parsed(_tidy(_fill(t)), [s.strip() for s in stickers], [" ".join(m.split()) for m in milestones])


def scrub(text: str) -> str:
    """只剥不解：推送、念出来的话这些出口用，保证一个标记都不漏。"""
    return parse(text).text if text else text
