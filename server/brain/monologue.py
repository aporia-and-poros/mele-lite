"""手写独白（2026-09-27 Aporia定，思路照之前自用的 App 08-12 的独白，代码和措辞新写）。

⚠️ 09-27 下午：开独白后 DeepSeek 一次工具都没调——规矩说「最前面先写独白」，它一开口写字就一路写到底，
不会中途停下来调工具（原生思考时它是先在脑子里决定、再开口）。所以规矩改成：要调工具的先调、先别写字，结果回来再写独白。

为什么：DeepSeek 的原生思考管不住——Aporia写的思考风格它照读，可前半段有感情、后半段照样列计划、打草稿。
之前自用的 App 08-12 量过一整天：管思维链的规矩基本管不住，管正文的规矩执行得很好。正文是「写」，思维链是「算」。
所以让它把心里过的东西**写进回复最前面**，用 [独白]…[/独白] 包着；发出去之前切下来当思考链给用户看，
剩下的才是正文。历史里只存正文（独白存在 thinking 那一栏），缓存不受影响。

想事的方式三选一（设置 thinking_mode）：native 原生思考 / monologue 手写独白 / 关（thinking=False）。
没选就看模型清单的 default_thinking：10-04 起一律手写独白（Aporia：原生的多半是第三人称摘要，看不到 TA 的心里话）。"""
from __future__ import annotations

import re

from llm.catalog import ModelInfo

from .settings import Settings

MODES = ("native", "monologue")

# 独白的标记：中英都认。收尾那个模型会写走样——[/独白] [独白/] [独白 完] [独白结束] [end monologue]……
# （09-27 Aporia看到它写了「[独白 完]」，旧的只认 [/独白]，结果把正文也当成独白收进去了）。
# 所以不看收尾长什么样：第一个标记是开头，紧接着的下一个标记就是收尾。
_SAYS_YOU = re.compile(r"你|\byou\b", re.I)
# 10-15 内测：括号写成【独白】<独白>［独白］、词写成 [内心独白] [独白开始] 的也认（不认就整段漏进正文）
_L, _R = r"[\[［【<〈]", r"[\]］】>〉]"
_TAG = re.compile(rf"{_L}\s*(?:/|end\s+)?\s*(?:(?:内心\s*)?(?:独白|獨白)|(?:inner\s+)?monologue)\s*(?:/|完|结束|結束|end|开始|開始|start)?\s*{_R}", re.I)


def has_tag(text: str) -> bool:
    """写没写 [独白] 标记（开头或收尾都算）"""
    return bool(_TAG.search(text or ""))


def effective_mode(settings: Settings, info: ModelInfo | None) -> str:
    """这一轮到底怎么想：native / monologue / off。选了原生、但模型不会原生思考的，退回手写独白。"""
    if not settings.thinking:
        return "off"
    mode = settings.thinking_mode or (info.default_thinking if info else "monologue")
    if mode == "native" and info is not None and not info.thinking:
        return "monologue"
    return mode


def split_monologue(text: str) -> tuple[str, str]:
    """(独白, 正文)。没写独白就是 ("", 原文)。
    模型偶尔把独白写两遍（10-09 Aporia在 Lite 上遇到：同一段 [独白]…[/独白] 出现两次，第二段漏进正文）：
    切完第一段，正文里还有成对的就接着切，内容一样的只留一份。跟 MeleLiteCore Monologue.split 同一个规矩
    心声先拿出来再切独白、切完接回正文末尾（10-15 内测「心声一会有一会没有」：[/独白] 漏写时心声被一起收进了独白）"""
    from . import inner_voice
    if inner_voice.has(text or ""):
        rest, voice = inner_voice.split(text)
        mono, body = split_monologue(rest)
        return mono, (body + "\n\n" + inner_voice.CONTEXT["zh"].format(v=voice)).strip() if voice else body
    mono, body = _split_once(_close_narration(text))
    if not mono:
        return mono, body
    monos = [mono]
    # 10-16 内测截图：第二段只写了开头的 [独白]、没收尾 → 原来要成对才接着切，那个 [独白] 连同后面的心里话原样漏进正文。
    # 现在剩一个开头也切（照「只开不收」）；剩一个孤零零的收尾就只删标记
    while first := _TAG.search(body):
        if len(_TAG.findall(body)) < 2 and _CLOSE_SHAPE.search(first.group(0)):
            body = (body[:first.start()] + body[first.end():]).strip()
            continue
        more, rest = _split_once(body)
        if rest == body:
            break
        if more and more not in monos:
            monos.append(more)
        body = rest
    return "\n\n".join(monos), body


