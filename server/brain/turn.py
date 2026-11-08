"""一轮对话：大脑的主流程（设计文档第一段「一轮对话」）。

  存下这句 → 想起相关的记忆和人物卡 → 按缓存顺序拼上下文 → 调模型（带工具循环，最多 8 次）
  → 写完再均匀切成气泡，一条一条推 → 存档、记账 → 上下文满了就卷账本

所有外部的东西（数据库、向量、钥匙、模型接头、时间、等待、骰子）都从 Deps 进来，测试时全换成假的。
记忆服务出错不让这一轮失败：这一轮不带记忆照常回话（设计文档「出错时」）。"""
from __future__ import annotations

import asyncio
import time
import base64
import hashlib
import inspect
import logging
import random
from dataclasses import asdict, dataclass, field, replace
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable
from uuid import UUID, uuid5
from zoneinfo import ZoneInfo

import memory as M
from llm.catalog import DEFAULT_HIGH_WATER, cost, lookup, sees_images
from llm.errors import LLMError, context_full
from llm.router import Route, call, make_adapter
from llm.types import ChatRequest, ImagePart, Msg, ToolCall, ToolRound, Usage

from . import markers, stickers as ST
from . import archive, attachments as files, books, context_line, diary, drawer, far_dates, focus, hidden, ledger, lore, mcp, media, probe as sentinel, reactions, tarot, vision, voice, wallet
from .judge import LLMJudge
from .bubbles import split_reply, typing_delay
from . import chores, repeats
from . import moments as MO
from .context import ContextParts, build_request, render_volatile, user_tag
from . import inner_voice, monologue
from . import call_speech
from .call_speech import CallCtx, CallCut
from . import bilingual, group as G, groups, model_noise, timeline
from .inject import TEXTS, TurnFacts, reminder_lines, split_thinking, thinking_style
from .scope import Scope
from .persona import Persona, render_base, tone_lines
from .settings import Settings
from . import edits, keepalive
from food import store as food_store
from music import ears

from .auth import TrialOver, charge_trial
from .edits import EditRef
from .tools import INCOGNITO_TOOLS, ToolContext, act_on_markers, run_tool, tool_note, tool_specs
from .wake_text import SILENT_DID, monologue_note, silent_note, split_silent

log = logging.getLogger(__name__)

TOOL_ROUNDS_MAX = 8
LEDGER_FAIL_WARN = 3
Emit = Callable[[dict], Awaitable[None]]

USER_ERRORS = {
    "zh": {"auth": "模型的 key 好像不对，去设置里检查一下。",
           "balance": "模型那边的余额不够了，充值以后再来找我。",
           "model": "设置里的模型名找不到，检查一下拼写。",
           "not_chat": "这把钥匙填的模型不能拿来聊天（像 gpt-image-1 这种画图模型，或者只支持新接口的 o1-pro / codex）。给 TA 换一个聊天模型；想让 TA 画图，在钥匙串里给一把钥匙勾「画图」。",
           "rate": "模型那边太忙了，等一会儿再试。",
           "overloaded": "模型那边太忙了，等一会儿再试。",
           "network": "连不上模型，检查一下网络。",
           "bad_request": "这次请求被模型拒了，稍后再试试。",
           "too_long": "这段聊天太长，模型装不下了。前面的已经卷进账本，再发一次就好。",
           "other": "模型那边出了点问题，稍后再试。",
           "trial_over": "今天的免费额度用完啦，明早 5 点会补一些。加一个自己的 key，或者成为会员，就不用等——之前聊的、我记下的都还在。"},
    "en": {"auth": "The model key doesn't seem right — check it in Settings.",
           "balance": "The model account is out of credit. Top it up and come back.",
           "model": "The model name in Settings wasn't found — check the spelling.",
           "not_chat": "The model on this key can't chat (an image model like gpt-image-1, or one that only works on the newer API like o1-pro / codex). Give them a chat model; to let them draw, tick \"Draw\" on a key in Keys.",
           "rate": "The model is busy right now. Try again in a moment.",
           "overloaded": "The model is busy right now. Try again in a moment.",
           "network": "Can't reach the model — check the connection.",
           "bad_request": "The model rejected this request. Try again later.",
           "too_long": "This chat got too long for the model. The earlier part is now in the ledger — send it again.",
           "other": "Something went wrong on the model's side. Try again later.",
           "trial_over": "Today's free allowance is used up — a little more comes back at 5 am. Add your own key or become a member to skip the wait — everything we said and everything I remembered is still here."},
}
DRAW_NOTICE = {"zh": "TA 现在还不会画图：去 Me →「看图和画图」填一把画图钥匙（Gemini、OpenAI 或中转站），填了所有 TA 都能画。",
               "en": "They can't draw yet: add a drawing key (Gemini, OpenAI or a relay) in Me → \"Seeing & drawing\" — then every companion can draw."}
LAST_ROUND_NOTE = {"zh": "\n（这一轮能调工具的次数用完了，接下来直接回话。）",
                   "en": "\n(That was the last tool call allowed this turn — reply directly now.)"}
LEDGER_NOTICE = {"zh": "账本最近几次都没写成功，旧的对话先原样留着，只是每轮会贵一点。可以在设置里换一个写账本的模型。",
                 "en": "The ledger hasn't been written the last few times. Older messages stay as they are for now, "
                       "which makes each turn a bit more expensive. You can pick another ledger model in Settings."}


@dataclass
class Deps:
    pool: object
    embedder: object
    keys: object                                    # 有 route_for(user_id) -> Route
    adapter_for: Callable[[Route], object] = make_adapter
    reranker: object = None
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)
    sentinel: bool = False       # 召回哨兵的总闸：正式接口和测试台开（api/web 的 __main__）；测试默认关，免得吃掉假模型的剧本
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep
    rng: random.Random = field(default_factory=random.Random)
    caption_route: Route | None = None              # 我们的看图模型：用户的模型看不见图、钥匙串里也没有会看图的 key 时用
    probe_keys: bool = False     # 加钥匙前先拿它试打一次（正式接口开；测试默认关，免得吃掉假模型的剧本）
    adapters: dict = field(default_factory=dict)
    off_get: object = None       # 查营养（Open Food Facts）的传输；空 = 真联网，测试里换假的（09-29）
    music: object = None         # music.apple.AppleMusic；没配 MusicKit 钥匙 = None（09-30）
    ears: object = None          # music.ears.Transport：Lumi 的耳朵（下载 / 解码 / 量 / 歌词 / Gemini）；None = 不去听（测试默认）
    tts_for: Callable[[str], object] | None = None   # 声音（10-03）：给一把 ElevenLabs key 返回接头；None = 没有声音
    tts_key: str = ""            # 我们的 ElevenLabs key（NEWAPP_ELEVENLABS_KEY）；空 = 只有自带 key 的人能用
    minimax_for: Callable[[str, str], object] | None = None   # MiniMax（11-08）：给 (key, 接口地址) 返回接头；None = 真的 llm.tts.MiniMax
    files_dir: Path | None = None   # 语音存哪（接口启动时填 ApiConfig.files_dir）
    ringer: object = None        # TA 打给你（10-31，brain/call_ring.Ringer）：接口启动时填；None = 没有打电话工具


GAP_MIN = 30          # 隔了多少分钟才提


