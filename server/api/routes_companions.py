"""联系人（一个 AI）和窗口（它底下的一段对话）。"""
from __future__ import annotations

import asyncio
from datetime import date, timedelta

from uuid import UUID

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, Response, UploadFile
from fastapi.responses import FileResponse

from brain import accounts, archive, attachments, auth, avatars, lore, rewind, tavern, traits
from brain.persona import Persona, persona_cost
from brain.settings import ADVANCED_KEYS, Settings
from brain.turn import run_turn
from brain.wake_text import render_first_meet

from .deps import Api, account, api, own_companion, own_conversation

router = APIRouter()


async def _companion(a: Api, acc: UUID, cid: UUID, *, full: bool = False) -> dict:
    pool = a.deps.pool
    s = Settings.from_dict(await archive.get_settings(pool, cid))
    p = Persona.from_dict(await archive.get_persona(pool, cid), s.lang)
    r = await pool.fetchrow("SELECT key_id, avatar_ver, created_at FROM companions WHERE id = $1", cid)
    week = await pool.fetchval(          # 最近 7 天聊了几句（首页「最常聊」用，09-28）
        "SELECT count(*) FROM chat_messages m JOIN conversations c ON c.id = m.user_id WHERE c.companion_id = $1 "
        "AND NOT c.incognito AND m.role <> 'wake' AND m.created_at >= $2", cid, a.deps.now() - timedelta(days=7))
    total = await pool.fetchval(         # 一共聊了几句（首页「认识第几天」中号、大号用，10-04）
        "SELECT count(*) FROM chat_messages m JOIN conversations c ON c.id = m.user_id WHERE c.companion_id = $1 "
        "AND NOT c.incognito AND m.role <> 'wake'", cid)
    out = {"id": str(cid), "name": p.name, "key_id": str(r["key_id"]) if r["key_id"] else None,
           "avatar_ver": r["avatar_ver"], "created_at": r["created_at"].isoformat(), "week_messages": week,
           "total_messages": total,
           "relationship": s.relationship}          # 聊天页名字旁边的小图标（09-29）
    if full:
        out.update(persona=p.for_client(s.lang), settings=s.to_dict())   # 出厂性格不出服务器
    return out


@router.get("/companions")
async def list_companions(acc: UUID = Depends(account), a: Api = Depends(api)):
    return [await _companion(a, acc, cid) for cid in await accounts.list_companions(a.deps.pool, acc)]


@router.post("/companions", status_code=201)
async def add_companion(body: dict = Body(default={}), acc: UUID = Depends(account), a: Api = Depends(api)):
    """新联系人：设置照着账号里第一个联系人的时区、我的设定，人设是出厂的（可带个名字），顺带开第一个窗口。"""
    pool = a.deps.pool
    first = (await accounts.list_companions(pool, acc))[0]
    base = Settings.from_dict(await archive.get_settings(pool, first))
    prof = await accounts.get_profile(pool, acc)
    cid = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, cid, Settings(tz=base.tz, lang=base.lang, user_name=prof["name"],
                                                    user_pronoun=prof["pronoun"]).to_dict())
    name = str(body.get("name") or "").strip()
    if name:
        await archive.save_persona(pool, cid, {"name": name[:20]})
    conv = await accounts.new_conversation(pool, acc, cid)
    return {**await _companion(a, acc, cid, full=True), "conversation": str(conv)}


async def _read_card(file: UploadFile) -> tavern.Card:
    try:
        return tavern.parse(await file.read(tavern.MAX_BYTES + 1), file.filename or "")
    except tavern.CardError as e:
        raise HTTPException(400, str(e)) from e


async def _who(pool, acc: UUID) -> tuple[str, str]:
    """TA 的名字和语言（宏 {{user}} 用；照账号第一个联系人的设置）。"""
    first = (await accounts.list_companions(pool, acc))[0]
    s = Settings.from_dict(await archive.get_settings(pool, first))
    return (await accounts.get_profile(pool, acc))["name"] or s.user_name, s.lang