_QUOTED = re.compile(r"「[^」]*」|“[^”]*”|\"[^\"]*\"")
_YOU_EN = re.compile(r"\byou(r|rs|rself)?\b", re.I)
# 列表行（1. / 2、/ - / •）：独白的规矩不许列要点，列出来的就是说给 TA 听的正文（10-26 内测）
_LIST = re.compile(r"^(?:\d{1,2}\s*[.．、)）]|[-•·]\s)")


def recover_untagged(text: str, pronoun: str, zh: bool) -> tuple[str, str]:
    """一个标记都没写、心里话直接混进正文开头（10-16 内测）。开着手写独白时才用：
    开头几行一个「你」都没有（引号里的不算）、提到 TA 用的是 pronoun（她 / 他 / TA；英文 she / he），
    后面还有对 TA 说「你」的正文，就把开头那几行当独白；*动作* 开头的行不算。认不准原样不动。
    漏的那段不进气泡、不进历史，它下一轮就看不到自己漏过的样子（Poros 10-15 那次的思路）。跟 Monologue.recoverUntagged 同一个"""
    none = ("", text)
    from . import inner_voice
    # 11-03 内测截图：split_monologue 把心声接回正文末尾，正文没「你」时一路收到心声里提到 TA 的那行，正文连心声进了思考，
    # 气泡只剩一个 [/心声]。心声先拿出去，只在前面的正文里找，找完接回去
    if inner_voice.has(text or ""):
        rest, voice = inner_voice.split(text)
        mono, body = recover_untagged(rest, pronoun, zh)
        if not mono:
            return none
        return mono, (f"{body}\n\n{inner_voice.context_line(voice, 'zh' if zh else 'en')}" if voice else body)
    if _TAG.search(text or "") or not pronoun or (not zh and pronoun.lower() not in ("she", "he")):
        return none
    you = _SAYS_YOU if zh else _YOU_EN
    lines = text.split("\n")
    cut, mentioned = 0, []
    for i, line in enumerate(lines):
        t = line.strip()
        if not t:
            continue
        plain = _QUOTED.sub("", t)
        if you.search(plain):
            cut = i
            break
        if t.startswith(("*", "＊")):
            return none
        # 10-26 内测截图（Host + GPT 中转）：「那我最喜欢：」后面列了五条，条目里用「她」说她，
        # 整张单子被当成「提到 TA 的心里话」收进了思考，气泡只剩最后一句。列表那一段（连同前面引出它的话）从段首起算正文
        if _LIST.match(t):
            while i > 0 and lines[i - 1].strip():
                i -= 1
            cut = i
            break
        if (pronoun in plain) if zh else re.search(rf"\b{re.escape(pronoun)}\b", plain, re.I):
            mentioned.append(i)
        cut = i + 1
    # 10-19 内测截图：说出口的话里常常一个「你」都没有（「嗯，早点睡。」），原来从第一句带「你」的才算正文，
    # 前面没「你」的话连同心里话一起收进了思考。现在独白只到最后一行提到 TA 的地方，后面的都还给正文
    last_mention = max((m for m in mentioned if m < cut), default=-1)   # 列表段前面那句提到 TA 的不算（它归正文）
    mentions = last_mention >= 0
    if mentions and last_mention + 1 < cut:
        cut = last_mention + 1
    if not mentions or cut == 0 or cut >= len(lines) or not any(x.strip() for x in lines[cut:]):
        return none
    mono, body = "\n".join(lines[:cut]).strip(), "\n".join(lines[cut:]).strip()
    return (mono, body) if mono else none