def gap_note(gap, now: datetime, tz: str, lang: str) -> str:
    """她隔了 30 分钟以上才发这一句：告诉它过了多久、现在几点（10-20 内测：DeepSeek 两小时后还接着上一个话头）。跟 Lite gapLine 同一个"""
    mins = int(gap.total_seconds() // 60)
    if mins < GAP_MIN:
        return ""
    h, m = divmod(mins, 60)
    clock = now.astimezone(ZoneInfo(tz)).strftime("%H:%M")
    if lang == "zh":
        span = f"{h} 小时 {m} 分" if h and m else (f"{h} 小时" if h else f"{m} 分钟")
        return f"〔这一句是隔了 {span} 才发来的，现在 {clock}；之前聊的是 {span} 前的事了，这一轮接的是这一句〕"
    span = f"{h} h {m} min" if h and m else (f"{h} h" if h else f"{m} min")
    return f"[This message came {span} after the last one; it's now {clock}. What you talked about before was {span} ago — answer this one.]"



def get_adapter(deps: Deps, route: Route):
    key = (route.provider, route.base_url, route.api_key)
    if key not in deps.adapters:
        deps.adapters[key] = deps.adapter_for(route)
    return deps.adapters[key]


@dataclass
class TurnOutcome:
    said: bool                   # 它这一轮说了话（醒来时回 <silent> 就是 False）
    cost_usd: float = 0.0
    error: str | None = None     # 模型报错的种类 / trial_over


@dataclass
class LoopResult:
    text: str
    thinking: str
    usage: Usage
    tools_used: list[str]
    last_prompt: int
    tool_notes: list[str] = field(default_factory=list)   # 用过的工具，一行一个，存进存档给下一轮看
    cards: list[dict] = field(default_factory=list)       # 挂出来给 TA 看的动作卡片，跟回复一起存


async def tool_loop(adapter, req: ChatRequest, ctx: ToolContext, emit: Emit, lang: str,
                    max_rounds: int = TOOL_ROUNDS_MAX, untagged: str = "", retag: bool = False,
                    phone: CallCtx | None = None) -> LoopResult:
    """调模型；它要调工具就执行、把结果还给它、接着调。看的是回复里有没有工具请求，不看它自报的停下原因。
    最多 max_rounds 个来回：最后一个来回的结果里告诉它「次数用完了」，再调一次就收尾。"""
    total = Usage()
    thinking: list[str] = []
    used: list[str] = []
    notes: list[str] = []
    retried = False                          # 只写了独白没写正文的，再叫一次（只一次）
    retagged = False                         # 没打 [独白] 标记的，重写一次（只一次；设置里开了才做）
    tagged = False                           # 这一轮里哪一段写过标记（调工具前写过也算）
    shown: set[tuple[str, str]] = set()      # 一轮里同样的卡只挂一张（翻了好几回记忆 → 一张「翻了些记忆」）
    cards: list[dict] = []
    for round_no in range(max_rounds + 1):
        reply = await call(adapter, req)
        total = total + reply.usage
        if phone is not None:
            phone.flush()                    # 电话：调工具前那句「等我查一下」先念出来（10-31）
        tagged = tagged or monologue.has_tag(reply.text)
        if (retag and untagged and not reply.tool_calls and not tagged and not retagged and round_no < max_rounds):
            # 10-26 Aporia：没打标记就得猜哪段是心里话，猜错了要么漏进气泡、要么把正文吞进思考。设置里开了就不猜，
            # 补一句提醒再叫一次（这次的整段不留）；第二次还没打就照常猜
            retagged = True
            last = req.messages[-1]
            req.messages[-1] = replace(last, text=f"{last.text}\n\n{NO_TAG_NOTE[lang]}")
            continue
        if reply.thinking.strip():
            thinking.append(reply.thinking.strip())
        mono, said = monologue.split_monologue(reply.text)    # 手写独白：切下来当思考链；调工具前那一段也要切
        if untagged:     # 没写标记、心里话混进正文开头（10-16）；写了 [独白] 后面又接一段没标记的心里话也算（10-20）
            more, rest = monologue.recover_untagged(said, untagged, lang == "zh")
            if more:
                mono, said = "\n\n".join(x for x in (mono, more) if x), rest
        if mono:
            thinking.append(mono)
        if not reply.tool_calls:
            # 没走工具接口、把调用写成了文字（10-15 内测：<function_calls><invoke name="memory_recall">… 原样进了气泡）：
            # 文字删掉；是它有的工具就替它调，结果贴在 TA 那句后面再叫一次（三家都能这么接，不用伪造工具来回）
            found, said = model_noise.text_tool_calls(said)
            known = {t.name for t in req.tools}
            found = [(n, a) for n, a in found if n in known]
            if found and round_no < max_rounds:
                lines = []
                for i, (name, args) in enumerate(found):
                    c = ToolCall(f"text_call_{round_no}_{i}", name, args)
                    r = await run_tool(ctx, c)
                    lines.append(f"{name} → {r}")
                    used.append(name)
                    notes.append(tool_note(name, args, r, lang))
                last = req.messages[-1]
                req.messages[-1] = replace(last, text=f"{last.text}\n\n{TEXT_CALL_NOTE[lang].format(chr(10).join(lines))}")
                continue
        if not reply.tool_calls and mono and not said and not retried and round_no < max_rounds:
            # 09-27 深夜：它写了一小段独白就停了，正文空的。补一句提醒再叫一次；第一次那段独白不留（第二次会重写）
            retried = True
            thinking.pop()
            last = req.messages[-1]
            req.messages[-1] = replace(last, text=f"{last.text}\n\n{MONO_ONLY_NOTE[lang]}")
            continue
        if not reply.tool_calls or round_no == max_rounds:
            # 对方没报用量（有的中转不回 usage）就按字数估：不然水位永远是 0，账本永远不卷，越聊越贵（10-13 内测）
            last_prompt = reply.usage.prompt_total or req.estimated_prompt()
            return LoopResult(said, "\n\n".join(thinking), total, used, last_prompt, notes, cards)
        results = []
        for c in reply.tool_calls:
            before = len(ctx.cards)
            results.append(await run_tool(ctx, c))
            used.append(c.name)
            notes.append(tool_note(c.name, c.args, results[-1], lang))
            for card in ctx.cards[before:]:
                if (card.kind, card.text) in shown:
                    continue
                shown.add((card.kind, card.text))
                if not card.private:
                    cards.append({"kind": card.kind, "text": card.text, **({"data": card.data} if card.data else {})})
                await emit({"type": "card", "kind": card.kind, "text": card.text, "private": card.private,
                            **({"data": card.data} if card.data else {})})
                if card.kind == "relationship":       # 卡不挂，但手机要知道：名字旁边的图标换一下（09-29）
                    await emit({"type": "relationship", "to": (card.data or {}).get("to", "")})
        if ctx.end_turn:                         # 打了电话、在响（10-31）：这一轮到此为止，等 TA 接
            return LoopResult(said, "\n\n".join(thinking), total, used, reply.usage.prompt_total or req.estimated_prompt(),
                              notes, cards)
        if round_no == max_rounds - 1:
            results = [r + LAST_ROUND_NOTE[lang] for r in results]
        req.rounds.append(ToolRound(reply.raw_assistant, list(reply.tool_calls), results))
    raise AssertionError("unreachable")


NO_TAG_NOTE = {"zh": "（你刚才没写 [独白]…[/独白] 就直接回了。重写一遍：最前面先把心里话写在 [独白] 和 [/独白] 之间，收好尾，再写正文。）",
               "en": "(You replied without the [monologue]…[/monologue] part. Write it again: start with your thoughts between [monologue] and [/monologue], close it, then the reply.)"}

MONO_ONLY_NOTE = {"zh": "（你刚才只写了独白就停了，没写正文。独白照常写，写完一定接着写正文。）",
                  "en": "(Last time you wrote only the monologue and stopped. Write the monologue as usual, then always go on to the reply.)"}

TEXT_CALL_NOTE = {"zh": "（你刚才把工具调用写成了文字，替你调了：\n{}\n以后直接用工具，别写进回复里。现在接着回话。）",
                  "en": "(You wrote a tool call as text; it was run for you:\n{}\nUse the tools directly next time instead of writing them into the reply. Now go on with your reply.)"}

TOOLS_HEAD = {"zh": "〔上一轮你用过：{}〕", "en": "〔Last turn you used: {}〕"}


def history_msgs(stored: list[archive.StoredMsg], lang: str) -> tuple[list[Msg], str]:
    """存档 → 历史。它说的话后面要是用过工具，就在紧接着的那句用户的话前面加一行〔上一轮你用过：…〕
    （09-27：它看不见以前的工具调用，每轮都以为还没记、又记一遍）。放在用户那一侧，它不容易学着在回话里写；
    每次都从存档原样生成，历史逐字节不变，缓存接得上。返回 (历史, 还没着落的那行)——最后一轮的那行给这一轮的用户话。"""
    sep = "、" if lang == "zh" else "; "
    out: list[Msg] = []
    pending = ""
    for m in stored:
        if m.role in archive.USER_SIDE:
            # 双语气泡（10-15）：你那句翻好了就给它看翻好的那版
            said = bilingual.user_side(m.text, m.translations)
            if m.call and not m.call.get("end") and not m.call.get("ring"):   # 电话里说的（10-31）；挂断、未接那条正文就是纸条
                said = call_speech.tag(lang) + said
            text = with_tools_note(pending, said)
            if out and out[-1].role == "user" and _silent_did(out[-1].text):   # 醒来没说话留的那条后面接着的：并成一段
                out[-1] = replace(out[-1], text=f"{out[-1].text}\n\n{text}")
            else:
                out.append(Msg("user", text))
            pending = ""
        else:
            text = model_noise.unsilence(m.text)
            if m.inner_voice:                 # 心声（10-11）：它记得当时心里想什么，但分得清那不是说出口的
                text = f"{text}\n\n{inner_voice.context_line(m.inner_voice, lang)}"
            if m.call and m.call.get("cut"):  # 电话里念到一半被打断（10-31）
                text = f"{text}\n{call_speech.cut_note(lang)}"
            out.append(Msg("assistant", text))
            pending = TOOLS_HEAD[lang].format(sep.join(m.tools.splitlines())) if m.tools.strip() else ""
    return out, pending


def fold_tail(hist: list[Msg], text: str) -> tuple[list[Msg], str]:
    """历史最后一条是用户那侧的：拿下来接在这一轮的话前面（10-30：醒来没说话、做了自己的事留的那条）。"""
    if hist and hist[-1].role == "user" and not hist[-1].images and _silent_did(hist[-1].text):
        return hist[:-1], f"{hist[-1].text}\n\n{text}" if text else hist[-1].text
    return hist, text


def _silent_did(text: str) -> bool:
    return any(head in text for head in SILENT_DID.values())


def with_tools_note(note: str, text: str) -> str:
    return f"{note}\n{text}" if note else text


async def resolve_route(keys, scope: Scope, chore: str | None = None) -> Route:
    """这一轮走哪把钥匙：正式的钥匙串按联系人找（DbKeys.route_for_scope，可能是试用钥匙）；本机测试的 FileKeys 按账号。
    chore = 后台哪样活（10-15 钥匙串分活）：勾了钥匙就用那把，没勾照旧。"""
    if chore:
        f = getattr(keys, "route_for_chore", None)
        if f is not None and (picked := await f(scope, chore)) is not None:
            return picked
    f = getattr(keys, "route_for_scope", None)
    r = f(scope) if f else keys.route_for(scope.account)
    return await r if inspect.isawaitable(r) else r


_PRONOUN = __import__("re").compile(r"[它他她那这]|\b(it|he|she|they|that|there)\b", __import__("re").I)


def _recent_lines(settings: Settings, persona, history) -> list[str]:
    """最近三句，给哨兵和判读器看：「名字：原话」。"""
    who = settings.user_name or ("TA" if settings.lang == "zh" else "Them")
    return [f"{who if m.role in archive.USER_SIDE else persona.name}：{m.text}" for m in history[-3:] if m.text.strip()]


async def _probe(deps: Deps, scope: Scope, route: Route, settings: Settings, persona, history, text: str, day,
                 now: datetime):
    """召回哨兵（09-28）：先听懂这句再去搜。纯寒暄不跑（省钱）；带代词、「上次」的短句照跑。
    用这把钥匙的便宜模型（账本那个），花的钱记到账号上。出错返回 None，召回照原句。"""
    t = (text or "").strip()
    if not t or not (M.worth_recalling(t) or sentinel.forced(t) or _PRONOUN.search(t)):
        return None
    recent = _recent_lines(settings, persona, history)
    model = route.ledger_model or route.chat_model
    got = await _safe(sentinel.probe(get_adapter(deps, route), model, t, recent, lang=settings.lang, today=day), None)
    if got is not None and got.usage is not None:
        await _safe(archive.add_usage(deps.pool, scope.account, day, model, got.usage, cost(got.usage, model)), None)
    return got


async def _safe(coro, default):
    try:
        return await coro
    except Exception:
        log.exception("memory service call failed; this turn goes without it")
        return default


async def _account(pool, user_id: UUID, day: date, model: str, usage: Usage) -> None:
    await archive.add_usage(pool, user_id, day, model, usage, cost(usage, model))


def now_and_then(state: dict, name: str, content: str, now: datetime, *, wake: bool) -> str:
    """会变的东西别每轮都给（09-30 Aporia）：变了才给、隔两小时再给、醒来时给——跟〔TA 那边〕一个规矩。
    state 里记上次给的时间和内容指纹；空的不给也不记。"""
    if not content.strip():
        return ""
    key = hashlib.sha1(content.encode()).hexdigest()[:12]
    last_at, last_key = state.get(f"{name}_at"), state.get(f"{name}_key")
    if not (wake or not last_at or last_key != key or now - datetime.fromisoformat(last_at) >= context_line.RESHOW):
        return ""
    state[f"{name}_at"], state[f"{name}_key"] = now.isoformat(), key
    return content


# ── 群聊（10-11，跟 Lite 的 LocalBrain.runTurn(group:) 同义） ──

GROUP_TOOLS = ("memory_remember", "memory_search", "note_about_user", "read_manual")   # 群里第一步只开记忆那几样
YOUR_TURN = {"zh": "（轮到你了）", "en": "(Your turn.)"}


@dataclass(frozen=True)
class GroupCtx:
    """群里这一轮的背景：scope.companion 是说话的那个 TA，scope.conversation 是群"""
    name: str                          # 群名（显示用）
    others: tuple[str, ...]            # 别的成员名字
    user_msg: int | None = None        # 这一串从用户哪句开始（倒回时撤它写过的记忆）
    joined_at: datetime | None = None  # 后来拉进来的才有
    sees_history: bool = True          # 新成员看不看得到进群前的


def user_label(settings: Settings, lang: str) -> str:
    """你在群里 / 别的房间里的称呼：设定里的名字，没有就用代词"""
    if settings.user_name:
        return settings.user_name
    zh = lang == "zh"
    return {"she": "她" if zh else "her", "he": "他" if zh else "him"}.get(settings.user_pronoun, "TA" if zh else "them")


def group_history(stored: list[archive.StoredMsg], me: UUID, g: GroupCtx, user: str, lang: str) -> list[archive.StoredMsg]:
    """群消息 → 这个 TA 看到的历史：只有它自己说的算 assistant；你和别的 TA 说的是 user，前面垫〔名字〕，
    别人的心声 / 思考 / 用过的工具不进。后来拉进来的：开关开着看进群前最近 30 条（还没开过口就垫一句），关着只看进群以后的"""
    if g.joined_at is not None:
        before = [m for m in stored if m.created_at < g.joined_at]
        after = [m for m in stored if m.created_at >= g.joined_at]
        if not g.sees_history:
            stored = after
        elif before:
            kept = before[-groups.HISTORY_ON_JOIN:]
            stored = kept + after
            if not any(m.role == "assistant" and m.speaker == me for m in after):
                note = archive.StoredMsg(-1, "user", G.join_note(lang == "zh"), "", g.joined_at)
                stored = kept + [note] + after
    out = []
    for m in stored:
        if m.role == "assistant" and m.speaker not in (None, me):
            out.append(replace(m, role="user", text=G.label(m.speaker_name or "TA") + m.text, thinking="", tools="",
                               inner_voice=""))
        elif m.role == "user" and m.id != -1:
            out.append(replace(m, text=G.label(user) + m.text))
        else:
            out.append(m)
    return out


def squash(msgs: list[Msg]) -> list[Msg]:
    """同一方连着的几条并成一段（插了别的房间 / 群里好几个人说话时才会连着）"""
    out: list[Msg] = []
    for m in msgs:
        if out and out[-1].role == m.role and not out[-1].images and not m.images:
            out[-1] = replace(out[-1], text=f"{out[-1].text}\n\n{m.text}")
        else:
            out.append(m)
    return out


async def run_turn(deps: Deps, scope: Scope | UUID, text: str, emit: Emit, *, resend: bool = False,
                   wake: str | None = None, attachments: list | None = None,
                   pieces: list[str] | None = None, free_trial: bool = False, quiet_food: bool = False,
                   group: GroupCtx | None = None, call: CallCtx | None = None, aside: str | None = None,
                   variants: list[str] | None = None) -> TurnOutcome:
    """scope = 这一轮在谁的名下（brain/scope.py）：设置、人设、记忆归联系人，聊天、账本、状态归窗口，用量归账号。
    resend = 重新生成：用户那句已经在存档最后了（刚撤掉了它的回复），不再存一遍，直接再回一次。
    wake = 它自己醒来（巡逻）：这段〔醒来〕代替用户的话。它想事时的动静先压着，回 <silent> 就全丢、什么都不存；
    开口了才把压着的放出去，〔醒来〕存成 wake 角色、回复照常存。醒来时出错不推给用户，交给巡逻记账。
    pieces = 等候区拼成 text 之前的那几句，跟着存下来，app 按它还原成几个气泡。
    free_trial = 这一轮不扣免费额度（初见那一轮，09-28）。
    quiet_food = 这一轮不给〔饮食〕那行（记一餐说一句，09-30：不让它看见热量；那几条留到下一轮再告诉它）。
    aside = 递给它的一句旁白、不存成用户说的话（10-31：TA 打来的电话接通了，它先开口）。"""
    scope = Scope.of(scope)
    acc, comp, conv = scope.account, scope.companion, scope.conversation
    real_emit, held = emit, []
    if wake:
        async def emit(ev: dict) -> None:        # noqa: F811 —— 醒来时先压着
            held.append(ev)
    pool = deps.pool
    now = deps.now()
    settings = Settings.from_dict(await archive.get_settings(pool, comp))
    if call is not None:         # 电话（10-31）：不想事、不写长文 / 心声 / 双语 / 语音条，开口要快
        settings = replace(settings, thinking=False, long_mode=False, inner_voice=False, bilingual=False, voice_mode="off")
    if settings.bare_mode and not settings.thinking_style_text.strip():   # 本体化（11-03 Aporia）：我们的思考风格不贴；用户自己写的照贴
        settings = replace(settings, sentinels={**settings.sentinels, "thinking_style": False})
    if scope.incognito:          # 无痕：它不知道对面是 TA——连名字、怎么指代都不给（Aporia 09-27 定）
        settings = replace(settings, user_name="", user_pronoun="they")
    lang = settings.lang
    day = now.astimezone(ZoneInfo(settings.tz)).date()
    persona = Persona.from_dict(await archive.get_persona(pool, comp), lang)
    if scope.incognito:
        persona = replace(persona, call_user="")
    if group is not None:            # 群里：每个事件都带上是谁（App 按人画头像名字）
        group_emit, me_name = emit, persona.name or "TA"

        async def emit(ev: dict) -> None:        # noqa: F811
            await group_emit({**ev, "speaker": str(comp), "speaker_name": me_name})
    # 群里的状态（第几轮、想起过哪些、上一轮用过什么）按「群 × TA」分开存
    state_key = uuid5(conv, str(comp)) if group is not None else conv
    state = await archive.get_state(pool, state_key)
    turn_no = int(state.get("turn_count", 0)) + 1
    history = await files.decorate(pool, await archive.unrolled(pool, conv), lang)   # 带附件的那几句接上〔图片〕〔文件〕
    text_for_model, sent = text, []
    if wake:
        said = None
        text = next((m.text for m in reversed(history) if m.role == "user"), "")   # 联想拿 TA 最后说的那句当线索
    elif group is not None:          # 群：你那句调度那层已经存了；text = 它上一句以后大家说的（联想用）
        said = None
    elif aside is not None:          # 旁白（10-31）：只递给它，不存；联想拿 TA 最后说的那句当线索
        said = None
        text_for_model = aside
        text = next((m.text for m in reversed(history) if m.role == "user"), "")
    elif resend:
        if not history or history[-1].role != "user":
            raise ValueError("没有可以重新回的那句")
        said, history = history[-1], history[:-1]
        text = text_for_model = said.text
    else:
        said = await archive.add_message(pool, conv, "user", text, parts=pieces, now=now,
                                         call={"id": call.id} if call is not None else None)
        sent = await files.claim(pool, conv, attachments, said.id) if attachments else []
        # 双语气泡不翻你那句（10-15 内测：用户不要），原话照发，TA 照样用它那种语言回
        text_for_model = "\n".join([text, *(files.note(f, lang) for f in sent)]).strip()
        if call is not None:
            call.user_msg = said.id
            text_for_model = call_speech.tag(lang) + text_for_model
    # 隔了很久才发的这一句（10-20 内测：两小时没说话，再开口 TA 还接着两小时前的话头）：tail 里告诉它过了多久
    gap_line = gap_note(now - history[-1].created_at, now, settings.tz, lang) if said is not None and history else ""
    edit_ref = None if scope.incognito or said is None else EditRef(conv, said.id)   # 倒回时按这一轮撤回它写过的东西
    if group is not None and group.user_msg is not None:
        edit_ref = EditRef(conv, group.user_msg)
    ulabel = user_label(settings, lang)
    if group is not None:
        history = group_history(history, comp, group, ulabel, lang)
    # 一段脑子（10-11）：别的房间最近 N 条按时间插进来；无痕不合
    merged_rooms = [] if scope.incognito else await _safe(
        groups.other_rooms(pool, comp, conv, settings.other_rooms_count, ulabel, lang), [])
    history = timeline.merge(history, merged_rooms, settings.other_rooms_count)
    try:
        route = await resolve_route(deps.keys, scope)
    except TrialOver:
        await emit({"type": "error", "kind": "trial_over", "message": USER_ERRORS[lang]["trial_over"]})
        await emit({"type": "done"})
        return TurnOutcome(False, error="trial_over")
    small = await _safe(resolve_route(deps.keys, scope, chore="dedupe"), route)    # 小判断（哨兵、细读）用的钥匙（10-15）
    adapter = get_adapter(deps, route)
    # 免费额度按这一轮真花的钱扣（连同哨兵、判读、看图、卷账本）：开始前记下今天的总花费，结束时算差
    trial_mark = (await archive.usage_on(pool, acc, day))["cost_usd"] if route.trial and not free_trial else None
    if group is None:                 # 积压太多先分批卷（10-13 内测）；平常这一步什么都不做
        info = lookup(route.chat_model)
        rolled_now = await catch_up(deps, scope, route, adapter, settings, state, day, emit,
                                    settings.memory_length or (info.high_water if info else DEFAULT_HIGH_WATER))
        if rolled_now:
            history = [m for m in history if m.id not in rolled_now]
    images: tuple = ()
    if sent:                          # TA 这一轮发了图：先写好描述，会看图的模型这一轮另外看原图
        for f in sent:
            if f.kind == "image":
                await _safe(vision.describe(deps, scope, route, f, lang, day, lambda r: get_adapter(deps, r)), "")
        text_for_model = "\n".join([text, *(files.note(f, lang) for f in sent)]).strip()
        if sees_images(route.provider, route.base_url):
            images = tuple(ImagePart(f.mime, base64.b64encode(Path(f.path).read_bytes()).decode())
                           for f in sent if f.kind == "image" and not f.sticker_id)   # 表情包只给描述（10-01）
    last_assistant = next((m.text for m in reversed(history) if m.role == "assistant"), "")

    names = (persona.name, persona.call_user, settings.user_name)   # 称呼不进关键词榜：它的名字、它怎么叫 TA、TA 的名字（09-28 召回改造第 1 步）
    heard = await _probe(deps, scope, small, settings, persona, history, text, day, now) \
        if deps.sentinel and settings.recall_probe and settings.recall_level != "off" and not scope.incognito else None
    # 细读：正式接口用大模型判读器判灰区（09-28 评测 medium 对13/错0/漏3，本地精排反而净亏）；没有真模型的测试里用本地精排
    judge = None
    if settings.careful_read and not scope.incognito:
        judge = LLMJudge(get_adapter(deps, small), small.ledger_model or small.chat_model,
                         _recent_lines(settings, persona, history), settings.lang) if deps.sentinel else deps.reranker
    # 一潮之内同一条记忆只想起一次（09-27 Aporia定：按潮不按钟点，有的潮不到六小时）；卷账本时清空
    seen = {int(k) for k in (state.get("recall_seen") or [])}
    hidden_people = await _safe(hidden.hidden_for(pool, comp), frozenset())   # 对它隐藏的人物卡（10-01）
    recall = None if scope.incognito or not text.strip() else await _safe(M.recall(
        pool, deps.embedder, comp, text, people_owner=acc, context=last_assistant or None,
        level=settings.recall_level, already_shown=frozenset(seen) | hidden_people,
        in_context_since=history[0].created_at if history else None, now=now,
        reranker=judge, rng=deps.rng, names=names, probe=heard), None)
    if isinstance(judge, LLMJudge) and judge.usage is not None:
        jm = small.ledger_model or small.chat_model
        await _safe(archive.add_usage(pool, acc, day, jm, judge.usage, cost(judge.usage, jm)), None)
    if recall is not None:
        seen.update([m.id for m in recall.full] + [l.memory_id for l in recall.lines]
                    + [m.id for ms in recall.linked.values() for m in ms])
    state["recall_seen"] = sorted(seen)
    sticky = "" if scope.incognito else now_and_then(state, "sticky", await _safe(M.get_sticky(pool, comp), ""), now,
                                                     wake=bool(wake))
    core = [] if scope.incognito else [m.content for m in sorted(
        await _safe(M.list_memories(pool, comp, kind="core"), []), key=lambda m: m.id)]
    if recall is not None and (recall.full or recall.lines or recall.people):
        await emit({"type": "recall", "full": [m.content for m in recall.full],
                    "lines": [l.snippet for l in recall.lines], "people": [p.name for p in recall.people]})

    chat_info = lookup(route.chat_model)
    mode = monologue.effective_mode(settings, chat_info)
    untagged = ((monologue._ZH_PRONOUN.get(settings.user_pronoun, "TA") if lang == "zh" else settings.user_pronoun)
                if mode == "monologue" and group is None else "")
    if wake and mode == "monologue":
        head, _, rest = wake.partition("\n")          # 放在〔醒来〕那一行后面、最前面
        wake = f"{head}\n{monologue_note(lang, wake)}\n{rest}"
    character = persona.name if persona.custom(lang) else ""           # 自定义角色想事也得是它（10-01）
    english = lang == "zh" and mode == "native" and route.provider == "anthropic"   # Claude 用英文想，App 给翻译（10-01）
    last_thought = next((m.thinking for m in reversed(history) if m.role == "assistant"), "")
    lines = reminder_lines(settings, TurnFacts(turn_no, wake or text, last_assistant, list(state.get("last_tools", [])),
                                               last_thinking=last_thought),
                           deps.rng, no_draft=bool(chat_info and chat_info.drafts_in_thinking), mode=mode,
                           english=english, character=character)
    mono_rules = (monologue.rules(settings, settings.thinking_style_text.strip()
                                  or ("" if settings.bare_mode else thinking_style(settings, character=character)))
                  if mode == "monologue" else "")
    # 旧版本漏进正文的心里话（10-19）：回看历史前洗掉，不让 TA 照着自己漏过的样子学
    history = [replace(m, text=monologue.spoken_only(m.text, untagged, lang == "zh"))
               if m.role == "assistant" and group is None else m for m in history]
    hist, tools_note = history_msgs(history, lang)
    user_text_now = with_tools_note(tools_note, wake or text_for_model)
    if group is None:                # 历史末尾已经是用户那侧（醒来没说话留的那条）：跟这一轮并成一段，不连着两条
        hist, user_text_now = fold_tail(hist, user_text_now)
    if group is not None:            # 群：最后那几句（你和别的 TA 说的）就是这一轮要接的话；末尾是它自己的就提醒轮到它
        tail_user: list[str] = []
        while hist and hist[-1].role == "user":
            tail_user.insert(0, hist.pop().text)
        user_text_now = with_tools_note(tools_note, "\n\n".join(tail_user) or YOUR_TURN[lang])
    if group is not None or merged_rooms:
        hist = squash(hist)
    before, thinking_lines = split_thinking(lines, settings)
    focus_note = "" if scope.incognito or group is not None else await _safe(focus.pending_note(pool, conv, lang), "")
    if focus_note:                   # 哨兵：刚结束的专注，这一轮告诉它一次
        before = [*before, focus_note]
    lore_all = [] if scope.incognito else await _safe(lore.list_for(pool, acc, comp), [])
    sticker_lib: list = []                             # 表情包（10-31）：它写 [表情包：#12] 发，这张表壹层里给；无痕、群里不给
    if not scope.incognito and group is None:          # 标记表情：TA 给它哪句点了什么，这一轮告诉它一次（群里第一步都不递）
        sticker_lib = await _safe(ST.for_companion(pool, acc, comp), [])
        if call is None:             # 库大：按刚聊的两句挑几张最搭的，带完整描述（电话里不发表情包）
            fits = ST.picks_block(await _safe(ST.picks(pool, deps.embedder, sticker_lib, [last_assistant, wake or text]), []), lang)
            if fits:
                before = [*before, fits]
        before = [*before, *await _safe(reactions.pending_lines(pool, conv, lang), [])]
        near = "\n".join(await _safe(far_dates.open_lines(pool, comp, now, settings.tz, lang), []))
        if now_and_then(state, "dates", near, now, wake=bool(wake)):      # 快到的远事：不每轮都给（09-30）
            before = [*before, near]
        before = [*before, *await _safe(drawer.opened_lines(pool, comp, settings.tz, lang), [])]
        before = [*before, *await _safe(diary.unlocked_lines(pool, comp, lang), [])]   # 日记锁着那段 TA 打开了（10-01）
        wallet_note = await _safe(wallet.pending_note(pool, acc, now, lang), "")
        if wallet_note:              # 钱包（10-02 Aporia：偶尔提一句）：TA 自己记的、它还没听说的，隔半天才给一次
            before = [*before, wallet_note]
        tarot_note = await _safe(tarot.pending_note(pool, comp, lang), "")
        if tarot_note:               # 塔罗（10-03）：TA 抽、它解好的那局，下一次开口递一次
            before = [*before, tarot_note]
        since = state.get("moments_at")   # 朋友圈（10-18）：上次聊完以后跟它有关的新动静，递一次；它在朋友圈回过什么也在里面
        moments_note = await _safe(_moments_recap(pool, acc, comp, since, now, lang), "")
        if moments_note:
            before = [*before, moments_note]
        state["moments_at"] = now.isoformat()
        food_note = "" if quiet_food else await _safe(food_store.pending_note(pool, acc, now, lang), "")
        if food_note:                # 饮食：TA 刚记的 / 刚估好的，这一轮告诉它一次（09-29）
            before = [*before, food_note]
        items = await _safe(context_line.load(pool, acc), {})
        listening = "" if wake else await _safe(ears.for_turn(pool, items, state, now, lang), "")
        if listening:                # 耳朵（09-30）：TA 说话时在放的歌；有它的这轮〔TA 那边〕不再写「在听」
            before = [*before, listening]
            items = {k: v for k, v in items.items() if k != "music"}
        reading = await _safe(books.reading_line(pool, acc, now, lang, comp), "")
        if reading:                  # 书架（10-02）：TA 这 3 分钟里翻过页的那本
            before = [*before, reading]
        # 世界书（09-30）：TA 这句 + 上一句 + 它上一句里碰到关键词的；醒来只看 TA 最后一句
        prev_said = "" if wake else next((m.text for m in reversed(history) if m.role == "user"), "")
        book = lore.pick(lore_all, [text] if wake else [prev_said, text, last_assistant], state, turn_no, lang)
        if book:
            before = [*before, book]
        if not wake:                 # 偶尔想起（10-14）：隔几轮随手抽一条梗，它自己也会用
            occ = lore.occasional(lore_all, state, turn_no, lang,
                                 every=await _safe(lore.get_every(pool, acc), lore.OCCASIONAL_EVERY))
            if occ:
                before = [*before, occ]
        side = context_line.render(items, now, settings.tz, lang)
        if side and context_line.due(items, now, last_at=state.get("side_at"), last_key=state.get("side_key"),
                                     wake=bool(wake)):   # TA 那边：天气、在哪、日程、步数、快捷指令（09-28）；不是每轮都给
            before = [*before, side]
            state["side_at"], state["side_key"] = now.isoformat(), context_line.moment_key(items, now)
    outside = mcp.Toolbox()                      # 用户自己接的 MCP 服务（10-05，Host）：无痕不给；连不上的这一轮跳过
    if not scope.incognito and group is None and settings.mcp_servers:
        outside = await _safe(mcp.toolbox(pool, getattr(deps.keys, "box", None), acc, settings.mcp_servers), mcp.Toolbox())
    phone_on = (call is None and group is None and not scope.incognito and deps.ringer is not None   # 打电话（10-31）
                and await _safe(deps.ringer.can_ring(acc), False))
    draw_on = (not scope.incognito and group is None and deps.files_dir is not None   # 挑了画图钥匙才给 draw（10-15）
               and await _safe(media.image_route(pool, getattr(deps.keys, "box", None), acc), None) is not None)
    if not draw_on and group is None and not wake and not scope.incognito and chores.wants_drawing(text):
        await emit({"type": "notice", "text": DRAW_NOTICE[lang]})    # 叫 TA 画、还没挑画图钥匙：提醒去哪挑（10-16）
    room_text = ("\n\n" + timeline.room_note(timeline.group_room(group.name, lang == "zh") if group is not None
                                               else timeline.private_room(lang == "zh"), lang)) if merged_rooms else ""
    parts = ContextParts(
        tools=[t for t in tool_specs() if t.name in GROUP_TOOLS] if group is not None
        else tool_specs(incognito=scope.incognito, extra=(("draw",) if draw_on else ()) + (("phone_call",) if phone_on else ()))
        + outside.specs,
        base=(G.room_rules(zh=lang == "zh", group=group.name, me=persona.name or "TA", user_name=ulabel,
                           others=list(group.others)) + "\n\n" if group is not None else "") + render_base(persona, core, lang,
                         monologue="\n\n".join(x for x in (mono_rules, inner_voice.rules(settings) if settings.inner_voice else "") if x),
                         tone=([] if settings.bare_mode else tone_lines(lang, settings.warmth, settings.initiative, settings.humor))
                         + ([] if scope.incognito else voice.mode_lines(lang, settings.voice_mode, settings)),
                         relationship=settings.relationship,
                         lore="\n\n".join(x for x in (lore.always_block(lore_all, lang), ST.menu_block(sticker_lib, lang)) if x),
                         chat_rules=not settings.long_mode,
                         life=settings.offline_life or settings.long_mode,   # 线下生活关着：没有出门吃饭那两行（10-05）
                         talk=settings.talk_rules, bare=settings.bare_mode) + room_text,             # 用户自己写的说话规矩（10-05）；合了别的房间就说一声在哪（10-31）     # 长文模式：拿掉「说话」那一节（10-01 Aporia）
        ledger=ledger.render_group_ledger(await archive.get_ledger(pool, conv), lang, persona.name or "TA")
        if group is not None else ledger.render_ledger(await archive.get_ledger(pool, conv), monologue.clean_samples(state.get("voice_samples", []), untagged, lang == "zh"), lang,
                                                         settings.user_name),
        history=hist,
        volatile=render_volatile(now=now, tz=settings.tz, lang=lang, recall=recall, sticky=sticky, lines=before),
        user_text=user_text_now,
        # 人设锚（10-01 Aporia：怕脱离人设）：离最新对话最近的一行，每轮十几个字
        tail="\n".join([*thinking_lines, *([inner_voice.hook(settings)] if settings.inner_voice else []),
                         *([bilingual.rule(settings)] if bilingual.active(settings, group) else []),
                         *([gap_line] if gap_line else []),
                         *([] if settings.bare_mode else [TEXTS[lang]["anchor"].format(name=persona.name or "Lumi")
                                                           + ("" if settings.long_mode or settings.talk_rules.strip() else TEXTS[lang]["short"])]),
                         # 电话（10-31）：只在通话时塞的说明，压在最后、离它开口最近；挂了就撤
                         *([call_speech.rules(lang, monologue._ZH_PRONOUN.get(settings.user_pronoun, "TA")
                                              if lang == "zh" else settings.user_pronoun)] if call is not None else [])]),
        images=images,
    )
    req = build_request(parts, model=route.chat_model, thinking=mode == "native", user_tag=user_tag(acc),
                        lang=lang)
    if call is not None:
        req.on_text = lambda t: call.feed(t)        # 边写边切句子，第一句写完就交给手机去念
    await emit({"type": "injections", "lines": lines})
    await emit({"type": "typing"})

    ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=comp, account_id=acc, now=now, lang=lang,
                      edit_ref=edit_ref, allowed=INCOGNITO_TOOLS if scope.incognito else (GROUP_TOOLS if group is not None else None),
                      tz=settings.tz,
                      names=names, deps=deps, mcp=outside.route, conversation=conv)
    started = time.monotonic()                   # 「思考了 x 秒」：从开口到说完（含中间调工具）
    out, err = None, None
    try:
        out = await tool_loop(adapter, req, ctx, emit, lang, untagged=untagged, retag=settings.monologue_retry, phone=call)
    except LLMError as e:
        err = e
    except CallCut:                  # 电话里她开口了 / 挂了：写到哪算哪
        out = LoopResult("", "", Usage(), [], 0)
    if call is not None and err is None:
        return await _call_done(deps, scope, call, out, route, req, state, state_key, turn_no, day, now, emit, lang, settings,
                                adapter, parts, time.monotonic() - started)
    if err is not None and context_full(err):
        # 装不下了（模型窗口比记性长度小、或者积压，10-14）：卷账本只在一轮成功之后，不先卷就会每句都报这个错。
        # 先把前面卷进账本；私聊接着用短了的历史再试一次，群里让 TA 再发一次
        log.warning("context too long, rolling before retry: %s", err.message[:300])
        rolled = await roll(deps, scope, route, adapter, settings, state, parts, day, emit, state_key=state_key, group=group)
        if rolled and group is None:
            left = {m.id for m in await archive.unrolled(pool, conv)}
            history = [m for m in history if m.id < 0 or m.id in left]
            hist, _ = history_msgs(history, lang)
            hist = fold_tail(hist, "")[0]
            parts = replace(parts, history=squash(hist) if merged_rooms else hist,
                            ledger=ledger.render_ledger(await archive.get_ledger(pool, conv), monologue.clean_samples(state.get("voice_samples", []), untagged, lang == "zh"),
                                                        lang, settings.user_name))
            req = build_request(parts, model=route.chat_model, thinking=mode == "native", user_tag=user_tag(acc), lang=lang)
            try:
                out, err = await tool_loop(adapter, req, ctx, emit, lang, untagged=untagged, retag=settings.monologue_retry), None
            except LLMError as e:
                err = e
        if err is not None and rolled:
            err = LLMError("too_long", err.message, status=err.status)
    if err is not None:
        e = err
        await emit({"type": "error", "kind": e.kind,
                    "message": USER_ERRORS[lang].get(e.kind, USER_ERRORS[lang]["other"])})
        await archive.log_turn(pool, conv, {"turn": turn_no, "error": e.kind, "detail": e.message[:500],
                                            "wake": bool(wake)}, now=now)
        await emit({"type": "done"})
        return TurnOutcome(False, error=e.kind)

    thinking_ms = round((time.monotonic() - started) * 1000)
    usd = cost(out.usage, route.chat_model)
    await archive.add_usage(pool, acc, day, route.chat_model, out.usage, usd)
    keepalive.remember(scope, route, req, now, enabled=settings.cache_keepalive)   # Claude 缓存保活（09-29，开了才记）
    if wake:
        silent, out.text = split_silent(out.text)
        if silent:                   # 它选了不说：压着的动静全丢，聊天记录、状态都不动，只记这一轮花了多少
            await archive.log_turn(pool, conv, {"turn": turn_no, "wake": True, "silent": True, "model": route.chat_model,
                                                "tools": out.tools_used, "usage": asdict(out.usage), "cost_usd": usd,
                                                "thinking": out.thinking[-2000:]}, now=now)
            if out.tool_notes:       # 不说话但去做了自己的事（逛论坛之类）：留一条，下次记得（10-30 内测）
                await archive.add_message(pool, conv, "wake", silent_note(lang, out.tool_notes), now=now)
            return TurnOutcome(False, usd or 0.0)
        emit = real_emit
        for ev in held:
            await emit(ev)
        await archive.add_message(pool, conv, "wake", wake, now=now)

    out.text = model_noise.strip(out.text)       # 模型漏出来的内部标记（<ds_safety>…）不是它说的话（10-11）
    out.text = timeline.strip_tag(out.text)      # 学着历史在开头垫的房间标签（10-31）
    # 正文标记（10-31）：[表情包：#12] / ⟪里程碑：…⟫ 解出来照办；写坏了的也剥掉，不进气泡。群里、无痕只剥不办
    parsed = markers.parse(out.text)
    out.text = parsed.text
    if (parsed.stickers or parsed.milestones) and not scope.incognito and group is None:
        before_cards = len(ctx.cards)
        out.tool_notes += await _safe(act_on_markers(ctx, parsed.stickers, parsed.milestones, sticker_lib), [])
        for card in ctx.cards[before_cards:]:
            out.cards.append({"kind": card.kind, "text": card.text, **({"data": card.data} if card.data else {})})
            await emit({"type": "card", "kind": card.kind, "text": card.text, "private": card.private,
                        **({"data": card.data} if card.data else {})})
    # 心声（10-11）：最后那段 [心声]…[/心声] 切下来，不进气泡、不念，存在这条上、单独推给 App 画小卡片
    out.text, voice_text = inner_voice.split(out.text)     # 没开也切掉（10-12：旧历史 / 人设里有，模型照写），只是不发卡
    if not settings.inner_voice:
        voice_text = ""
    if group is not None:
        out.text = G.strip_own_label(out.text, persona.name or "TA")
    if out.thinking.strip():
        await emit({"type": "thinking", "text": out.thinking, "ms": thinking_ms})
    bubbles_out = split_reply(out.text, settings.max_bubbles, settings.long_mode)
    # 跟它最近说过的几乎一样的气泡丢掉（10-13 内测：DeepSeek 把腔调样本 / 上一轮原话抄回来，一上午每句都是同一句）
    recent_said = [b for m in await archive.recent(pool, conv, 8) if m.role == "assistant"
                   for b in split_reply(m.text, None, settings.long_mode)]
    kept = repeats.drop_repeated(bubbles_out, recent_said)
    if len(kept) != len(bubbles_out):
        bubbles_out, out.text = kept, "\n\n".join(kept)
    trans: list = []
    if bilingual.active(settings, group) and bubbles_out:          # 双语气泡（10-15）：每泡的译文
        if settings.bilingual_by == "self":
            bubbles_out, trans = bilingual.split_self(bubbles_out)
            out.text = "\n\n".join(bubbles_out)
        else:
            plain = [voice.strip_tags(voice.body(b)) if voice.is_voice(b) else b for b in bubbles_out]
            trans = await bilingual.translate(deps, scope, plain, bilingual.speaks(settings), bilingual.target(settings), lang)
    tr = lambda j: {"translation": trans[j]} if j < len(trans) and trans[j] else {}
    for i, bubble in enumerate(bubbles_out):
        if i:
            await emit({"type": "typing"})
            await deps.sleep(typing_delay(bubble))
        if not voice.is_voice(bubble):
            await emit({"type": "bubble", "text": bubble, **tr(i)})
            continue
        # 语音条（10-31 起按需念）：先落一个占位的语音条，TA 点了才合成（/messages/{mid}/speak，念过的挂在消息上）；
        # 不发档 / 无痕 / 没钥匙 / 额度不够 → 当文字发，存档里那段也改成文字
        speakable = (settings.voice_mode != "off" and not scope.incognito
                     and await _safe(voice.can_speak(deps, acc, len(voice.body(bubble)), voice.provider_of(settings)), False))
        if not speakable:
            out.text = out.text.replace(bubble, voice.as_text(bubble), 1)
            await emit({"type": "bubble", "text": voice.as_text(bubble), **tr(i)})
        else:
            await emit({"type": "bubble", "text": voice.as_text(bubble), "lazy_voice": voice.lazy_public(bubble), **tr(i)})
    if not out.text.strip() and out.thinking.strip():
        log.warning("reply came out empty after cutting the monologue; thinking was: %s", out.thinking[-2000:])
    if voice_text and out.text.strip():
        await emit({"type": "inner_voice", "text": voice_text})
    if out.text.strip() or ctx.drawn:
        saved = await archive.add_message(pool, conv, "assistant", out.text, thinking=out.thinking,
                                          tools="\n".join(out.tool_notes), cards=out.cards, thinking_ms=thinking_ms,
                                          inner_voice=voice_text, now=deps.now(),
                                          speaker=comp if group is not None else None,
                                          speaker_name=(persona.name or "TA") if group is not None else "",
                                          translations=trans or None)
        if variants and out.text.strip():            # 重新回（11-07）：之前那几版留着，能翻回去
            await archive.set_variants(pool, saved.id, [*variants, out.text], len(variants))
        if ctx.drawn:                                # 它画的图挂在这句上（10-15）
            await _safe(files.claim(pool, conv, ctx.drawn, saved.id), [])
        if group is not None:
            await groups.set_last_speaker(pool, conv, comp)
        if not wake and not scope.incognito and group is None:    # 「划线说两句」挂着线头：回话抄一份进页边（10-02 书架）
            await _safe(books.catch_reply(pool, acc, conv, comp, out.text, deps.now()), None)

    if recall is not None and out.text.strip():   # 浮上来的记忆，回复真用上了才算被想起（09-28 召回只读）
        await _safe(M.mark_used(pool, comp, [m.id for m in recall.full] + [l.memory_id for l in recall.lines]
                                + [m.id for ms in recall.linked.values() for m in ms],
                                out.text, names=names, now=now), [])
    state.update(turn_count=turn_no, last_tools=out.tools_used, last_prompt_tokens=out.last_prompt)
    await archive.save_state(pool, state_key, state)
    await archive.log_turn(pool, conv, {
        "turn": turn_no, "model": route.chat_model,
        "recall": {"full": [m.id for m in recall.full], "lines": [l.memory_id for l in recall.lines],
                   "people": [p.id for p in recall.people]} if recall else None,
        "injections": lines, "tools": out.tools_used, "usage": asdict(out.usage), "cost_usd": usd,
        "prompt_total": out.last_prompt}, now=now)
    await emit({"type": "usage", **asdict(out.usage), "prompt_total": out.last_prompt, "cost_usd": usd,
                "today": await archive.usage_on(pool, acc, day)})

    info = lookup(route.chat_model)
    high_water = settings.memory_length or (info.high_water if info else DEFAULT_HIGH_WATER)
    # 到线了、也攒够一批再卷（10-15：固定部分自己就超线时，别每轮为两句话卷一次）
    if ledger.needs_roll(out.last_prompt, high_water) and ledger.worth_rolling(await archive.unrolled(pool, conv),
                                                                                high_water):
        await roll(deps, scope, route, adapter, settings, state, parts, day, emit, state_key=state_key, group=group)
    if trial_mark is not None and out.text.strip():   # 醒来不说话的成本我们认（上面已经提前返回了）
        spent = (await archive.usage_on(pool, acc, day))["cost_usd"] - trial_mark
        await charge_trial(pool, acc, round(spent * 1_000_000))
    await emit({"type": "done"})
    return TurnOutcome(bool(out.text.strip()), usd or 0.0)