@router.post("/companions/import/preview")
async def import_preview(file: UploadFile = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """导入酒馆角色卡之前先看看（10-01）：什么都不建。persona_cost = 这份人设每轮大概多花多少美元（走缓存时, 没走时；按 DeepSeek 算）。"""
    card = await _read_card(file)
    user, lang = await _who(a.deps.pool, acc)
    out = tavern.preview(card, user, lang)
    cost = persona_cost(tavern.persona_text(card, user, lang), "deepseek-flash")
    out["persona_cost"] = list(cost) if cost else None
    return out


@router.post("/companions/import", status_code=201)
async def import_card(file: UploadFile = File(...), greeting: int = Form(0), style: str = Form("chat"),
                      acc: UUID = Depends(account), a: Api = Depends(api)):
    """导入（10-01）：新联系人 = 卡的名字、人设（导入的那份）、头像（卡图）、关系「照卡来」、「多久来找你」低档、
    文风 chat / long（long = 长文模式，拿掉说明书的「说话」一节）、世界书只给它、第一个窗口第一句是挑好的开场白。"""
    if style not in ("chat", "long"):
        raise HTTPException(400, "文风只能是 chat / long")
    card = await _read_card(file)
    pool = a.deps.pool
    user, lang = await _who(pool, acc)
    first = (await accounts.list_companions(pool, acc))[0]
    base = Settings.from_dict(await archive.get_settings(pool, first))
    prof = await accounts.get_profile(pool, acc)
    cid = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, cid, Settings(
        tz=base.tz, lang=base.lang, user_name=prof["name"], user_pronoun=prof["pronoun"], relationship="card",
        patrol_level="low", long_mode=style == "long").to_dict())
    await archive.save_persona(pool, cid, {"name": card.name, "imported": tavern.persona_text(card, user, lang)})
    if card.image:
        try:
            avatars.save(a.cfg.files_dir, cid, card.image)
            await pool.execute("UPDATE companions SET avatar_ver = avatar_ver + 1 WHERE id = $1", cid)
        except avatars.AvatarError:
            pass                                             # 图读不了：照样导，没头像
    entries, skipped = tavern.lore_entries(card, user, lang)
    added = 0
    for e in entries:
        try:
            await lore.add(pool, acc, companion_id=cid, created_by="user", **e)
            added += 1
        except ValueError:                                   # 满了 / 不合规的：跳过，数目告诉 TA
            skipped += 1
    conv = await accounts.new_conversation(pool, acc, cid)
    greetings = [tavern.fill(g, card.name, user or ("你" if lang == "zh" else "you")) for g in card.greetings]
    if greetings:
        await archive.add_message(pool, conv, "assistant", greetings[max(0, min(greeting, len(greetings) - 1))],
                                  now=a.deps.now())
    return {**await _companion(a, acc, cid, full=True), "conversation": str(conv), "lore": added, "lore_skipped": skipped}


