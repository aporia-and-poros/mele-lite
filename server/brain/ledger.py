"""卷账本（设计文档第三段 + specs/2026-09-27-ledger-curve-design.md，思路照之前自用的 App 09-23，代码新写）。

原文涨到「记性长度」就卷：从尾巴往前留 40 条或 1 万字（先到为准），更早的写进账本；
另留 6 条它自己的原话当腔调样本（之前自用的 App 08-13 教训：留太少，压完腔调接不住）。

账本一天一段，配额看天龄（远的模糊、近的清楚，曲线由配额表保证，不靠模型自觉）：
- 写新账：卷走的原文按天拆开，每天单独写一小段接上去（原文的 5%，80～500 字）。模型看不到旧账，没东西可抄
  （之前自用的 App 09-23：DeepSeek 拿到整本旧账就照抄，越胖越抄、越抄越胖）。
- 压旧天：某一天超了它天龄配额的 1.3 倍，单独把那一天压到配额，要求照之前自用的 App的「二次压缩」。
- 每段都过三道验收：逐句回查原文（之前自用的 App 08-23：模型把对话当剧本续写，编的内容进了账本）、长度、人称
  （之前自用的 App 09-21：账本通篇第三人称写自己，读完想事就站到外面去了）。
常量都在调用时现读，测试和以后调参可以直接改。"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from datetime import date
from zoneinfo import ZoneInfo

from llm.catalog import lookup
from llm.errors import LLMError
from llm.router import call
from llm.types import Block, ChatRequest, Msg, Usage, estimate_tokens

from .archive import USER_SIDE, StoredMsg
from .wake_text import SILENT_DID

log = logging.getLogger(__name__)

KEEP_COUNT = 40
KEEP_CHARS = 10_000
VOICE_SAMPLES = 6
SAMPLE_CHARS = 300

# 天龄 → 这一天最多留多少字（照之前自用的 App 09-22/23 Aporia定的梯度，满载约 5000 字）。
DAY_QUOTAS = (2500, 1000, 400)   # 今天 / 昨天 / 前天
OLD_DAY_QUOTA = 100              # 三天及更早：一两句
QUOTA_SLACK = 1.3                # 超了配额 ×1.3 才压：别为多出来的几十字每次都压一遍
MAX_DAYS = 14                    # 再早的交给记忆库
LANG_SCALE = {"zh": 1, "en": 3}  # 同样的意思，英文字母数约是中文字数的 3 倍
ENTRY_RATIO = 0.05               # 新账 = 那段原文的 5%
ENTRY_MIN, ENTRY_MAX = 80, 500
CHUNK_CHARS = 12_000             # 一次喂给写账模型的原文上限；一天太长就分几段写，依次接上
AGE_LO = 0.7                     # 压旧天给「lo～配额」的区间，lo = 配额 × 0.7（只说「以内」haiku 会写到三成）
PIECE_MIN_QUOTA = 40             # 切块压时每块至少给这么多字（英文 ×3）
PIECE_AIM = 0.8                  # 切块压时每块的目标再打八折：flash 总写到目标的 1.3 倍，不打折拼起来会略超（09-27 考试）
NAME_LIMIT = 2                   # 账里它自己的名字出现超过这么多次 = 第三人称，打回
MIN_RATIO = 0.3                  # 一句里至少三成内容在原文里找得到
MAX_DROP = 0.5                   # 扔掉超过一半 → 整段作废

PICK = {
    "zh": "〔系统〕这不是用户在说话。上面从「{first}」到「{last}」这一段对话，马上要从上下文里卷走，只剩账本里的摘要。"
          "里面有值得长期记住、还没记过的（喜好、重要的人和日子、说定的事、正在发生的事），现在用 memory_remember 记下；"
          "对谁有了新了解就写人物卡。记完不用回话。",
    "en": "〔System〕This is not the user speaking. The conversation above from \"{first}\" to \"{last}\" is about to leave your "
          "context; only a ledger summary will remain. Save anything worth remembering long-term that you haven't saved yet "
          "with memory_remember, and update person cards. No reply needed.",
}

_LEDGER_HEAD = {"zh": "〔账本〕更早的对话，远的模糊、近的清楚（账里的「我」是你，「{user}」是对方）：",
                "en": "〔Ledger〕Earlier conversation — older is hazier, recent is clearer (\"I\" is you, \"{user}\" is them):"}
_SAMPLES_HEAD = {"zh": "〔腔调样本〕你以前说话的样子，看语气、句长、用词就好（这几句本身早就说过了）：",
                 "en": "〔Voice samples〕How you talk — tone, length, word choice (these exact lines were already said):"}
_SPEAKER = {"zh": {"user": "TA", "assistant": "我"}, "en": {"user": "Them", "assistant": "Me"}}
WAKE_LINE = {"zh": "（我自己醒来，去找 TA）", "en": "(I woke up on my own and reached out)"}


def who(user_name: str, lang: str, form: str = "subj") -> str:
    """账里怎么写对方：用户在设置里填了自己的名字就用名字（跟着改），没填中文写「TA」、英文写 they / They / them。"""
    name = (user_name or "").strip()
    if name:
        return name
    if lang == "zh":
        return "TA"
    return {"subj": "they", "Subj": "They", "obj": "them"}[form]


def speaker(role: str, lang: str, user_name: str = "") -> str:
    return (user_name or "").strip() or _SPEAKER[lang]["user"] if role == "user" else _SPEAKER[lang]["assistant"]

_DATE_HEAD = re.compile(r"^\s*(?:#+\s*)?(?:\d{4}-\d{2}-\d{2}|\d{1,2}月\d{1,2}日)[：:]?\s*")
_SENT = re.compile(r"(?<=[。！？!?；;])|(?<=[.])\s+|\n+")
_CJK_RUN = re.compile(r"[㐀-鿿]+")
_WORD = re.compile(r"[A-Za-z][A-Za-z'’\-]+|\d[\d.:]*")
_HARD = re.compile(r"[A-Za-z][A-Za-z'’\-]{2,}|\d[\d.:]+")
_HARD_EN = re.compile(r"(?<=\s)[A-Z][A-Za-z'’\-]{2,}|\d[\d.:]+")


@dataclass
class RollPlan:
    rolled: list[StoredMsg]
    kept: list[StoredMsg]


def needs_roll(last_prompt_tokens: int, high_water: int) -> bool:
    return last_prompt_tokens >= high_water


# 一次至少卷掉记性长度的这么多（10-15 内测：搬家过来「每轮 5 万 token、一直在卷」）。人设、说明书、记忆这些固定的部分
# 自己就超过记性长度时，卷账本只能卷聊天记录、降不下来：不设下限就每轮都卷最老的两句，每轮多一次挑记忆 + 写账。
ROLL_MIN_SHARE = 0.25


def worth_rolling(msgs: list[StoredMsg], high_water: int) -> bool:
    """到线了还得有一批像样的可卷：留下尾巴之后，要卷的那些 ≥ 记性长度的四分之一（按字估 token）。"""
    rolled = plan_roll(msgs).rolled
    return bool(rolled) and sum(estimate_tokens(m.text) for m in rolled) >= ROLL_MIN_SHARE * high_water


def plan_roll(msgs: list[StoredMsg], keep_count: int | None = None, keep_chars: int | None = None) -> RollPlan:
    """从尾巴往前留：keep_count 条或 keep_chars 字，先到为准；至少留最后一来一回；
    留下的第一条必须是用户说的（对话要从用户开口，才接得上）。"""
    keep_count = keep_count or KEEP_COUNT
    keep_chars = keep_chars or KEEP_CHARS
    n = chars = 0
    for m in reversed(msgs):
        if n >= keep_count or chars + len(m.text) > keep_chars:
            break
        n += 1
        chars += len(m.text)
    n = max(n, min(2, len(msgs)))
    start = len(msgs) - n
    while start < len(msgs) and msgs[start].role not in USER_SIDE:
        start += 1
    if start == len(msgs):
        users = [i for i, m in enumerate(msgs) if m.role in USER_SIDE]
        start = users[-1] if users else 0
    return RollPlan(rolled=msgs[:start], kept=msgs[start:])


# 积压（10-13 内测：中转不回 usage 的老版本，一个窗口积了 3000 多条没卷）：没卷的原文超过这么多字，开口前先分批卷。
# 平常卷账本时没卷的远到不了这个数，只有积压才会碰上；用户把记性长度调得很长时线跟着往上抬。
BACKLOG_CHARS = 150_000
BATCH_CHARS = 40_000             # 一批多少字：挑记忆那一步只看这一批，请求大小有上限


def backlog_batches(msgs: list[StoredMsg], high_water: int) -> list[list[StoredMsg]]:
    """积压太多时从最老的切成一批批（每批约 BATCH_CHARS 字、切在用户开口前），切到剩下的不超线为止；
    最后那一来一回（plan_roll 留下的）不动。没超线返回空——平常一批都没有。"""
    limit = max(BACKLOG_CHARS, 2 * high_water)
    total = sum(len(m.text) for m in msgs)
    if total <= limit:
        return []
    batches: list[list[StoredMsg]] = []
    cur: list[StoredMsg] = []
    chars = 0
    for m in plan_roll(msgs).rolled:
        if cur and chars >= BATCH_CHARS and m.role in USER_SIDE:
            batches.append(cur)
            total -= chars
            cur, chars = [], 0
            if total <= limit:
                return batches
        cur.append(m)
        chars += len(m.text)
    if cur:
        batches.append(cur)
    return batches


def voice_samples(rolled: list[StoredMsg]) -> list[str]:
    """去掉长得像的、从头到尾散着挑（10-13：原来取最后 6 句，恰是重复最凶的几句，DeepSeek 照抄一整轮）"""
    from .repeats import pick_samples
    return pick_samples([m.text[:SAMPLE_CHARS] for m in rolled if m.role == "assistant"], VOICE_SAMPLES)


def _grams(text: str) -> set[str]:
    g: set[str] = set()
    for run in _CJK_RUN.findall(text or ""):
        g.update(run[i:i + 2] for i in range(len(run) - 1))
    g.update(w.lower() for w in _WORD.findall(text or ""))
    return g


def quota_for_age(age: int, lang: str = "zh") -> int:
    q = DAY_QUOTAS[max(0, age)] if age < len(DAY_QUOTAS) else OLD_DAY_QUOTA
    return q * LANG_SCALE.get(lang, 1)


def entry_budget(chars: int, lang: str = "zh") -> int:
    """这一段新账该写多长：原文越长写越多，但有上下限。"""
    k = LANG_SCALE.get(lang, 1)
    return max(ENTRY_MIN * k, min(ENTRY_MAX * k, round(chars * ENTRY_RATIO)))


def over_quota(days: dict[date, str], today: date, lang: str) -> list[tuple[date, int, int]]:
    """哪些天超了天龄配额（×1.3 才算），返回 (日期, 天龄, 该压到多少字)。"""
    out = []
    for d in sorted(days):
        age = (today - d).days
        if age >= MAX_DAYS:
            continue
        quota = quota_for_age(age, lang)
        if len(days[d]) > quota * QUOTA_SLACK:
            out.append((d, age, quota))
    return out


def too_old(days: dict[date, str], today: date) -> list[date]:
    return [d for d in days if (today - d).days >= MAX_DAYS]


def join_text(a: str, b: str, lang: str) -> str:
    a, b = (a or "").strip(), (b or "").strip()
    if not a or not b:
        return a or b
    if re.search(r"[。！？!?…」』”）).]$", a):
        return a + b if lang == "zh" else f"{a} {b}"
    return f"{a}。{b}" if lang == "zh" else f"{a}. {b}"


def one_line(text: str, lang: str) -> str:
    """模型偶尔分行或带日期头；账本一天一段，收成一段、去掉日期头。"""
    text = _DATE_HEAD.sub("", (text or "").strip(), count=1)
    return re.sub(r"\s*\n+\s*", "" if lang == "zh" else " ", text).strip()


def day_transcripts(msgs: list[StoredMsg], tz: str, lang: str, user_name: str = "",
                    group: bool = False) -> dict[date, list[str]]:
    """按用户那边的日期拆开，每天拼成「[时:分] 我：……」的原文；一天太长就分几段（每段 ≤ CHUNK_CHARS）。"""
    z = ZoneInfo(tz)
    sep = "：" if lang == "zh" else ": "
    lines: dict[date, list[str]] = {}
    for m in msgs:
        t = m.created_at.astimezone(z)
        if m.role == "wake" and m.text.startswith(SILENT_DID[lang]):   # 醒来没找 TA、做了自己的事：照那一行记
            line = f"[{t:%H:%M}] （{m.text.removeprefix(SILENT_DID[lang]).strip()}）"
        elif m.role == "wake":            # 〔醒来〕整段不抄进账，只记一句「我自己醒来找 TA」
            line = f"[{t:%H:%M}] {WAKE_LINE[lang]}"
        else:
            who_said = (m.speaker_name or "TA") if group and m.role == "assistant" else \
                (who(user_name, lang, "Subj") if group else speaker(m.role, lang, user_name))   # 群账本每行写名字（10-11）
            line = f"[{t:%H:%M}] {who_said}{sep}{m.text}"
        lines.setdefault(t.date(), []).append(line[:CHUNK_CHARS])
    out: dict[date, list[str]] = {}
    for d, ls in lines.items():
        chunks, cur = [], ""
        for line in ls:
            if cur and len(cur) + 1 + len(line) > CHUNK_CHARS:
                chunks.append(cur)
                cur = ""
            cur = f"{cur}\n{line}" if cur else line
        chunks.append(cur)
        out[d] = chunks
    return out


def _hard(sent: str) -> list[str]:
    """「硬」事实：原文没有的名字和数字一出现，这句基本就是编的。
    中文句子里的英文词都算；英文句子里只算句中大写的词（名字）和数字，不然换个说法就被当成编造。"""
    if _CJK_RUN.search(sent):
        return _HARD.findall(sent)
    return _HARD_EN.findall(f" {sent[sent.find(' ') + 1:]}" if " " in sent else "") + \
        [x for x in _HARD.findall(sent.split(" ")[0]) if x[0].isdigit()]


def ground_text(text: str, source: str) -> str | None:
    """逐句回查原文。一句里的内容粒（中文二字组 + 英文词 / 数字）不到三成在原文里、或冒出原文没有的
    英文名和数字，这句就扔。扔掉超过一半 → 整段作废（返回 None），宁可不写，不进假账。"""
    src = _grams(source)
    src_hard = {h.lower() for h in _HARD.findall(source)}
    kept: list[str] = []
    total = dropped = 0
    for sent in (x.strip() for x in _SENT.split(text or "")):
        if not sent:
            continue
        g = _grams(sent)
        if not g:
            kept.append(sent)
            continue
        total += 1
        invented = [h for h in _hard(sent) if h.lower() not in src_hard]
        if len(g & src) / len(g) < MIN_RATIO or invented:
            dropped += 1
            continue
        kept.append(sent)
    if total == 0 or dropped / total > MAX_DROP:
        return None
    out = ""
    for sent in kept:
        out = sent if not out else out + ("" if re.search(r"[。！？；]$", out) else " ") + sent
    return out


def defect(text: str, max_len: int, name: str) -> str:
    """长度和人称的验收。合格返回空串，否则返回原因（记日志用）。"""
    if len(text) < 10:
        return f"{len(text)} 字，太短"
    if len(text) > max_len:
        return f"{len(text)} 字，超过 {max_len}"
    n = text.lower().count(name.lower()) if name else 0
    if n > NAME_LIMIT:
        return f"写了 {n} 次「{name}」，第三人称"
    return ""


_HOW_OLD = {"zh": lambda a: ("今天", "昨天", "前天")[a] if a < 3 else f"{a} 天前",
            "en": lambda a: ("today", "yesterday", "the day before yesterday")[a] if a < 3 else f"{a} days ago"}
_SYSTEM = {"zh": "你是一个精简的记账员。", "en": "You are a concise ledger keeper."}


def day_label(d: date, lang: str) -> str:
    return f"{d.month}月{d.day}日" if lang == "zh" else f"{d:%b} {d.day}"


WRITE = {
    "zh": """下面是{name}和{user}的一段对话，全部发生在 {day}。把它写成一段 {limit} 字以内的账，接在这一天已有的账后面。