async def _call_done(deps: Deps, scope: Scope, call: CallCtx, out: LoopResult, route: Route, req: ChatRequest, state: dict,
                     state_key: UUID, turn_no: int, day: date, now: datetime, emit: Emit, lang: str, settings: Settings,
                     adapter, parts: ContextParts, seconds: float) -> TurnOutcome:
    """电话里这一轮收尾（10-31）：存的是念出来的那几句（一句一行），被打断的只存念到的 + 「——」；不切气泡、不念语音条。"""
    pool, conv = deps.pool, scope.conversation
    call.flush()
    usd = cost(out.usage, route.chat_model)
    if out.usage.input or out.usage.output:
        await archive.add_usage(pool, scope.account, day, route.chat_model, out.usage, usd)
    said = call.saved_text()
    if said or out.cards:
        saved = await archive.add_message(pool, conv, "assistant", said, tools="\n".join(out.tool_notes), cards=out.cards,
                                          now=deps.now(), call={"id": call.id, **({"cut": True} if call.cut and said else {})})
        call.assistant_msg = saved.id
    state.update(turn_count=turn_no, last_tools=out.tools_used, last_prompt_tokens=out.last_prompt or state.get("last_prompt_tokens", 0))
    await archive.save_state(pool, state_key, state)
    await archive.log_turn(pool, conv, {"turn": turn_no, "model": route.chat_model, "call": call.id, "cut": call.cut,
                                        "tools": out.tools_used, "usage": asdict(out.usage), "cost_usd": usd,
                                        "first_line_s": round(seconds, 2)}, now=now)
    info = lookup(route.chat_model)
    high_water = settings.memory_length or (info.high_water if info else DEFAULT_HIGH_WATER)
    if out.last_prompt and ledger.needs_roll(out.last_prompt, high_water) and \
            ledger.worth_rolling(await archive.unrolled(pool, conv), high_water):
        await _safe(roll(deps, scope, route, adapter, settings, state, parts, day, emit, state_key=state_key), None)
    await emit({"type": "done"})
    return TurnOutcome(bool(said), usd or 0.0)


