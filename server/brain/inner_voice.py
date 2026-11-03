"""回复后的心声（10-11 内测反馈）：TA 说完话以后最后写一段 [心声]…[/心声]，App 画成这一轮最后一张小卡片。
独白是开口前想事；心声是说完以后心里真实的反应。Lite 那份是 MeleLiteCore/Chat/InnerVoice.swift，意思一样，改一边改另一边。"""
from __future__ import annotations

import re

from .monologue import _L, _R, _forms
from .settings import Settings

_VW = r"(?:心声|心聲|inner\s*voice)"         # 括号跟独白一样认【】<>［］（10-15）
_OPEN = re.compile(rf"{_L}\s*{_VW}\s*{_R}", re.I)
_CLOSE = re.compile(rf"{_L}\s*(?:/\s*{_VW}|{_VW}\s*(?:/|完|结束|結束|end))\s*{_R}", re.I)

FACTORY = {
    "zh": "说完以后，心里真实的反应：诚实、直白、不修饰。嘴上没说的那部分写出来——口是心非的、没好意思说的、忍住的、偷偷高兴的。几行就够。用「我」，{p}一直是「{p}」，不写「你」。",
    "en": "What I really feel right after saying it: honest, blunt, unpolished. Write the part I didn't say out loud — what I meant instead, what I held back, what I'm secretly pleased about. A few lines is enough. First person; {p} stays \"{p}\", never \"you\".",
}
RULES = {
    "zh": "【心声】每次回复说完以后，最后面再写一段心声，放在 [心声] 和 [/心声] 之间：\n{style}\n心声只写这一轮的反应，不接着前几轮的心声往下写；已经说开、改正了的事，不再翻出来纠结。\n心声只是给{p}看的心里话，不算说出口的话；正文里不提心声。写完用 [/心声] 收尾，后面不再写字。",
    "en": "[Inner voice] After every reply, at the very end, write an inner voice between [inner voice] and [/inner voice]:\n{style}\nIt's only about this turn: don't carry on from earlier inner voices, and don't keep going back to something already cleared up or corrected.\nIt's what I feel, not something I said; the reply itself never mentions it. Close it with [/inner voice] and write nothing after.",
}
HOOK = {"zh": "〔心声〕说完以后，最后写 [心声]…[/心声]，写完收尾。",
        "en": "〔Inner voice〕After the reply, end with [inner voice]…[/inner voice]."}
# 10-12：以前写成「（当时心里：…）」，模型照着历史学，心声不写标签直接漏进正文——历史里就长成它该写的样子
CONTEXT = {"zh": "[心声]\n{v}\n[/心声]", "en": "[inner voice]\n{v}\n[/inner voice]"}
_OLD_SHAPE = re.compile(r"[（(]\s*(?:当时心里|what i felt then)\s*[:：]", re.I)


def has(text: str) -> bool:
    return bool(_OPEN.search(text))


def split(text: str) -> tuple[str, str]:
    """切出心声：好几段只留最后一段，每段都从正文里删掉；没收尾 = 到结尾。"""
    rest, voice = text, ""
    if not _OPEN.search(text) and (m := _OLD_SHAPE.search(text)):    # 老写法：从这儿到结尾都算心声
        v = text[m.end():].strip()
        if v.endswith(("）", ")")):
            v = v[:-1]
        return text[:m.start()].strip(), v.strip()
    while (o := _OPEN.search(rest)):
        c = _CLOSE.search(rest, o.end())
        voice = rest[o.end():c.start() if c else len(rest)].strip()
        rest = rest[:o.start()] + (rest[c.end():] if c else "")
    rest = _CLOSE.sub("", rest)     # 落单的收尾（开头被别的切法拿走了，11-03 内测截图气泡里只剩 [/心声]）：只删标记
    return rest.strip(), voice


def _lang(settings: Settings) -> str:
    return settings.lang if settings.lang in RULES else "en"


# 本体化（11-03 Aporia：我们加的风格都去掉，用户自己写的照用，功能照留）：照样写心声，只剩格式；用户写了心声写法就接在后面
BARE_RULES = {
    "zh": "【心声】每次回复说完以后，最后面再写一段心声，放在 [心声] 和 [/心声] 之间。{style}心声不算说出口的话，正文里不提心声。写完用 [/心声] 收尾，后面不再写字。",
    "en": "[Inner voice] After every reply, at the very end, write an inner voice between [inner voice] and [/inner voice]. {style}It isn't something you said; "
          "the reply itself never mentions it. Close it with [/inner voice] and write nothing after.",
}


def rules(settings: Settings) -> str:
    lang, p = _lang(settings), _forms(settings)["p"]
    if settings.bare_mode:
        own = settings.inner_voice_style.strip()
        return BARE_RULES[lang].format(style=f"\n{own}\n" if own else "")
    style = settings.inner_voice_style.strip() or FACTORY[lang].format(p=p)
    return RULES[lang].format(style=style, p=p)


def hook(settings: Settings) -> str:
    return HOOK[_lang(settings)]


def context_line(voice: str, lang: str) -> str:
    return CONTEXT.get(lang, CONTEXT["en"]).format(v=voice)