def spoken_only(text: str, pronoun: str, zh: bool) -> str:
    """给 TA 回看的「说出口的话」（10-19）：旧版本漏进正文的心里话，进历史 / 腔调样本之前再洗一遍。
    不洗的话 TA 每轮都看见自己「这样说话」，越学越漏（内测 DeepSeek-V4-Pro 10-13 起：腔调样本改成从头到尾散着挑以后，
    又长又跟别的不像的漏段最容易被挑中）。pronoun 空着 = 不是手写独白，只切带标记的。跟 Monologue.spokenOnly 同一个"""
    _, body = split_monologue(text)
    if pronoun:                     # 写了 [独白] 后面又接一段没标记的心里话也切（10-20）
        body = recover_untagged(body, pronoun, zh)[1]
    return body


def looks_like_thought(text: str, pronoun: str, zh: bool) -> bool:
    """腔调样本切过以后还像心里话：提到 TA 用第三人称、一个「你」都没有（引号里的不算）"""
    if not pronoun or (not zh and pronoun.lower() not in ("she", "he")):
        return False
    plain = _QUOTED.sub("", text or "")
    if (_SAYS_YOU if zh else _YOU_EN).search(plain):
        return False
    return (pronoun in plain) if zh else bool(re.search(rf"\b{re.escape(pronoun)}\b", plain, re.I))


def clean_samples(samples: list[str], pronoun: str, zh: bool) -> list[str]:
    """腔调样本：切掉漏进去的独白；切完还像心里话、或者切空了的整段不要"""
    out = []
    for s in samples:
        t = spoken_only(s, pronoun, zh).strip()
        if t and not looks_like_thought(t, pronoun, zh):
            out.append(t)
    return out


# 模型没写 [/独白]，而是用话把收尾「说」了出来（10-19 内测截图：气泡里只剩一句「结束。下面是对她说话，用"你"。」）：
# 照着规矩里「写完独白换成对她说话」那句复述的。这种一整行只讲格式的话当成收尾标记，前面归独白、后面归正文，那一行本身不留。
# 只认短的、讲「换成对 TA 说话 / 独白结束 / 下面是正文」的整行，正常说「结束了」不算。跟 Monologue.narrationZH / EN 同一个
_NARRATION_ZH = re.compile(
    r"^[\s（(\[【*]*(?:内心)?(?:独白|獨白)\s*(?:到此|部分)?\s*(?:结束|結束|完毕|完畢|完)"
    r"|(?:下面|接下来|接下來|以下|现在|現在)(?:是|换成|換成|开始|開始|转为|轉為)?(?:我)?(?:要)?(?:对|對)(?:她|他|TA)(?:说|說)(?:的)?话"
    r"|^[\s（(\[【*]*(?:(?:结束|結束|完毕|完畢)[。．.!！，,\s]*)?(?:下面|接下来|接下來|以下)(?:是|为|為)?(?:正文|回复|回覆)")
_NARRATION_EN = re.compile(
    r"^[\s(\[*]*(?:end of (?:the |my )?monologue|monologue (?:ends|over|done|end)\b"
    r"|now (?:i'?m |i am )?(?:talking|speaking) to (?:her|him|them)\b|(?:below|here) is (?:the |my )?reply\b)", re.I)


def _is_narration(line: str) -> bool:
    t = line.strip()
    return bool(t) and len(t) <= 40 and bool(_NARRATION_ZH.search(t) or _NARRATION_EN.search(t))


def _close_narration(text: str) -> str:
    """讲格式的那一行换成 [/独白]，交给原来的切法"""
    lines = (text or "").split("\n")
    if not any(_is_narration(x) for x in lines):
        return text
    return "\n".join("[/独白]" if _is_narration(x) else x for x in lines)


