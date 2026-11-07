"""聊天：发消息进等候区、事件流、补拉、倒回。"""
from __future__ import annotations

import asyncio
import json
from datetime import date, datetime, time, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response
from fastapi.responses import StreamingResponse

from brain import accounts, archive, attachments, books, groups, monologue, reactions, rewind
from brain.group_run import run_group
from brain import voice
from brain.bubbles import split_reply
from brain.scope import Scope
from brain.settings import Settings
from brain.turn import run_turn
from patrol import store as patrol_store

from .deps import Api, account, api, own_conversation

router = APIRouter()
KEEPALIVE = 15.0                 # 事件流没事件时隔多久发一行心跳，免得被中间的代理掐断


def _runner(a: Api, scope: Scope, variants: list[str] | None = None):
    async def run(text: str, resend: bool, emit, attachments: list, parts: list) -> None:
        out = await run_turn(a.deps, scope, text, emit, resend=resend, attachments=attachments, pieces=parts, variants=variants)
        await accounts.touch_conversation(a.deps.pool, scope.conversation, a.deps.now())
        if out.said and not scope.incognito:
            reply = next((m for m in reversed(await archive.recent(a.deps.pool, scope.conversation, 3))
                          if m.role == "assistant"), None)
            if reply is not None:
                if not a.rooms.watched(scope.conversation):     # TA 发完就切走了：它的回话推送过去（09-28）
                    await patrol_store.queue_push(a.deps.pool, account=scope.account, companion=scope.companion,
                                                  conversation=scope.conversation, text=reply.text)
    return run


def _group_runner(a: Api, acc: UUID, gid: UUID):
    """群（10-11）：一串说完；切走了的话最后说话那个 TA 的那句推过去"""
    async def run(text: str, resend: bool, emit, attachments: list, parts: list) -> None:
        room = a.rooms.room(gid)
        room.interrupt = False
        said = await run_group(a.deps, acc, gid, text, emit, lambda: room.interrupt, resend=resend, parts=parts,
                               attachments=attachments)
        await accounts.touch_conversation(a.deps.pool, gid, a.deps.now())
        if said and not a.rooms.watched(gid):
            reply = next((m for m in reversed(await archive.recent(a.deps.pool, gid, 3)) if m.role == "assistant"), None)
            if reply is not None and reply.speaker:
                await patrol_store.queue_push(a.deps.pool, account=acc, companion=reply.speaker, conversation=gid,
                                              text=f"{reply.speaker_name}：{reply.text}")
    return run


async def _settings_of(a: Api, scope: Scope, speaker: UUID | None = None) -> Settings:
    """这个窗口按谁的设定：私聊 = 窗口的 TA；群 = 说话的那个 TA，没有就第一个成员"""
    who = speaker or scope.companion
    if who is None:
        first = await groups.members(a.deps.pool, scope.conversation)
        who = first[0] if first else None
    return Settings.from_dict(await archive.get_settings(a.deps.pool, who)) if who else Settings()