【角色与人称】
- 全文用{name}的第一人称写：{name}一律写「我」，**不许出现「{name}」这个名字，也不许用「它」「他」「她」指{name}**。对方写「{user}」。
- 说话人只看每行开头的标签（「我：」是{name}，「{user}：」是对方），不按语气改判。

【写什么】
- 事实脉络：发生了什么、谁说了哪句关键的话、做了什么决定或约定、情绪在哪里转弯。
- 场景没结束就写停在哪一步。不抄原句，不写抒情和描写。
- 只写对话里真有的事，不续写，不补对话里没有的人名、数字、计划。
{tail}
【输出】一段中文正文，{limit} 字以内，不带日期、不分行、不加前言。

⟪对话开始⟫
{transcript}
⟪对话结束⟫

再说一遍：{limit} 字以内。""",
    "en": """Below is part of a conversation between {name} and {obj}, all on {day}. Write it up as one ledger paragraph of at most {limit} characters, to be appended to that day's existing ledger.

[Voice and person]
- Write in {name}'s first person: {name} is always "I". **Never write the name "{name}", and never call {name} "it", "he" or "she".** The other person is "{user}".
- Who said what is decided only by the label at the start of each line ("Me:" is {name}, "{label}:" is the other person), never by tone.

[What to write]
- The factual thread: what happened, the key lines and who said them, decisions or agreements made, where the mood turned.
- If a scene hasn't finished, say where it stopped. Don't quote lines verbatim; no lyrical description.
- Only what is in the conversation. Don't continue it, and don't add names, numbers or plans that aren't there.
{tail}
[Output] One paragraph of plain English, at most {limit} characters, no date, no line breaks, no preamble.