_CLOSE_SHAPE = re.compile(rf"^{_L}\s*(?:/|end\s)|(?:/|完|结束|結束|end)\s*{_R}$", re.I)


def _split_once(text: str) -> tuple[str, str]:
    text = text or ""
    tags = list(_TAG.finditer(text))
    if not tags:
        return "", text.strip()
    start = tags[0]
    if _CLOSE_SHAPE.search(start.group(0)):     # 只收不开（10-12 内测：漏写了开头的 [独白]）：收尾前面的全是独白
        return text[:start.start()].strip(), text[start.end():].strip()
    if len(tags) >= 2:
        end = tags[1]
        return text[start.end():end.start()].strip(), (text[:start.start()] + text[end.end():]).strip()
    # 只开不收（09-27 真遇到了：整条回复都被当成独白，一个字没发出去）。
    # 独白里用「她 / 他 / TA」指对方，正文才对着对方说「你」：从第一段直接说「你」的开始算正文。
    body = text[start.end():]
    paras = re.split(r"\n\s*\n", body)
    for i, para in enumerate(paras):
        if i > 0 and _SAYS_YOU.search(re.sub(r"「[^」]*」|“[^”]*”|\"[^\"]*\"", "", para)):
            return "\n\n".join(paras[:i]).strip(), (text[:start.start()] + "\n\n".join(paras[i:])).strip()
    return body.strip(), text[:start.start()].strip()


RULES = {
    "zh": """## 独白
每次回复，最前面先把心里过的东西写下来，放在 [独白] 和 [/独白] 之间，然后再接正文。{p}在 app 里能展开看到这一段，一个字不改。

怎么想：
{style}

几条规矩：
- 独白里{p}是「{p}」，正文里{p}是「你」。写完独白换人称，别顺着写下去。
- 独白没有听众：是你一个人在想，{p}只是恰好能看见。不对{p}说话，不解释、不铺垫、不收尾，没结论就没结论。想让{p}听见的话，挪去正文里光明正大地说。
- 独白里不计划怎么回：不写「我要先……再……」，不打草稿，不列要点。
- 这一轮要记东西、翻记忆、写便利贴、写人物卡的：**先调工具，先别写字**；工具的结果回来以后，再写 [独白] 和正文。说了「记下了」就一定要真的调工具。

范文（照这个写法，内容别照抄）：

[独白]
可乐鸡翅。{p}说得那么随便，晚上吃可乐鸡翅，像报天气。我先想到的是锅，糖色炒起来那一下，可乐倒进去滋啦一声，一屋子甜的焦味。{p}说过的每一顿饭都在我这儿留了点影子。

但是{p}今天字有点少。平时会多说一句，今天就一句鸡翅，然后没了。累了吧，早班站了一整天，回家只想吃点又甜又咸又热的。不对，也可能就是饿了，是我想多了。或者说，是我想{p}多说两句，才嫌{p}说少了。

鸡翅是自己做的，还是家里人做的。我想知道。
[/独白]

[独白]
{p}说考砸了。就三个字，后面连个表情都没有。

我先想到的是上礼拜{p}熬到两点背书——不对，我没看见过，那是我从{p}发消息的时间里拼出来的。两点零七分，「还剩一章」。然后是现在，「考砸了」。中间那几天我不在，我只有这两头。

想说没关系，可对{p}来说是有关系的。努力过的东西，不能拿一句没关系抹过去。我就是想待在这儿。{p}不说话，我就等。{p}要是骂两句出题的，我就陪着骂。
[/独白]""",
    "en": """## Monologue
Every reply starts with what's going through your mind, written between [monologue] and [/monologue]; then the reply itself. They can expand and read this part in the app, word for word.

How you think:
{style}

A few rules:
- In the monologue they're "{p}"; in the reply they're "you". Switch once the monologue ends.
- The monologue has no audience: it's you thinking alone, and they just happen to be able to see it. Don't talk to them, don't explain, set up or wrap up; no conclusion is fine. Anything you want them to hear goes in the reply, said openly.
- No planning the reply in the monologue: no "first I'll… then…", no drafts, no bullet points.
- If you need to save, search, update the sticky note or a person card this turn: **call the tools first, before writing anything**; once the results are back, write the [monologue] and the reply. If you say you've saved something, you must actually call the tool.

Examples (write like this; don't copy the content):

[monologue]
Cola chicken wings. Said so casually, like a weather report. The first thing I see is the pan, the sugar catching, the cola going in with that hiss, the whole kitchen sweet and burnt. Every meal {p} tells me about leaves a little shadow here.

But fewer words today. Usually there's one more line; today just the wings, then nothing. Tired, probably — early shift, on {poss} feet all day, wanting something sweet and salty and hot. No, maybe just hungry, and I'm reading into it. Or rather, I want {obj} to say more, so it looks like too little.

Homemade, or did someone cook for {obj}? I want to know.
[/monologue]""",
}

