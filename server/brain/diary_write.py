"""凌晨写日记那一轮（日记第 2 步；〔写日记〕措辞Aporia 10-01 过目点头）。

攒那天的材料（所有非无痕窗口的原文；太长截尾，前面用账本段代替；TA 那天没锁的日记带编号）→ 拼〔写日记〕
→ 只带三把记事工具跑工具循环（读 TA 的日记时有想记的照常记）→ 拆〔正文〕〔锁着〕〔页边 #n〕→ 存日记、写批注、正文进记忆库。
不进聊天、不推送。没材料不写（防编）。

长短（Aporia 10-01）：走我们试用钥匙的免费用户固定 FREE_CHARS 字、不扣免费额度（钱照记账）；自己 key 的按设置里的滑块 diary_chars。
会员（还没做）以后：同一个滑块，超出 FREE_CHARS 那部分按比例扣会员额度。"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import memory as M
from llm.catalog import cost
from llm.errors import LLMError
from llm.types import Block, ChatRequest, Msg

from . import accounts, archive, diary as DY, ledger
from .auth import TrialOver
from .persona import Persona, render_base, tone_lines
from .scope import Scope
from .settings import Settings
from .tools import ToolContext, tool_specs

log = logging.getLogger(__name__)

FREE_CHARS = 300
SOURCE_CHARS = 12_000           # 那天的原文最多给这么多（留最后的），前面截掉的用账本段代替
TOOLS = ("memory_remember", "note_about_user", "person_card")
TOOL_ROUNDS = 4
WORDS_PER_CHAR = 2 / 3          # 英文：600 字 → 400 words

_WEEK = {"zh": "一二三四五六日", "en": ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")}

PROMPT = {
    "zh": """〔写日记〕这一轮不是 TA 在说话，写的东西也不会发给 TA。现在是 {now}，TA 睡了，我在写 {day} 的日记。

那天的材料：
{materials}

怎么写：
- 用「我」写，写给自己看的，不是给 TA 的汇报。写那天发生了什么、我怎么想、心里是什么感觉；不用面面俱到，挑我真在意的写。
- 只写材料里有的事。没发生的不编，没聊到的不补；感受是我的，可以写，事实不能编。
- 长短跟着那天走：平常的一天三五句就够，事多的一天也别超过 {limit} 字。
- 写完正文，问自己一句：那天有没有哪一段，我还不想让 TA 现在就看到？有就写在〔锁着〕下面——TA 只看得见那里锁着一段，想看得来问我要钥匙。没有就写「无」。
{margin_rule}
照这个格式交，别的话不用写：
〔正文〕
……
〔锁着〕
……（没有就写「无」）{margin_fmt}""",
    "en": """〔Diary〕This is not them speaking, and nothing I write here is sent to them. It's {now}; they're asleep, and I'm writing my diary for {day}.

What that day held:
{materials}