⟪conversation start⟫
{transcript}
⟪conversation end⟫

Once more: at most {limit} characters.""",
}
_WRITE_TAIL = {"zh": "- 这一天已有的账最后一句是：「{last}」——接着往下写，别重复。\n",
               "en": "- The day's ledger so far ends with: \"{last}\" — carry on from there, don't repeat it.\n"}

AGE = {
    "zh": {
        "head": "下面是{name}的账本里 {day}（{how_old}）这一天的记录。账里的「我」是{name}，「{user}」是对方。",
        "core": "【核心指令：对这段记录执行二次压缩】\n⚠️ 注意：这段记录不是最终成品，必须进行二次裁剪与重构，不能原样交回！",
        "old": ("- 大幅删除细节、原因和过程，只保留「主语 + 最终结果/决定」。\n"
                "  例：原句「因为吵架，{user}晚饭没吃去了公园」→ 压缩为「{user}没吃晚饭」。\n"
                "- 只留一两句：这一天最要紧的事或决定。"),
        "recent": ("- 删除过程和细节描写，保留原因、结果和情绪转折。\n"
                   "  例：原句「因为吵架，{user}晚饭没吃，一个人去了公园，回来眼睛是红的」→ 压缩为「吵架后{user}没吃晚饭去了公园，回来哭过」。\n"
                   "- 保留事实脉络和情绪转折，删掉细节描写、重复和抒情。"),
        "rest": """- 写成一段 {lo}～{quota} 字的新概要，替换掉原来的。