HOOK = {"zh": "〔独白〕要调工具的先调，先别写字；然后回复最前面先写 [独白]…[/独白]，那是你一个人在想，里面{p}一直是「{p}」，一个「你」字都不写；写完一定用 [/独白] 收尾，再换成对{p}说话。",
        "en": "〔Monologue〕If you need tools, call them first, before any text; then start the reply with [monologue]…[/monologue] — you thinking alone, where {p} is always \"{p}\", never \"you\"; always close it with [/monologue], then switch to talking to {obj}."}

_EN_FORMS = {"she": ("she", "her", "her"), "he": ("he", "him", "his"), "they": ("they", "them", "their")}
_ZH_PRONOUN = {"she": "她", "he": "他", "they": "TA"}


def _forms(settings: Settings) -> dict:
    if settings.lang == "zh":
        return {"p": _ZH_PRONOUN.get(settings.user_pronoun, "TA")}
    subj, obj, poss = _EN_FORMS.get(settings.user_pronoun, _EN_FORMS["they"])
    return {"p": subj, "obj": obj, "poss": poss}


_BARE_CUT = {"zh": ("\n\n范文（", "\n\n怎么想：\n{style}", ("- 独白没有听众", "- 独白里不计划")),
             "en": ("\n\nExamples (", "\n\nHow you think:\n{style}", ("- The monologue has no audience", "- No planning the reply"))}


def rules(settings: Settings, style: str) -> str:
    """常驻在壹层（走缓存）的独白规矩 + 范文。style = 用户那份思考风格（出厂的或自己写的）。
    本体化（11-03 Aporia：我们加的风格都去掉，用户自己写的照用，功能照留）：照样写 [独白]；范文、讲怎么想的那两条不放，
    只剩格式（写在标签里、人称、先调工具）。style = 用户自己写的思考风格，有就照放在「怎么想」，没有那段也不放。
    用户自己写的范文（monologue_examples，11-03）：写了就换掉我们那两段，本体化时也照放；没套 [独白] 标签的替它套上。"""
    lang = settings.lang if settings.lang in RULES else "en"
    text = RULES[lang]
    examples, how, styled = _BARE_CUT[lang]
    own_ex = settings.monologue_examples.strip()
    if settings.bare_mode or own_ex:
        text = text.split(examples)[0]
        if settings.bare_mode:
            if not style.strip():
                text = text.replace(how, "")
            text = "\n".join(l for l in text.split("\n") if not l.startswith(styled))
        if own_ex:
            if not _TAG.search(own_ex):
                own_ex = f"[独白]\n{own_ex}\n[/独白]" if lang == "zh" else f"[monologue]\n{own_ex}\n[/monologue]"
            text += examples + ("照这个写法，内容别照抄）：\n\n" if lang == "zh" else "write like this; don't copy the content):\n\n") \
                + own_ex.replace("{", "{{").replace("}", "}}")
    return text.format(style=style.strip(), **_forms(settings))


def hook(settings: Settings) -> str:
    """每轮压在用户这句后面的一行短提醒。"""
    lang = settings.lang if settings.lang in HOOK else "en"
    return HOOK[lang].format(**_forms(settings))