@router.post("/conversations/{conv}/messages", status_code=202)
async def send(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """发一句：先进等候区，安静满 reply_wait 秒才跑。回复从 /events 推。
    client_id 是 app 自己生成的：30 秒没收到这一轮的事件就带同一个 id 重发，这里不会排两次。"""
    scope = await own_conversation(a, acc, conv)
    text = str(body.get("text") or "").strip()
    try:
        files = [UUID(str(x)) for x in body.get("attachments") or []][:10]
    except ValueError:
        raise HTTPException(400, "附件编号不对") from None
    if not text and not files:
        raise HTTPException(400, "说点什么吧")
    wait = (await _settings_of(a, scope)).reply_wait
    client_id = str(body["client_id"]) if body.get("client_id") else None
    if scope.companion is None:      # 群（10-11）
        queued = a.rooms.submit(conv, text, client_id, wait, _group_runner(a, acc, conv), files, interrupt=True)
        return {"queued": queued, "client_id": client_id, "reply_wait": wait}
    if body.get("book_mark_id"):     # 「划线说两句」（10-02 书架）：它接下来的回话抄一份进页边
        await books.arm_thread(a.deps.pool, acc, conv, int(body["book_mark_id"]), a.deps.now())
    elif text:                       # 说了别的就收线
        await books.disarm(a.deps.pool, conv)
    queued = a.rooms.submit(conv, text, client_id, wait, _runner(a, scope), files)
    return {"queued": queued, "client_id": client_id, "reply_wait": wait}


@router.get("/conversations/{conv}/events")
async def events(conv: UUID, request: Request, acc: UUID = Depends(account), a: Api = Depends(api)):
    """一直连着的事件流（Server-Sent Events）。同一个窗口可以有好几个连着的（手机 + 平板）。"""
    await own_conversation(a, acc, conv)
    q = a.rooms.listen(conv)

    async def stream():
        try:
            yield ": hello\n\n"
            while True:
                try:
                    ev = await asyncio.wait_for(q.get(), KEEPALIVE)
                except asyncio.TimeoutError:
                    if await request.is_disconnected():
                        return
                    yield ": ping\n\n"
                    continue
                if ev is None:           # 窗口删了
                    return
                yield f"data: {json.dumps(ev, ensure_ascii=False, default=str)}\n\n"
        finally:
            a.rooms.unlisten(conv, q)

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


def _msg(m: archive.StoredMsg) -> dict:
    return {"id": m.id, "role": m.role, "text": m.text, "thinking": m.thinking, "thinking_ms": m.thinking_ms,
            "inner_voice": m.inner_voice, "at": m.created_at.isoformat(),
            "speaker": str(m.speaker) if m.speaker else None, "speaker_name": m.speaker_name or None,
            # 电话（10-31）：电话里说的不出气泡；挂断那条画成一行「📞 通话时长」，点开看这通
            "call": bool(m.call) and not (m.call or {}).get("end") and not (m.call or {}).get("ring"),
            "call_end": bool((m.call or {}).get("end")), "call_id": (m.call or {}).get("id"),
            "ring": (m.call or {}).get("ring"),           # TA 打来没接通（第 4 步）：missed / declined / withdrawn
            "variants": len(m.variants or []) or None, "variant": m.variant}   # 重新回留下了几版、现在是第几版（11-07）


@router.get("/conversations/{conv}/messages")
async def messages(conv: UUID, after: int = 0, before: int | None = None, day: str | None = None, limit: int = 200,
                   acc: UUID = Depends(account), a: Api = Depends(api)):
    """三种取法：after = 补拉（app 从后台回来，拉 after 之后没看到的，含思考链）；before = 往前翻（上滑加载更早的）；
    day = YYYY-MM-DD 那天的（按联系人时区，「回到那天」）。〔醒来〕是给它看的，一律不给。
    busy=true 表示还有排着或者正在跑的一轮，app 可以接着等事件流。"""
    scope = await own_conversation(a, acc, conv)
    limit = max(1, min(limit, 500))
    has_more = None
    if before is not None:
        msgs, has_more = await archive.before(a.deps.pool, conv, before, limit)
    elif day is not None:
        try:
            d = date.fromisoformat(day)
        except ValueError:
            raise HTTPException(400, "day 要写成 2026-09-27") from None
        tz = ZoneInfo((await _settings_of(a, scope)).tz)
        start = datetime.combine(d, time(0), tzinfo=tz)
        msgs = await archive.between(a.deps.pool, conv, start, start + timedelta(days=1), limit)
    else:
        msgs = await archive.after(a.deps.pool, conv, after, limit)
    shown = [m for m in msgs if m.role != "wake"]
    by_speaker = {sp: await _settings_of(a, scope, sp) for sp in {m.speaker for m in shown}}   # 群里每个 TA 按自己的设定切

    def bubbles(m: archive.StoredMsg) -> list[str]:       # 跟事件流里推的一样切；TA 连发的几句还原成几个
        if m.call:                                         # 电话里的（10-31）：聊天里只留「📞 通话时长」那一行
            return []
        if m.role == "assistant":
            settings = by_speaker[m.speaker]
            return split_reply(m.text, settings.max_bubbles, settings.long_mode)
        return m.parts or [m.text]
    marks = await reactions.for_messages(a.deps.pool, [m.id for m in shown])
    files = await attachments.for_messages(a.deps.pool, [m.id for m in shown])
    clips = {m.id: await voice.clips_for_message(a.deps.pool, scope.account, m.id)
             for m in shown if m.role == "assistant" and voice.MARK in m.text}
    speakable = bool(clips) and await voice.can_speak(a.deps, scope.account)

    def with_voice(m: archive.StoredMsg) -> tuple[list[str], list, list]:
        """语音条（10-03）：气泡里给逐字稿，并排一列 voices（null = 文字），App 老版本照样读 bubbles。
        还没念的（10-31 按需念）并排一列 lazy_voices：App 画成语音条、点了才念；老 App 不认这列，看到的是文字。"""
        bs = bubbles(m)
        if m.id not in clips:
            return bs, [None] * len(bs), [None] * len(bs)
        texts, vs, lz = [], [], []
        for b in bs:
            c = clips[m.id].get(voice.text_sha(voice.body(b))) if voice.is_voice(b) else None
            texts.append(voice.strip_tags(voice.body(b)) if voice.is_voice(b) else b)
            vs.append(c.public() if c else None)
            lz.append(voice.lazy_public(b) if voice.is_voice(b) and c is None and speakable else None)
        return texts, vs, lz
    shaped = {m.id: with_voice(m) for m in shown}
    def divider(m: archive.StoredMsg) -> str | None:      # 搬来的那几段：每段第一条挂的灰字行（brain/chat_import.py）
        return next((c.get("text") for c in m.cards or [] if c.get("kind") == "divider"), None)
    out = {"messages": [{**_msg(m), "bubbles": shaped[m.id][0], "voices": shaped[m.id][1], "lazy_voices": shaped[m.id][2],
                         "cards": [] if m.call else [c for c in m.cards or [] if c.get("kind") != "divider"],
                         "divider": (m.call or {}).get("line") or divider(m),
                         "reaction": (marks.get(m.id) or {}).get(-1) or next(iter((marks.get(m.id) or {}).values()), None),
                         "reactions": reactions.per_bubble(marks.get(m.id) or {}, len(shaped[m.id][0])),
                         "attachments": [f.public() for f in files.get(m.id, [])],
                         "translations": m.translations if m.translations and len(m.translations) == len(shaped[m.id][0]) else None}
                        for m in shown],
           "busy": a.rooms.busy(conv)}
    if has_more is not None:
        out["has_more"] = has_more
    return out


@router.get("/conversations/{conv}/calendar")
async def calendar(conv: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """聊天日历：哪几天聊过（按联系人时区）、那天说了几句、那天第一句的号（点日期从那句开始看）。〔醒来〕不算。"""
    scope = await own_conversation(a, acc, conv)
    tz = (await _settings_of(a, scope)).tz
    rows = await a.deps.pool.fetch(
        "SELECT to_char(created_at AT TIME ZONE $2, 'YYYY-MM-DD') AS day, count(*) AS n, min(id) AS first_id "
        "FROM chat_messages WHERE user_id = $1 AND role <> 'wake' GROUP BY 1 ORDER BY 1", conv, tz)
    return {"days": [{"day": r["day"], "count": r["n"], "first_id": r["first_id"]} for r in rows]}


@router.get("/conversations/{conv}/search")
async def search(conv: UUID, q: str = "", limit: int = 50, acc: UUID = Depends(account), a: Api = Depends(api)):
    """按字搜聊天记录（只搜说出口的话，不搜思考链），新的在前；每条带前后各一条当上下文，点了跳过去用 before / after 补。"""
    await own_conversation(a, acc, conv)
    q = q.strip()
    if not q:
        raise HTTPException(400, "要搜什么？")
    hits = []
    for m in await archive.search(a.deps.pool, conv, q[:100], max(1, min(limit, 100))):
        prev, nxt = await archive.neighbours(a.deps.pool, conv, m.id)
        hits.append({"message": _msg(m), "before": _msg(prev) if prev else None, "after": _msg(nxt) if nxt else None})
    return {"hits": hits}


@router.post("/conversations/{conv}/rewind")
async def do_rewind(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """点用户的一句 → 这句和之后的撤回，原文还给输入栏（kind=edit）；
    点它一轮的最后一条 → 撤回这一轮回复，服务器接着自己重新回（kind=regenerate，事件照样从 /events 推）。"""
    scope = await own_conversation(a, acc, conv)
    if a.rooms.busy(conv):
        raise HTTPException(409, "它还在回，等这一轮说完再倒回")
    try:
        mid = int(body["message_id"])
    except (KeyError, TypeError, ValueError):
        raise HTTPException(400, "要带 message_id") from None
    role = next((m.role for m in await archive.unrolled(a.deps.pool, conv) if m.id == mid), None)
    try:
        if role == "user":
            return {"kind": "edit", "text": await rewind.rewind_to_user(a.deps.pool, a.deps.embedder, scope, mid)}
        if scope.companion is None:  # 群：点哪个 TA 的都一样——你那句之后大家说的全撤，重新来一串
            await rewind.undo_group_round(a.deps.pool, a.deps.embedder, scope, mid)
            a.rooms.run_now(conv, _group_runner(a, acc, conv), resend=True)
            return {"kind": "regenerate"}
        kept = _kept_variants(await archive.unrolled(a.deps.pool, conv), mid)
        await rewind.undo_reply(a.deps.pool, a.deps.embedder, scope, mid)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    a.rooms.run_now(conv, _runner(a, scope, kept), resend=True)
    return {"kind": "regenerate"}


MAX_VARIANTS = 10


def _kept_variants(msgs: list, mid: int) -> list[str]:
    """重新回之前留一份（11-07，一测最想要的）：这几条撤掉的话合成一版，排在它原来那几版后面；只留最近几版。"""
    gone = [m for m in msgs if m.id >= mid and m.role == "assistant" and m.text.strip()]
    if not gone:
        return []
    old = gone[0].variants or []
    earlier = [v for i, v in enumerate(old) if i != gone[0].variant]
    return [*earlier, "\n\n".join(m.text for m in gone)][-(MAX_VARIANTS - 1):]


async def _editable_reply(a: Api, acc: UUID, mid: int):
    """TA 说的、还没卷进账本的一条：（消息，这个 TA 的设定）"""
    row = await a.deps.pool.fetchrow(
        """SELECT m.user_id AS conv, coalesce(m.speaker_id, c.companion_id) AS companion_id FROM chat_messages m
           JOIN conversations c ON c.id = m.user_id WHERE m.id = $1 AND c.account_id = $2 AND m.role = 'assistant'""", mid, acc)
    if row is None:
        raise HTTPException(400, "只能改它说的话")
    if a.rooms.busy(row["conv"]):
        raise HTTPException(409, "它还在回，等这一轮说完再改")
    msg = next((m for m in await archive.unrolled(a.deps.pool, row["conv"]) if m.id == mid), None)
    if msg is None:
        raise HTTPException(400, "这句已经卷进账本了，改不了")
    return msg, Settings.from_dict(await archive.get_settings(a.deps.pool, row["companion_id"]))


@router.patch("/messages/{mid}")
async def edit_reply(mid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """改 TA 说过的一泡（11-07，修小幻觉）：{bubble, text}。TA 下一轮看到的就是改过的。"""
    msg, s = await _editable_reply(a, acc, mid)
    bubbles = split_reply(msg.text, s.max_bubbles, s.long_mode)
    i, text = body.get("bubble"), str(body.get("text") or "").strip()
    if not isinstance(i, int) or not 0 <= i < len(bubbles):
        raise HTTPException(400, "没有这一条")
    if not text:
        raise HTTPException(400, "改完不能是空的")
    if voice.is_voice(bubbles[i]):
        raise HTTPException(400, "语音条改不了")
    bubbles[i] = text
    full = "\n\n".join(bubbles)
    vs = msg.variants
    if vs and msg.variant is not None and 0 <= msg.variant < len(vs):
        vs = [*vs[:msg.variant], full, *vs[msg.variant + 1:]]
    await archive.set_reply_text(a.deps.pool, mid, full, variants=vs)
    return {"ok": True}


@router.post("/messages/{mid}/variant")
async def choose_variant(mid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """换到重新回留下的另一版（11-07）：{index}。TA 下一轮看到的就是这一版。"""
    msg, _ = await _editable_reply(a, acc, mid)
    i = body.get("index")
    if not msg.variants or not isinstance(i, int) or not 0 <= i < len(msg.variants):
        raise HTTPException(400, "没有这一版")
    await archive.set_reply_text(a.deps.pool, mid, msg.variants[i], index=i)
    return {"ok": True}


RECALL_NOTE = {
    "zh": "〔{p}撤回了一条消息：「{text}」〕\n你刚才已经看到了。像微信里对方撤回那样，照你自己的样子接就好。",
    "en": "[{p} unsent a message: \"{text}\"]\nYou'd already seen it. Like when someone unsends a message in a chat app — respond however you naturally would.",
}


@router.post("/conversations/{conv}/recall")
async def do_recall(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """撤回自己的一句（10-20，照之前自用的 App）：只删这一句，它的回复都留着。
    它还没读到（后面没有它的话、也不在回）就悄悄删；读过了，像微信那样告诉它撤回了哪句（私聊才说，群里只删）。"""
    scope = await own_conversation(a, acc, conv)
    if body.get("client_id"):        # 刚发出去、还在「等你说完」里的那句：它还没看到，直接拿掉
        if a.rooms.withdraw(conv, str(body["client_id"])):
            return {"recalled": None, "told": False}
        raise HTTPException(409, "TA 已经开始看了，等它回完再撤回")
    try:
        mid = int(body["message_id"])
    except (KeyError, TypeError, ValueError):
        raise HTTPException(400, "要带 message_id") from None
    msgs = await archive.unrolled(a.deps.pool, conv)
    target = next((m for m in msgs if m.id == mid), None)
    if target is None or target.role != "user":
        raise HTTPException(400, "只能撤回自己说的、还没卷进账本的话")
    read = a.rooms.busy(conv) or any(m.id > mid and m.role == "assistant" for m in msgs)
    if not await archive.delete_message(a.deps.pool, conv, mid):
        raise HTTPException(400, "这条撤不回了")
    told = read and scope.companion is not None and not scope.incognito
    if told:
        s = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion))
        p = (monologue._ZH_PRONOUN.get(s.user_pronoun, "TA") if s.lang == "zh" else
             {"she": "She", "he": "He"}.get(s.user_pronoun, "They"))
        note = RECALL_NOTE[s.lang if s.lang in RECALL_NOTE else "zh"].format(p=p, text=target.text.strip()[:300])
        asyncio.create_task(_after_recall(a, scope, note))
    return {"recalled": mid, "told": told}


async def _after_recall(a: Api, scope, note: str) -> None:
    """它正在回的话等它说完（最多 5 分钟），再递一句「撤回了」让它接（借巡逻醒来那条路，说完照常存）"""
    for _ in range(600):
        if not a.rooms.busy(scope.conversation):
            break
        await asyncio.sleep(0.5)
    ran, out = await a.rooms.run_exclusive(scope.conversation, lambda emit: run_turn(a.deps, scope, "", emit, wake=note))
    if ran and out is not None and out.said:
        await accounts.touch_conversation(a.deps.pool, scope.conversation, a.deps.now())


def _bubble(raw) -> int:
    """第几泡（10-11）；老 App 不带 = -1（整条，画在最后一泡）"""
    try:
        return max(-1, int(raw)) if raw is not None else -1
    except (TypeError, ValueError):
        raise HTTPException(400, "bubble 要是个数字") from None


async def _which_bubble(a: Api, acc: UUID, conv: UUID, mid: int, bubble: int) -> tuple[str, bool]:
    """那一泡的原话（告诉它的时候引这泡，不引整条）+ 是不是最后一泡（老的整条表情画在那，换/取消要一起清）"""
    if bubble < 0:
        return "", True
    scope = await own_conversation(a, acc, conv)
    r = await a.deps.pool.fetchrow("SELECT text, speaker_id FROM chat_messages WHERE id = $1", mid)
    settings = await _settings_of(a, scope, r["speaker_id"] if r else None)
    text = (r["text"] if r else "") or ""
    parts = split_reply(text, settings.max_bubbles, settings.long_mode)
    if bubble >= len(parts):
        return "", False
    b = parts[bubble]
    return (voice.strip_tags(voice.body(b)) if voice.is_voice(b) else b), bubble == len(parts) - 1


@router.put("/messages/{mid}/reaction", status_code=204)
async def react(mid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """给它的一泡点个表情（每泡一个，再点就换）。只能点它说的话。"""
    conv, role = await _owned_message(a, acc, mid)
    emoji = str(body.get("emoji") or "").strip()
    if not emoji or len(emoji) > 16:
        raise HTTPException(400, "要带一个表情")
    if role != "assistant":
        raise HTTPException(400, "只能给它说的话点表情")
    bubble = _bubble(body.get("bubble"))
    quote, last = await _which_bubble(a, acc, conv, mid, bubble)
    if last and bubble >= 0:
        await reactions.set_reaction(a.deps.pool, conv, mid, None, -1)
    await reactions.set_reaction(a.deps.pool, conv, mid, emoji, bubble, quote)
    return Response(status_code=204)


@router.delete("/messages/{mid}/reaction", status_code=204)
async def unreact(mid: int, bubble: int | None = None, acc: UUID = Depends(account), a: Api = Depends(api)):
    conv, _ = await _owned_message(a, acc, mid)
    b = _bubble(bubble)
    _, last = await _which_bubble(a, acc, conv, mid, b)
    await reactions.set_reaction(a.deps.pool, conv, mid, None, b)
    if last and b >= 0:
        await reactions.set_reaction(a.deps.pool, conv, mid, None, -1)
    return Response(status_code=204)


@router.post("/messages/{mid}/thinking/translate")
async def translate_thinking(mid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    """它那句的思考链翻成中文（10-01）：翻过的直接给。"""
    from brain.auth import TrialOver
    from brain.translate import thinking_zh
    conv, role = await _owned_message(a, acc, mid)
    r = await a.deps.pool.fetchrow("SELECT m.thinking, coalesce(m.speaker_id, c.companion_id) AS companion_id "
                                   "FROM chat_messages m JOIN conversations c ON c.id = m.user_id WHERE m.id = $1", mid)
    if role != "assistant" or not (r["thinking"] or "").strip():
        raise HTTPException(400, "这句没有思考链")
    try:
        text = await thinking_zh(a.deps, Scope(acc, r["companion_id"], conv), mid, r["thinking"], a.deps.now())
    except TrialOver:
        raise HTTPException(402, "今天的免费额度用完了")
    return {"text": text}


async def _owned_message(a: Api, acc: UUID, mid: int) -> tuple[UUID, str]:
    r = await a.deps.pool.fetchrow("SELECT user_id, role FROM chat_messages WHERE id = $1", mid)
    if r is None:
        raise HTTPException(404, "没有这条消息")
    await own_conversation(a, acc, r["user_id"])          # 不是这个账号的窗口 → 404
    return r["user_id"], r["role"]
