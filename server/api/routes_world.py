"""地图 + 它的一天的接口（11-11）。路径和字段跟 Lite 本机（ios/Lite/LocalMap.swift）一模一样，App 两条路同一份界面。"""
from __future__ import annotations

import asyncio
from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import accounts, archive
from brain import world as W
from brain.settings import Settings
from brain.turn import run_turn

from .deps import Api, account, api, own_companion

router = APIRouter()


async def _settings(a: Api, cid: UUID) -> Settings:
    return Settings.from_dict(await archive.get_settings(a.deps.pool, cid))


@router.get("/world/{cid}")
async def world(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    s, now = await _settings(a, cid), a.deps.now()
    await W.kick_day(a.deps, acc, cid, s, now)          # 打开地图也算今天第一次：没排就后台排
    return await W.snapshot(a.deps.pool, cid, s, now)


@router.post("/world/{cid}/generate", status_code=202)
async def generate(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    W.regenerate(a.deps, acc, cid)                      # 起世界（花钥匙的钱）：它起的换掉，你加的留着
    return {"started": True}


@router.post("/world/{cid}/places", status_code=201)
async def add_place(cid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    name = str(body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "给这个地方起个名字")
    return await W.add_place(a.deps.pool, acc, cid, name, str(body.get("desc") or ""), str(body.get("icon") or ""))


@router.patch("/world/{cid}/places/{pid}")
async def patch_place(cid: UUID, pid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    out = await W.patch_place(a.deps.pool, cid, pid, body)
    if out is None:
        raise HTTPException(404, "没有这个地方")
    return out


@router.delete("/world/{cid}/places/{pid}", status_code=204)
async def delete_place(cid: UUID, pid: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    why = await W.delete_place(a.deps.pool, cid, pid)
    if why:
        raise HTTPException(400, why)
    return Response(status_code=204)


@router.post("/world/{cid}/visit")
async def visit(cid: UUID, body: dict = Body(default={}), acc: UUID = Depends(account), a: Api = Depends(api)):
    """去它在的地方找它：切线下（记下在哪）、进它最近的平常窗口、它先开场"""
    await own_companion(a, acc, cid)
    pool, now = a.deps.pool, a.deps.now()
    s = await _settings(a, cid)
    pls = await W.places(pool, cid)
    loc = W._local(now, s.tz)
    n = W.current(await W.today(pool, cid, loc.date()), pls, loc.strftime("%H:%M"))
    pid = body.get("place_id") if isinstance(body.get("place_id"), int) else (n or {}).get("place_id")
    pl = next((p for p in pls if p["id"] == pid), None)
    if pl is None:
        raise HTTPException(404, "没有这个地方")
    s.long_mode, s.scene_place = True, pid
    await archive.save_settings(pool, cid, s.to_dict())
    convs = await accounts.list_conversations(pool, acc, cid)
    conv = convs[0].id if convs else await accounts.new_conversation(pool, acc, cid)
    doing = str((n or {}).get("doing") or "") if n and n.get("place_id") == pid else ""
    note = W.visit_note(s.lang, pl["name"], doing)
    scope = await accounts.scope_for(pool, acc, conv)

    async def go() -> None:
        await asyncio.sleep(1.2)          # 等聊天页推开、接上事件流再开场（跟 Lite 一样）
        ran, out = await a.rooms.run_exclusive(conv, lambda emit: run_turn(a.deps, scope, "", emit, wake=note))
        if ran and out is not None and out.said:
            await accounts.touch_conversation(pool, conv, a.deps.now())
    W._spawn(go())
    return {"conversation": str(conv)}