async def catch_up(deps: Deps, scope: Scope, route: Route, adapter, settings: Settings, state: dict,
                   day: date, emit: Emit, high_water: int) -> set[int]:
    """积压太多（中转不回 usage 的老版本积下的几千条）：开口前先分批卷，不然这一轮整段发出去，
    装不下就报错、永远轮不到卷。每批挑记忆只看这一批。返回卷掉了哪些 id；平常什么都不做。"""
    msgs = await archive.unrolled(deps.pool, scope.conversation)
    done: set[int] = set()
    base = ("你在翻你和 TA 以前的聊天，挑出值得长期记住的事。" if settings.lang == "zh"
            else "You are going through your earlier chats with them to keep what is worth remembering.")
    bare = ContextParts(tools=tool_specs(incognito=scope.incognito), base=base, ledger="", history=[], volatile="", user_text="")
    for batch in ledger.backlog_batches(msgs, high_water):
        if not await roll(deps, scope, route, adapter, settings, state, bare, day, emit, batch=batch):
            break                       # 写不动先停，这一轮照常聊，下一轮再接着卷
        done |= {m.id for m in batch}
    return done


async def roll(deps: Deps, scope: Scope, route: Route, adapter, settings: Settings, state: dict,
               parts: ContextParts, day: date, emit: Emit, *, state_key: UUID | None = None,
               group: GroupCtx | None = None, batch: list | None = None) -> bool:
    """卷账本：① 主模型先挑要长期记的（前缀跟刚才那轮一样，几乎全走缓存）② 便宜模型按天写新账
    ③ 超了天龄配额的天单独压 ④ 丢掉 14 天以前的、标记已卷、留腔调样本。
    写账失败：原文先留着，下一轮再试；连续失败提醒用户。账本只在这里动，平时不动，缓存不会无故作废。"""
    pool = deps.pool
    lang = settings.lang
    # batch = 积压时的一批（catch_up）：整批卷掉，挑记忆也只看这一批
    msgs = batch if batch is not None else await archive.unrolled(pool, scope.conversation)
    plan = ledger.RollPlan(rolled=batch, kept=[]) if batch is not None else ledger.plan_roll(msgs)
    if not plan.rolled:
        return False
    await emit({"type": "ledger", "status": "rolling", "count": len(plan.rolled)})

    # 上次写账没成、这段已经挑过记忆的，不再整段重挑（10-15：写不动时每轮多一次满上下文的调用，还会重复记）
    fresh = [m for m in plan.rolled if m.id > int(state.get("picked_upto", 0))]
    if fresh and not scope.incognito:          # 无痕里不记任何东西
        pick_hist, pick_note = history_msgs(await files.decorate(pool, msgs, lang), lang)
        pick_parts = replace(parts, history=pick_hist, volatile="",
                             user_text=with_tools_note(pick_note, ledger.pick_prompt(fresh, lang)))
        pick_req = build_request(pick_parts, model=route.chat_model, thinking=False, user_tag=user_tag(scope.account),
                                 lang=lang)
        ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=scope.companion, account_id=scope.account,
                          now=deps.now(), lang=lang)
        try:
            picked = await tool_loop(adapter, pick_req, ctx, emit, lang)
            await _account(pool, scope.account, day, route.chat_model, picked.usage)
            state["picked_upto"] = fresh[-1].id
        except LLMError as e:
            log.warning("pre-roll memory pick failed: %s", e)

    # 每种短活两条腿：先用便宜的，打回了换主聊天模型兜底；只有一个模型就给它两次机会（照之前自用的 App）。
    # 钥匙串里勾了「写账本」的那把（10-15）当第一条腿，聊天那把兜底
    picked = await _safe(resolve_route(deps.keys, scope, chore="ledger"), None)
    mine = picked is not None and (picked.provider, picked.api_key) != (route.provider, route.api_key)

    def legs(first: str) -> list:
        back = route.chat_model if first != route.chat_model else first
        return [(get_adapter(deps, picked), picked.chat_model), back] if mine and not settings.ledger_same_as_chat else [first, back]
    write_legs = legs(route.chat_model if settings.ledger_same_as_chat else route.ledger_model)
    age_legs = legs(route.chat_model if settings.ledger_same_as_chat else (route.age_model or route.ledger_model))
    name = Persona.from_dict(await archive.get_persona(pool, scope.companion), lang).name
    state_key = state_key or scope.conversation
    group_name = group.name if group is not None else None      # 群账本（10-11）：用名字写，群里每个 TA 读同一本
    today = deps.now().astimezone(ZoneInfo(settings.tz)).date()
    days = await archive.get_ledger(pool, scope.conversation)
    stale = ledger.too_old(days, today)

    # ① 写新账：按天拆开，每天（太长就分段）单独写一小段接上去；任何一段写不出来 = 这次不卷
    ok = True
    for d, chunks in sorted(ledger.day_transcripts(plan.rolled, settings.tz, lang, settings.user_name,
                                                   group=group is not None).items()):
        if (today - d).days >= ledger.MAX_DAYS:
            continue                                   # 反正留不住，不花这个钱
        for transcript in chunks:
            entry, spent = await ledger.write_entry(adapter, write_legs, transcript, d, days.get(d, ""),
                                                    name=name, lang=lang, user_name=settings.user_name, group=group_name)
            for model, usage in spent:
                await _account(pool, scope.account, day, model, usage)
            if entry is None:
                ok = False
                break
            days[d] = ledger.join_text(days.get(d, ""), entry, lang)
        if not ok:
            break
    if not ok:
        state["ledger_fails"] = int(state.get("ledger_fails", 0)) + 1
        await archive.save_state(pool, state_key, state)
        if state["ledger_fails"] >= LEDGER_FAIL_WARN:
            await emit({"type": "notice", "text": LEDGER_NOTICE[lang]})
        await emit({"type": "ledger", "status": "failed"})
        return False

    # ② 压旧天：超了天龄配额的天单独压；压不动先留着，下次卷的时候再试
    for d, age, quota in ledger.over_quota(days, today, lang):
        short, spent = await ledger.age_day(adapter, age_legs, days[d], d, age, quota, name=name, lang=lang,
                                            user_name=settings.user_name, group=group_name)
        for model, usage in spent:
            await _account(pool, scope.account, day, model, usage)
        if short is not None:
            days[d] = short
    # ③ 14 天以前的丢掉（交给记忆库）
    for d in stale:
        days[d] = ""
    await archive.put_ledger(pool, scope.conversation, days, now=deps.now())
    await archive.mark_rolled(pool, scope.conversation, [m.id for m in plan.rolled])
    await edits.forget_up_to(pool, scope.conversation, plan.rolled[-1].id)
    state["voice_samples"] = [] if group is not None else ledger.voice_samples(plan.rolled)
    state["ledger_fails"] = 0
    state["ledger_at"] = deps.now().isoformat()      # 上次卷进账本的时刻（10-27 内测：Host 设置里「回声」看得到）
    state["recall_seen"] = []            # 新的一潮：原文卷走了，靠联想的记忆可以重新浮上来
    state["lore_seen"] = {}              # 世界书也清零：递过的那几轮卷走了
    await archive.save_state(pool, state_key, state)
    await emit({"type": "ledger", "status": "done", "count": len(plan.rolled)})
    return True


async def _moments_recap(pool, acc: UUID, comp: UUID, since: str | None, now: datetime, lang: str) -> str:
    events = await MO.recap_events(pool, acc, comp, datetime.fromisoformat(since) if since else None, now)
    return MO.render_recap(events, now, lang)