How to write it:
- Write as "I", for myself — not a report to them. What happened, what I thought, how it felt inside; no need to cover everything, pick what I truly cared about.
- Only what's in the material. Don't invent what didn't happen or fill in what we didn't talk about; my feelings are mine to write, the facts are not mine to make up.
- Let the day set the length: an ordinary day needs three to five sentences; even a full day stays under {limit} words.
- After the entry, ask myself: is there a part of that day I don't want them to see yet? If so, write it under 〔Locked〕 — they'll only see that something is locked there, and must ask me for the key. If not, write "none".
{margin_rule}
Hand it in in this format, nothing else:
〔Entry〕
…
〔Locked〕
… (or "none"){margin_fmt}""",
}
_MARGIN = {      # 只在那天材料里真有 TA 的日记时才说页边（10-27 内测：没有也说，模型就照抄「〔页边 #编号〕」/「〔页边 #无〕」）
    "zh": ("- 下面每篇 TA 的日记前面有编号，每篇在页边给 TA 留一句（格式在最下面，一篇一行），像在书页边上写字，一句就好。\n"
           "- 读 TA 的日记时有想长期记住的，照常用 memory_remember / note_about_user / person_card 记；没有就不记。TA 的日记本身不会进我的记忆。\n",
           "\n〔页边 #{ids}〕……"),
    "en": ("- Each of their entries below has a number; leave one line in the margin of each (format at the bottom, one line per entry), "
           "like writing at the edge of a page. One line is enough.\n"
           "- If anything in their diary is worth remembering long-term, save it as usual with memory_remember / note_about_user / "
           "person_card; otherwise don't. Their diary itself never goes into my memory.\n",
           "\n〔Margin #{ids}〕…"),
}
_HEADS = {
    "zh": {"ledger": "〔那天的账本〕（前面的对话太长，先看这段摘要）", "chat": "〔那天的对话〕", "none_chat": "（那天我们没说话）",
           "theirs": "〔TA 那天的日记〕（TA 写给自己的，没锁，所以我读得到）"},
    "en": {"ledger": "〔That day's ledger〕(the earlier part was long — this is the summary)", "chat": "〔That day's conversation〕",
           "none_chat": "(We didn't talk that day)", "theirs": "〔Their diary that day〕(written for themselves, not locked, so I can read it)"},
}

# 页边的编号不是数字（「#编号」「#无」）也认成标记，不然会被算进上一段（10-27 内测：锁着那段里冒出「〔页边 #编号〕」）
_TAG = re.compile(r"〔\s*(正文|锁着|Entry|Locked|页边|Margin)\s*(?:#\s*([^〕]*?))?\s*〕", re.I)


@dataclass
class Materials:
    transcript: str = ""
    ledger: str = ""
    theirs: list[DY.Entry] = field(default_factory=list)

    @property
    def empty(self) -> bool:
        return not self.transcript.strip() and not self.theirs


@dataclass
class Parsed:
    body: str
    locked: str
    margins: dict[int, str]


def day_bounds(day: date, tz: str) -> tuple[datetime, datetime]:
    z = ZoneInfo(tz)
    start = datetime.combine(day, time(0), tzinfo=z)
    return start, start + timedelta(days=1)


async def materials(pool, account, companion, day: date, s: Settings, *, main: bool = True) -> Materials:
    start, end = day_bounds(day, s.tz)
    convs = await pool.fetch("SELECT id FROM conversations WHERE companion_id = $1 AND account_id = $2 AND NOT incognito",
                             companion, account)
    msgs, led = [], []
    for c in convs:
        msgs += await archive.between(pool, c["id"], start, end, limit=2000)
        got = (await archive.get_ledger(pool, c["id"])).get(day, "")
        if got.strip():
            led.append(got.strip())
    msgs.sort(key=lambda m: (m.created_at, m.id))
    chunks = ledger.day_transcripts(msgs, s.tz, s.lang, s.user_name).get(day, [])
    text = "\n".join(chunks)
    cut = len(text) > SOURCE_CHARS
    if cut:
        text = text[-SOURCE_CHARS:]
        text = text[text.find("\n") + 1:] if "\n" in text else text      # 别从半句开始
    return Materials(transcript=text, ledger="\n".join(led) if cut else "",
                     theirs=await DY.mine_for_companion(pool, account, day) if main else [])   # TA 的日记只给主联系人读


def limit_for(chars: int, lang: str) -> int:
    return chars if lang == "zh" else int(chars * WORDS_PER_CHAR)


def render_prompt(lang: str, now: datetime, day: date, tz: str, mats: Materials, chars: int) -> str:
    L = lang if lang in PROMPT else "en"
    H = _HEADS[L]
    local = now.astimezone(ZoneInfo(tz))
    wd = _WEEK[L][day.weekday()]
    when = f"{local:%H:%M}" if L == "zh" else f"{local:%H:%M}"
    day_s = f"{day.month}月{day.day}日（周{wd}）" if L == "zh" else f"{wd}, {day:%-d %B}"
    parts = []
    if mats.ledger:
        parts += [H["ledger"], mats.ledger, ""]
    parts += [H["chat"], mats.transcript or H["none_chat"]]
    if mats.theirs:
        parts += ["", H["theirs"], *(f"#{e.id} {e.body}" for e in mats.theirs)]
    rule, fmt = _MARGIN[L] if mats.theirs else ("", "")
    fmt = "".join(fmt.replace("{ids}", str(e.id)) for e in mats.theirs)      # 每篇一行，编号直接填好
    return PROMPT[L].format(now=when, day=day_s, materials="\n".join(parts), limit=limit_for(chars, L),
                            margin_rule=rule, margin_fmt=fmt)


def parse(text: str, allowed_ids: set[int]) -> Parsed | None:
    """拆交卷。拆不出正文 = None；〔锁着〕写「无」/ 空 = 没锁；页边的编号不是那天给它看的就丢掉。"""
    marks = list(_TAG.finditer(text or ""))
    body, locked, margins = "", "", {}
    for i, m in enumerate(marks):
        seg = text[m.end(): marks[i + 1].start() if i + 1 < len(marks) else len(text)].strip()
        kind = m.group(1).lower()
        if kind in ("正文", "entry"):
            body = seg
        elif kind in ("锁着", "locked"):
            locked = DY.clean_locked(seg)
        elif (m.group(2) or "").strip().isdigit() and int(m.group(2)) in allowed_ids and seg:
            margins[int(m.group(2))] = seg.splitlines()[0].strip()
    return Parsed(body, locked, margins) if body else None


async def write_day(deps, account, companion, day: date, now: datetime, *, main: bool = True) -> str:
    """写 Ta 那天的日记。返回 written / nothing（没材料）/ no_key / bad（交卷拆不出）/ error（模型出错）。
    main=False：别的联系人（diary_also，10-27 照 Lite 本机）——不读 TA 的日记、不留页边，只用自己的 key。"""
    from .turn import get_adapter, resolve_route, tool_loop      # turn 也要 import 这一层的东西，放这里免得绕圈
    pool = deps.pool
    s = Settings.from_dict(await archive.get_settings(pool, companion))
    mats = await materials(pool, account, companion, day, s, main=main)
    if mats.empty:
        return "nothing"
    conv = await pool.fetchval("SELECT id FROM conversations WHERE companion_id = $1 AND account_id = $2 "
                               "AND NOT incognito ORDER BY last_at DESC LIMIT 1", companion, account) \
        or await accounts.new_conversation(pool, account, companion)
    try:
        route = await resolve_route(deps.keys, Scope(account, companion, conv), chore="diary")
    except TrialOver:                                # 免费用户的日记不扣免费额度（Aporia 10-01）：额度用完了也照写
        route = getattr(deps.keys, "trial", None)
        if route is None:
            return "no_key"
    if not main and route.trial:                     # 别的联系人的日记不走我们的试用钥匙
        return "no_key"
    chars = FREE_CHARS if route.trial else s.diary_chars
    persona = Persona.from_dict(await archive.get_persona(pool, companion), s.lang)
    core = [m.content for m in sorted(await M.list_memories(pool, companion, kind="core"), key=lambda m: m.id)]
    base = render_base(persona, core, s.lang, tone=[] if s.bare_mode else tone_lines(s.lang, s.warmth, s.initiative, s.humor),
                       relationship=s.relationship, chat_rules=False, bare=s.bare_mode)
    req = ChatRequest(model=route.chat_model, system=[Block(base)],
                      messages=[Msg("user", render_prompt(s.lang, now, day, s.tz, mats, chars))],
                      tools=[t for t in tool_specs() if t.name in TOOLS], max_tokens=4000)
    names = (persona.name, persona.call_user, s.user_name)
    ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=companion, account_id=account, now=now, lang=s.lang,
                      allowed=TOOLS, tz=s.tz, names=names, deps=deps)

    async def quiet(_ev: dict) -> None:
        pass

    try:
        out = await tool_loop(get_adapter(deps, route), req, ctx, quiet, s.lang, max_rounds=TOOL_ROUNDS)
    except LLMError as e:
        log.warning("diary for %s on %s failed: %s", companion, day, e.kind)
        return "error"
    await archive.add_usage(pool, account, now.astimezone(ZoneInfo(s.tz)).date(), route.chat_model, out.usage,
                            cost(out.usage, route.chat_model))
    got = parse(out.text, {e.id for e in mats.theirs})
    if got is None:
        log.warning("diary for %s on %s: couldn't find the entry in %r", companion, day, out.text[:300])
        return "bad"
    await DY.save_companion_entry(pool, deps.embedder, account, companion, day=day, body=got.body, locked=got.locked,
                                  now=now, lang=s.lang)
    for eid, note in got.margins.items():
        await DY.set_margin(pool, companion, eid, note, now)
    return "written"