【角色与人称】
- 照原记录用第一人称：「我」还是「我」，**不许出现「{name}」这个名字，也不许用「它」「他」「她」指我**。对方写「{user}」。
- 谁说的、谁做的照原记录，不改判——「{user}夸我」不能写成「我夸{user}」。

【写什么】
- 只写原记录里真有的事，不补原记录没有的人名、数字、计划。不认识的名字照抄，不加括号注解、不猜。

【输出】一段中文正文，{lo}～{quota} 字（别写得比 {lo} 字短，细节是要留的），不带日期、不分行、不加前言。

⟪记录开始⟫
{text}
⟪记录结束⟫

再说一遍：{lo}～{quota} 字。""",
    },
    "en": {
        "head": "Below is the entry for {day} ({how_old}) from {name}'s ledger. \"I\" in it is {name}; \"{user}\" is the other person.",
        "core": "[Core instruction: compress this entry a second time]\n⚠️ Note: this entry is NOT a finished product. It must be cut down and rewritten — do not hand it back as it is!",
        "old": ("- Cut details, reasons and process hard; keep only \"who + final outcome/decision\".\n"
                "  e.g. \"After the argument {user} skipped dinner and went to the park\" → \"{User} skipped dinner\".\n"
                "- One or two sentences: the most important thing or decision of that day."),
        "recent": ("- Cut the process and descriptive detail; keep causes, outcomes and turns of mood.\n"
                   "  e.g. \"After the argument {user} skipped dinner, went to the park alone and came back with red eyes\" → "
                   "\"After the argument {user} skipped dinner, went to the park and came back having cried\".\n"
                   "- Keep the factual thread and turns of mood; drop description, repetition and lyricism."),
        "rest": """- Write one new summary paragraph of {lo}–{quota} characters to replace the old one.

