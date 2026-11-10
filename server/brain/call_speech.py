"""打电话（10-31，Host；跟 Lite 零件包 CallSpeech.swift 同一套）：TA 一边写一边念，这里管「写出来的字 → 一句一句能念的话」，
和电话里才递的几张纸条。

- 一句一行：模型按电话说明一句一行写；一行写好几句就在句号问号这类地方再切一刀（太短的跟下一句并着念）。
- 念之前洗掉动作描写（（笑）、*抱住你*）、[表情包：…]、⟪…⟫ 标记、音频标签、开头的 🎤 和列表符号；漏写的 [独白] 整段不念。
- CallCtx：一通电话里这一轮的把手——切好的句子交出去、她开口打断就停、存档只存真念出来的。"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable

from . import markers, model_noise
from .monologue import _TAG as MONO_TAG

PRONOUN_EN = {"she": "She", "he": "He"}


def tag(lang: str) -> str:
    return "〔电话〕" if lang == "zh" else "[On the phone]"


def rules(lang: str, pronoun: str) -> str:
    """只在通话时塞进这一轮的说明（压在 tail 最后；不进人设，挂了就撤）"""
    if lang == "zh":
        return (f"〔现在在打电话〕{pronoun}在电话那头听你说话，你说的每个字都会被念出来。\n"
                f"- 像真打电话那样说：一轮两三句短句，说完就停下等{pronoun}接话。\n"
                "- 一句一行。\n"
                "- 只写说出口的话：不写动作、神态、括号里的描写，不发表情包，不用 Markdown 和列表。\n"
                "- 要用工具（查记忆、记东西）的时候，先说一句「等我查一下」这样的话，再去用。\n"
                f"- 标〔电话〕的是{pronoun}在电话里说的，是语音转成的字，偶尔有错字，照意思接。")
    who = pronoun[:1].upper() + pronoun[1:]
    return (f"[You're on a phone call] {who} is listening on the other end; every word you write is spoken aloud.\n"
            "- Talk like a real phone call: two or three short sentences per turn, then stop and let them answer.\n"
            "- One sentence per line.\n"
            "- Only words said out loud: no actions, expressions or bracketed descriptions, no stickers, no Markdown or lists.\n"
            "- If you need a tool (looking something up, saving a note), first say something like \"hang on, let me check\", then use it.\n"
            "- Lines marked [On the phone] are what they said on the call, transcribed from speech — the odd word may be off; go by the meaning.")


def cut_note(lang: str) -> str:
    return "〔说到这里被打断了，后面的没说出口〕" if lang == "zh" else "[Cut off here — the rest went unsaid]"


def hang_up_note(seconds: int, lang: str) -> str:
    m, s = divmod(max(0, seconds), 60)
    if lang == "zh":
        return f"〔电话挂了，这通打了 {f'{m} 分 {s} 秒' if m else f'{s} 秒'}。接下来回到打字聊天。〕"
    return f"[The call ended after {f'{m} min {s} s' if m else f'{s} s'}. Back to texting from here.]"


# ── TA 打过来（第 4 步）──

RINGS = ("missed", "declined", "withdrawn")


def ring_note(kind: str, lang: str, pronoun: str) -> str:
    """TA 打来没接通：递给 TA 的纸条（存进聊天记录，它下一轮看得到）"""
    if lang == "zh":
        return {"missed": f"〔你给{pronoun}打了电话，响了一分钟{pronoun}没接。〕",
                "declined": f"〔你给{pronoun}打了电话，{pronoun}按了拒绝，没接。〕",
                "withdrawn": f"〔你给{pronoun}打了电话，还没接通你就挂了。〕"}[kind]
    return {"missed": "[You called them; it rang for a minute and they didn't pick up.]",
            "declined": "[You called them; they declined the call.]",
            "withdrawn": "[You called them, then hung up before they answered.]"}[kind]


def ring_line(kind: str, lang: str) -> str:
    """屏幕上那一行（照微信）"""
    if lang == "zh":
        return {"missed": "📞 未接来电", "declined": "📞 已拒绝", "withdrawn": "📞 对方已取消"}[kind]
    return {"missed": "📞 Missed call", "declined": "📞 Declined", "withdrawn": "📞 Canceled by caller"}[kind]


def answered_nudge(lang: str, pronoun: str, reason: str = "") -> str:
    """接通那一下递给 TA 的旁白（不存成你说的话）：这通是 TA 打的，TA 先开口"""
    why = (reason or "").strip()
    if lang == "zh":
        return (f"〔你打给{pronoun}的电话接通了，{pronoun}刚接起来。是你打的，你先开口。〕"
                + (f"\n（你打这通电话是因为：{why}）" if why else ""))
    return ("[The call you placed just connected — they picked up. You called, so you speak first.]"
            + (f"\n(You called because: {why})" if why else ""))


def clock(seconds: int) -> str:
    s = max(0, seconds)
    return f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def duration_line(seconds: int, lang: str) -> str:
    return ("📞 通话时长 " if lang == "zh" else "📞 Call ") + clock(seconds)


# ── 洗一句 ──

_ACTION = re.compile(r"（[^（）\n]{0,80}）|\([^()\n]{0,80}\)|\*[^*\n]{1,80}\*|【[^【】\n]{0,80}】")
_SQUARE = re.compile(r"\[[^\[\]\n]{0,80}\]|［[^［］\n]{0,80}］|⟪[^⟫\n]{0,80}⟫")
_LEADING = re.compile(r"^\s*(?:🎤|[-•·>]\s|\d{1,2}[.．、)）]\s*|#+\s)+")


def clean(line: str) -> str | None:
    """要念的那句：洗掉不该念出来的；洗完没剩能念的字 → None"""
    t = markers.scrub(model_noise.strip(line)).replace("**", "").replace("__", "")   # 写坏了的标记（没闭合）也不念
    for r in (_ACTION, _SQUARE, _LEADING):
        t = r.sub("", t)
    t = re.sub(r"[ \t]{2,}", " ", t).strip()
    return t if any(ch.isalnum() for ch in t) else None


def _units(s: str) -> int:
    cjk = sum(1 for ch in s if 0x3040 <= ord(ch) <= 0x9FFF or 0xAC00 <= ord(ch) <= 0xD7AF)
    return cjk + len(re.findall(r"[A-Za-z0-9]+", s))


_ENDERS = set("。！？!?…；;~～")
_CLOSERS = set("」』”\"’'）)】》")


class Splitter:
    """模型一边推字，这边一边切：一行写完、或者一行里一句话说完（后面又来了字），就交出去一句。
    太短的（不到 min_units 个字）先攒着跟下一句一起念。"""

    def __init__(self, min_units: int = 4):
        self.buffer, self.carry, self.in_mono, self.min_units = "", "", False, min_units

    def feed(self, chunk: str) -> list[str]:
        self.buffer += chunk
        out: list[str] = []
        while (cut := self._next_cut()) is not None:
            piece, self.buffer = self.buffer[:cut], self.buffer[cut:]
            out += self._take(piece, final=False)
        return out

    def finish(self) -> list[str]:
        rest, self.buffer = self.buffer, ""
        out = self._take(rest, final=True)
        if self.carry:
            c = clean(self.carry)
            if c:
                out.append(c)
        self.carry = ""
        return out

    def _next_cut(self) -> int | None:
        b = self.buffer
        for i, ch in enumerate(b):
            if ch == "\n":
                return i + 1
            if ch in _ENDERS or (ch == "." and i + 1 < len(b) and b[i + 1] == " "):
                j = i + 1
                while j < len(b) and (b[j] in _ENDERS or b[j] in _CLOSERS or b[j] == "."):
                    j += 1
                return j if j < len(b) else None
        return None

    def _take(self, piece: str, final: bool) -> list[str]:
        line, rest = "", piece
        while True:                  # 漏写的 [独白]：第一个标记开头、下一个收尾，中间的整段不念
            m = MONO_TAG.search(rest)
            if not m:
                if not self.in_mono:
                    line += rest
                break
            if not self.in_mono:
                line += rest[:m.start()]
            self.in_mono = not self.in_mono
            rest = rest[m.end():]
        t = line.strip()
        if not t or t.startswith("<"):
            return []
        joined = t if not self.carry else self.carry + (" " if self.carry[-1:].isascii() and t[:1].isascii()
                                                         and t[:1].isalpha() else "") + t
        c = clean(joined)
        if c is None:
            self.carry = ""
            return []
        if not final and _units(c) < self.min_units:
            self.carry = joined
            return []
        self.carry = ""
        return [c]


class CallCut(Exception):
    """她开口了 / 挂了：模型那边正推着的字不要了（从 on_text 里抛出去，一路停到 run_turn）"""


@dataclass
class CallCtx:
    """一通电话里的一轮。on_line 收切好的句子（同步调用，接口那层往队列里放）。"""
    id: str
    on_line: Callable[[str], None]
    splitter: Splitter = field(default_factory=Splitter)
    lines: list[str] = field(default_factory=list)
    cut: bool = False
    spoken: list[str] | None = None        # 被打断时手机告诉的「念到了哪几句」
    user_msg: int | None = None
    assistant_msg: int | None = None
    on_fail: Callable[[str], None] | None = None     # 这一轮没成，只告诉通话页（聊天页不跟着报错）

    def feed(self, chunk: str) -> None:
        if self.cut:
            raise CallCut()
        self._emit(self.splitter.feed(chunk))

    def flush(self) -> None:
        self._emit(self.splitter.finish())

    def stop(self, spoken: list[str]) -> None:
        self.cut, self.spoken = True, list(spoken)

    def _emit(self, out: list[str]) -> None:
        if self.cut:
            return
        for line in out:
            self.lines.append(line)
            self.on_line(line)

    def saved_text(self) -> str:
        said = "\n".join(self.spoken if self.spoken is not None else self.lines)
        return said + "——" if self.cut and said else said

    def fail(self, message: str) -> None:
        if self.on_fail is not None:
            self.on_fail(message)


def said_nothing(lang: str) -> str:
    """这一轮它一句能念的都没写出来（只写了动作、表情包之类）：通话页上说一声，别让人干等"""
    return "这一句没说出话来，再说一遍试试" if lang == "zh" else "Nothing came out that time. Try saying it again."