@router.get("/companions/{cid}")
async def get_companion(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    return await _companion(a, acc, cid, full=True)


@router.patch("/companions/{cid}")
async def patch_companion(cid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """改一部分：{persona: {...}, settings: {...}, key_id}。没带的项不动。
    改人设 / 设置里影响底子的项会让这个联系人的缓存作废一次（跟测试台一样）。"""
    pool = a.deps.pool
    await own_companion(a, acc, cid)
    try:
        s = Settings.from_dict({**(await archive.get_settings(pool, cid)), **(body.get("settings") or {})})
        if (body.get("settings") or {}).get("long_mode") is False:
            s.scene_place = None          # 回线上：地图上找过去的那场线下结束了（11-11，跟 Lite 一样）
        if body.get("persona") is not None:
            if "traits" in body["persona"]:
                traits.check(body["persona"]["traits"])
            cur = Persona.from_dict(await archive.get_persona(pool, cid), s.lang).to_dict()
            p = Persona.from_dict({**cur, **body["persona"]}, s.lang)
    except (ValueError, TypeError) as e:
        raise HTTPException(400, str(e)) from e
    if "key_id" in body:
        try:
            await auth.use_key(pool, acc, cid, UUID(body["key_id"]) if body["key_id"] else None)
        except (auth.AuthError, ValueError) as e:
            raise HTTPException(400, str(e)) from e
    if body.get("settings"):
        await archive.save_settings(pool, cid, s.to_dict())
        if {"sleep_to", "tz"} & set(body["settings"]):            # 改了起床时间 / 时区：早上那次按新的重挂（10-01）
            from patrol import morning
            await morning.ensure_clock(pool, acc, a.deps.now())
    if body.get("persona") is not None:
        await archive.save_persona(pool, cid, p.overrides(s.lang))
    return await _companion(a, acc, cid, full=True)


@router.delete("/companions/{cid}", status_code=204)
async def delete_companion(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    for conv in [r["id"] for r in await a.deps.pool.fetch("SELECT id FROM conversations WHERE companion_id = $1", cid)]:
        a.rooms.drop(conv)
    try:
        await accounts.delete_companion(a.deps.pool, acc, cid)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    avatars.remove(a.cfg.files_dir, cid)
    return Response(status_code=204)


@router.post("/companions/{cid}/sync-advanced")
async def sync_advanced(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """「同步到全部联系人」：把这个联系人「高级」里的设置抄给同账号的其他联系人（外层的名字、性格、关系、钥匙不动）。"""
    pool = a.deps.pool
    await own_companion(a, acc, cid)
    src = await archive.get_settings(pool, cid)
    src = Settings.from_dict(src).to_dict()
    n = 0
    for other in await accounts.list_companions(pool, acc):
        if other == cid:
            continue
        s = await archive.get_settings(pool, other)
        s.update({k: src[k] for k in ADVANCED_KEYS})
        await archive.save_settings(pool, other, Settings.from_dict(s).to_dict())
        n += 1
    return {"copied": n}


# ── 头像 ──

@router.put("/companions/{cid}/avatar")
async def put_avatar(cid: UUID, file: UploadFile = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    try:
        avatars.save(a.cfg.files_dir, cid, await file.read(avatars.MAX_BYTES + 1))
    except avatars.AvatarError as e:
        raise HTTPException(400, str(e)) from e
    ver = await a.deps.pool.fetchval("UPDATE companions SET avatar_ver = avatar_ver + 1 WHERE id = $1 RETURNING avatar_ver", cid)
    return {"avatar_ver": ver}


@router.get("/companions/{cid}/avatar")
async def get_avatar(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    p = avatars.path(a.cfg.files_dir, cid)
    if not p.exists():
        raise HTTPException(404, "还没有头像")
    return FileResponse(p, media_type="image/jpeg")


@router.delete("/companions/{cid}/avatar")
async def delete_avatar(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    avatars.remove(a.cfg.files_dir, cid)
    ver = await a.deps.pool.fetchval("UPDATE companions SET avatar_ver = avatar_ver + 1 WHERE id = $1 RETURNING avatar_ver", cid)
    return {"avatar_ver": ver}


@router.get("/traits")
async def list_traits(lang: str | None = None, acc: UUID = Depends(account), a: Api = Depends(api)):
    """性格标签清单（现在是空的，等Aporia的模拟人生清单）。lang 不给就跟第一个联系人。"""
    if lang not in ("zh", "en"):
        first = (await accounts.list_companions(a.deps.pool, acc))[0]
        lang = Settings.from_dict(await archive.get_settings(a.deps.pool, first)).lang
    return traits.catalog(lang)


# ── 窗口 ──

async def _conv_row(a: Api, c: accounts.Conversation) -> dict:
    last = next((m for m in reversed(await archive.recent(a.deps.pool, c.id, 3)) if m.role != "wake"), None)
    first = await a.deps.pool.fetchval("SELECT text FROM chat_messages WHERE user_id = $1 AND role <> 'wake' "
                                       "ORDER BY id LIMIT 1", c.id)
    # 最后一条是电话挂断那条：列表里写「📞 通话时长」，不写纸条（10-31）
    return {"id": str(c.id), "companion_id": str(c.companion_id), "incognito": c.incognito,
            "created_at": c.created_at.isoformat(), "last_at": c.last_at.isoformat(),
            "preview": (((last.call or {}).get("line") or last.text[:40]) if last else ""), "title": c.title, "first": (first or "")[:20]}


@router.get("/companions/{cid}/conversations")
async def list_conversations(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    return [await _conv_row(a, c) for c in await accounts.list_conversations(a.deps.pool, acc, cid)]


@router.post("/companions/{cid}/conversations", status_code=201)
async def new_conversation(cid: UUID, body: dict = Body(default={}), acc: UUID = Depends(account),
                           a: Api = Depends(api)):
    """新窗口（账本和聊天从空白开始，记忆照旧）；incognito=true 开无痕。"""
    await own_companion(a, acc, cid)
    if body.get("incognito"):
        conv = (await rewind.start_incognito(a.deps.pool, acc, cid)).conversation
    else:
        conv = await accounts.new_conversation(a.deps.pool, acc, cid)
    r = await a.deps.pool.fetchrow("SELECT id, companion_id, incognito, created_at, last_at, title FROM conversations "
                                   "WHERE id = $1", conv)
    return await _conv_row(a, accounts.Conversation(**dict(r)))


@router.patch("/conversations/{conv}")
async def rename_conversation(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """改窗口名 {title}（≤ 30 字；空 = 回到默认，app 用第一句）。"""
    await own_conversation(a, acc, conv)
    title = str(body.get("title") or "").strip()
    if len(title) > 30:
        raise HTTPException(400, "窗口名最多 30 个字")
    await a.deps.pool.execute("UPDATE conversations SET title = $2 WHERE id = $1", conv, title)
    r = await a.deps.pool.fetchrow("SELECT id, companion_id, incognito, created_at, last_at, title FROM conversations "
                                   "WHERE id = $1", conv)
    return await _conv_row(a, accounts.Conversation(**dict(r)))


@router.delete("/conversations/{conv}", status_code=204)
async def delete_conversation(conv: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """无痕窗口 = 关掉无痕（整段删）；普通窗口也能删，删的是这段聊天和账本，记忆还在联系人名下。"""
    scope = await own_conversation(a, acc, conv)
    a.rooms.drop(conv)
    if scope.incognito:
        await rewind.end_incognito(a.deps.pool, scope)
    else:
        await attachments.wipe(a.deps.pool, "conversation_id", conv)
        await archive.wipe(a.deps.pool, conv)
        await a.deps.pool.execute("DELETE FROM memory_edits WHERE conversation_id = $1", conv)
        await a.deps.pool.execute("DELETE FROM conversations WHERE id = $1", conv)
    return Response(status_code=204)


# ── 回声（10-27 内测：Host 也要看得到什么时候卷进账本、账本写了什么；跟 Lite 本机 LocalEcho 同一个样子）──

@router.get("/companions/{cid}/echo")
async def echo(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """这个 TA 每个窗口的账本：按天（新的在前）、腔调样本、上次卷的时刻、最近连着几次没卷成。没卷过的窗口不列。"""
    await own_companion(a, acc, cid)
    pool, out = a.deps.pool, []
    for c in await accounts.list_conversations(pool, acc, cid):
        days = await archive.get_ledger(pool, c.id)
        if not days:
            continue
        st = await archive.get_state(pool, c.id)
        at = st.get("ledger_at") or ((await pool.fetchval("SELECT max(updated_at) FROM ledger_days WHERE user_id = $1", c.id))
                                     or c.last_at).isoformat()          # 这版以前卷的没记时刻：拿账本最后一次改动顶上
        out.append({"conversation": str(c.id), "title": c.title, "alt_name": "",
                    "days": [{"day": d.isoformat(), "text": t} for d, t in sorted(days.items(), reverse=True)],
                    "samples": st.get("voice_samples", []), "at": at, "fails": int(st.get("ledger_fails", 0))})
    return out


@router.put("/conversations/{conv}/echo")
async def edit_echo(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """改某一天的账 {day, text}；text 空 = 不要这一天。"""
    await own_conversation(a, acc, conv)
    try:
        day = date.fromisoformat(str(body.get("day") or ""))
    except ValueError:
        raise HTTPException(400, "日子不对") from None
    await archive.put_ledger(a.deps.pool, conv, {day: str(body.get("text") or "").strip()}, now=a.deps.now())
    return {"ok": True}


# ── 初见（09-28）──

_greeting: set = set()      # 正在打招呼的联系人（防手快点两下）


@router.post("/companions/{cid}/greet", status_code=202)
async def greet(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """引导做完、第一次进聊天：它先开口打招呼。只在这个联系人一句话都还没有时跑（否则 409），不扣免费额度。
    回复照常从这个窗口的事件流出来；返回窗口 id。"""
    pool = a.deps.pool
    await own_companion(a, acc, cid)
    said = await pool.fetchval("SELECT EXISTS (SELECT 1 FROM chat_messages m JOIN conversations c ON c.id = m.user_id "
                               "WHERE c.companion_id = $1)", cid)
    if said or cid in _greeting:
        raise HTTPException(409, "已经聊过了")
    convs = await accounts.list_conversations(pool, acc, cid)
    conv = convs[0].id if convs else await accounts.new_conversation(pool, acc, cid)
    if a.rooms.busy(conv):
        raise HTTPException(409, "它正忙着")
    s = Settings.from_dict(await archive.get_settings(pool, cid))
    now = a.deps.now()
    text = render_first_meet(s.lang, now, s.tz, user_name=s.user_name, relationship=s.relationship)
    scope = await accounts.scope_for(pool, acc, conv)
    _greeting.add(cid)

    async def go() -> None:
        try:
            ran, out = await a.rooms.run_exclusive(
                conv, lambda emit: run_turn(a.deps, scope, "", emit, wake=text, free_trial=True))
            if ran and out is not None and out.said:
                await accounts.touch_conversation(pool, conv, a.deps.now())
        finally:
            _greeting.discard(cid)
    asyncio.create_task(go())
    return {"conversation": str(conv)}