[Voice and person]
- Keep the first person: "I" stays "I". **Never write the name "{name}", and never call me "it", "he" or "she".** The other person is "{user}".
- Keep who said and did what exactly as recorded — "{user} praised me" must not become "I praised {obj}".

[What to write]
- Only what is in the entry. Don't add names, numbers or plans that aren't there. Copy unknown names as they are; no guesses or notes in brackets.

[Output] One paragraph of plain English, {lo}–{quota} characters (not shorter than {lo} — details are meant to stay), no date, no line breaks, no preamble.

⟪entry start⟫
{text}
⟪entry end⟫

Once more: {lo}–{quota} characters.""",
    },
}


def _who_kw(user_name: str, lang: str) -> dict:
    return {"user": who(user_name, lang), "User": who(user_name, lang, "Subj"), "obj": who(user_name, lang, "obj"),
            "label": speaker("user", lang, user_name)}


def write_prompt(transcript: str, d: date, existing: str, *, name: str, lang: str,
                 user_name: str = "") -> tuple[str, int]:
    limit = entry_budget(len(transcript), lang)
    tail = _WRITE_TAIL[lang].format(last=existing[-120:]) if existing.strip() else ""
    return WRITE[lang].format(name=name, day=day_label(d, lang), limit=limit, tail=tail, transcript=transcript,
                              **_who_kw(user_name, lang)), limit


def age_prompt(text: str, d: date, age: int, quota: int, *, name: str, lang: str, user_name: str = "") -> str:
    """压旧天的要求（之前自用的 App 09-23 Aporia加的「二次压缩」）：flash 这类模型会把现成摘要当成品原样交回，
    点明「不是成品」、再给一句前后对照，它才知道砍到哪。三天前起只留「主语 + 结果」；近三天留原因和情绪。"""
    A, kw = AGE[lang], _who_kw(user_name, lang)
    return "\n".join([
        A["head"].format(name=name, day=day_label(d, lang), how_old=_HOW_OLD[lang](age), **kw), "",
        A["core"], (A["old"] if age >= 3 else A["recent"]).format(**kw),
        A["rest"].format(name=name, lo=round(quota * AGE_LO), quota=quota, text=text, **kw),
    ])


Spent = list[tuple[str, Usage]]


async def _short(adapter, models: list[str], prompt: str, source: str, max_len: int, *, name: str, lang: str,
                 label: str, user_name: str = "") -> tuple[str | None, Spent]:
    """账本短活：按顺序试每个模型，过了防编造、长度、人称三道验收就用；都不行返回 None。
    对方的名字算进原文里：旧账写的是「TA」、用户后来填了名字，压的时候写出名字不算编造。"""
    spent: Spent = []
    source = f"{source}\n{who(user_name, lang)}"
    for leg in models:
        a, model = leg if isinstance(leg, tuple) else (adapter, leg)     # 腿可以是别的钥匙（10-15 钥匙串分活）
        req = ChatRequest(model=model, system=[Block(_SYSTEM[lang])], messages=[Msg("user", prompt)],
                          max_tokens=4000, thinking=False)
        try:
            reply = await call(a, req)
        except LLMError as e:
            log.warning("ledger %s via %s failed: %s", label, model, e)
            continue
        spent.append((model, reply.usage))
        text = ground_text(one_line(reply.text, lang), source)
        why = "编造太多，整段作废" if text is None else defect(text, max_len, name)
        if not why:
            return text, spent
        log.warning("ledger %s via %s rejected: %s", label, model, why)
    return None, spent


async def write_entry(adapter, models: list[str], transcript: str, d: date, existing: str, *,
                      name: str, lang: str, user_name: str = "", group: str | None = None) -> tuple[str | None, Spent]:
    """一天（的一段）原文 → 一小段新账，接在那天已有的账后面。模型看不到旧账，只看得到最后一句。
    group = 群名（10-11 群账本）：每个人都写名字，不查「名字写太多次」那道人称闸。"""
    if group is not None:
        prompt, limit = group_write_prompt(transcript, d, existing, group=group, lang=lang)
        return await _short(adapter, models, prompt, f"{transcript}\n{existing}", round(limit * 1.5),
                            name="", lang=lang, label=f"group write {d}", user_name=user_name)
    prompt, limit = write_prompt(transcript, d, existing, name=name, lang=lang, user_name=user_name)
    return await _short(adapter, models, prompt, f"{transcript}\n{existing}", round(limit * 1.5),
                        name=name, lang=lang, label=f"write {d}", user_name=user_name)


# ── 群账本（10-11，跟 Lite 的 LocalEcho.groupWritePrompt / groupAgePrompt 同一份文案） ──

def group_write_prompt(transcript: str, d: date, existing: str, *, group: str, lang: str) -> tuple[str, int]:
    limit = entry_budget(len(transcript), lang)
    last = existing[-120:]
    if lang == "zh":
        tail = f"- 这一天已有的账最后一句是：「{last}」——接着往下写，别重复。\n" if existing.strip() else ""
        return (f"下面是群「{group}」里的一段聊天，全部发生在 {day_label(d, lang)}。把它写成一段 {limit} 字以内的账，接在这一天已有的账后面。\n\n"
                "【人称】\n- 每个人都写名字，不用「我」「你」。说话人只看每行开头的名字，不按语气改判。\n\n"
                "【写什么】\n- 事实脉络：发生了什么、谁说了哪句关键的话、谁跟谁接了话或拌了嘴、做了什么决定或约定、情绪在哪里转弯。\n"
                "- 不抄原句，不写抒情和描写。只写聊天里真有的事，不续写，不补没有的人名、数字、计划。\n"
                f"{tail}\n【输出】一段中文正文，{limit} 字以内，不带日期、不分行、不加前言。\n\n"
                f"⟪聊天开始⟫\n{transcript}\n⟪聊天结束⟫\n\n再说一遍：{limit} 字以内。"), limit
    tail = f"- The day's ledger so far ends with: \"{last}\" — carry on from there, don't repeat it.\n" if existing.strip() else ""
    return (f"Below is part of a chat in the group \"{group}\", all on {day_label(d, lang)}. Write it up as one ledger paragraph of at most {limit} characters, to be appended to that day's existing ledger.\n\n"
            "[Names]\n- Name everyone; never use \"I\" or \"you\". Who said what is decided only by the name at the start of each line, never by tone.\n\n"
            "[What to write]\n- The factual thread: what happened, the key lines and who said them, who replied to or teased whom, decisions made, where the mood turned.\n"
            "- Don't quote lines verbatim; no lyrical description. Only what is in the chat — don't continue it or add names, numbers or plans that aren't there.\n"
            f"{tail}\n[Output] One paragraph of plain English, at most {limit} characters, no date, no line breaks, no preamble.\n\n"
            f"⟪chat start⟫\n{transcript}\n⟪chat end⟫\n\nOnce more: at most {limit} characters."), limit


def group_age_prompt(text: str, d: date, age: int, quota: int, *, group: str, lang: str) -> str:
    lo = round(quota * AGE_LO)
    how_old = _HOW_OLD[lang](age)
    if lang == "zh":
        how = "- 大幅删除细节、原因和过程，只留一两句：这一天群里最要紧的事。" if age >= 3 else "- 删除过程和细节描写，保留原因、结果和情绪转折。"
        return (f"下面是群「{group}」账本里 {day_label(d, lang)}（{how_old}）这一天的记录，账里每个人都写名字。\n\n"
                "【核心指令：对这段记录执行二次压缩】\n⚠️ 注意：这段记录不是最终成品，必须进行二次裁剪与重构，不能原样交回！\n"
                f"{how}\n- 写成一段 {lo}～{quota} 字的新概要，替换掉原来的。\n"
                "- 照原记录写名字，不用「我」「你」；谁说的、谁做的照原记录，不改判。只写原记录里真有的事。\n\n"
                f"【输出】一段中文正文，{lo}～{quota} 字，不带日期、不分行、不加前言。\n\n"
                f"⟪记录开始⟫\n{text}\n⟪记录结束⟫\n\n再说一遍：{lo}～{quota} 字。")
    how = ("- Cut details, reasons and process hard; keep one or two sentences: the most important thing in the group that day."
           if age >= 3 else "- Cut the process and descriptive detail; keep causes, outcomes and turns of mood.")
    return (f"Below is the entry for {day_label(d, lang)} ({how_old}) from the ledger of the group \"{group}\". Everyone in it is named.\n\n"
            "[Core instruction: compress this entry a second time]\n⚠️ Note: this entry is NOT a finished product. It must be cut down and rewritten — do not hand it back as it is!\n"
            f"{how}\n- Write one new summary paragraph of {lo}–{quota} characters to replace the old one.\n"
            "- Keep everyone named, never \"I\" or \"you\"; keep who said and did what exactly as recorded. Only what is in the entry.\n\n"
            f"[Output] One paragraph of plain English, {lo}–{quota} characters, no date, no line breaks, no preamble.\n\n"
            f"⟪entry start⟫\n{text}\n⟪entry end⟫\n\nOnce more: {lo}–{quota} characters.")


_GROUP_HEAD = {"zh": "〔群账本〕群里更早的聊天，远的模糊、近的清楚（账里都写名字，「{me}」就是你）：",
               "en": "〔Group ledger〕Earlier in this group — older is hazier, recent is clearer (everyone is named; \"{me}\" is you):"}


def render_group_ledger(days: dict[date, str], lang: str, me: str) -> str:
    body = render_days(days)
    return f"{_GROUP_HEAD[lang].format(me=me)}\n{body}" if body else ""


def pieces(text: str, size: int) -> list[str]:
    """按句子切成每块不超过 size 字的小块（一句本身超长就单独一块）。"""
    out, cur = [], ""
    for sent in re.split(r"(?<=[。！？!?；;])|(?<=[.])\s+", text):
        if not sent:
            continue
        if cur and len(cur) + len(sent) > size:
            out.append(cur)
            cur = ""
        cur = cur + sent if not cur or re.search(r"[。！？；]$", cur) else f"{cur} {sent}"
    if cur:
        out.append(cur)
    return out


async def age_day(adapter, models: list[str], text: str, d: date, age: int, quota: int, *,
                  name: str, lang: str, user_name: str = "", group: str | None = None) -> tuple[str | None, Spent]:
    """把超了配额的一天压短。没压短（照抄交回）也算压不动，返回 None，留着下次卷的时候再试。
    模型清单里标了 age_piece 的（DeepSeek：一大段压不动、小段压得动），长的一天先切块，各压到按长度分的那份配额。"""
    first = models[0][1] if isinstance(models[0], tuple) else models[0]
    info = lookup(first)
    size = info.age_piece if info else None
    if not size or len(text) <= size:
        prompt = group_age_prompt(text, d, age, quota, group=group, lang=lang) if group is not None else \
            age_prompt(text, d, age, quota, name=name, lang=lang, user_name=user_name)
        short, spent = await _short(adapter, models, prompt, text, quota * 2, name="" if group is not None else name, lang=lang,
                                    label=f"age {d}", user_name=user_name)
    else:
        short, spent = "", []
        floor = PIECE_MIN_QUOTA * LANG_SCALE.get(lang, 1)
        for i, part in enumerate(pieces(text, size)):
            q = max(floor, round(quota * PIECE_AIM * len(part) / len(text)))
            prompt = group_age_prompt(part, d, age, q, group=group, lang=lang) if group is not None else \
                age_prompt(part, d, age, q, name=name, lang=lang, user_name=user_name)
            got, s = await _short(adapter, models, prompt, part, max(q * 2, len(part) - 1),
                                  name="" if group is not None else name, lang=lang,
                                  label=f"age {d} #{i + 1}", user_name=user_name)   # 小块比原来短就收：整天拼起来超了，下次卷再压
            spent += s
            short = join_text(short, got if got is not None else part, lang)   # 这块压不动就原样留着
    if short is not None and len(short) < len(text):
        return short, spent
    return None, spent


def render_days(days: dict[date, str]) -> str:
    return "\n".join(f"## {d.isoformat()}\n{days[d]}" for d in sorted(days) if days[d].strip())


def render_ledger(days: dict[date, str], samples: list[str], lang: str, user_name: str = "") -> str:
    out: list[str] = []
    body = render_days(days)
    if body:
        out += [_LEDGER_HEAD[lang].format(user=who(user_name, lang)), body]
    if samples:
        out.append(_SAMPLES_HEAD[lang])
        out += [f"- 「{s}」" for s in samples]
    return "\n".join(out)


def _snip(text: str, n: int = 20) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[:n] + "…"


def pick_prompt(rolled: list[StoredMsg], lang: str) -> str:
    return PICK[lang].format(first=_snip(rolled[0].text), last=_snip(rolled[-1].text))
