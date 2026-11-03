"""巡逻的接口（第 6 步）：报「在」、设备号、你定的钟、醒来账、每档估价、哨兵。
它自己约的钟（kind=self）这里一律看不见、改不动——那是它的小秘密（Aporia 09-27）。"""
from __future__ import annotations

import json
from datetime import timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, HTTPException, Response

from brain import accounts, archive
from brain import focus as F
from brain.auth import TrialOver
from brain.scope import Scope
from brain.settings import Settings
from brain.turn import get_adapter, resolve_route
from patrol import store
from patrol.clocks import next_fire, patrol_numbers, validate_spec
from patrol.estimate import DAYS, levels_table, per_wake_usd, wakes_per_day

from .deps import Api, account, api, own_companion, own_conversation

router = APIRouter()
PAUSED_NOTICE = {"zh": "找不到模型（key 可能不对或没余额了），我先不主动找你了。改好了我就接着来。",
                 "en": "I couldn't reach the model (the key may be wrong or out of credit), so I've stopped reaching out "
                       "for now. Once it's fixed I'll pick up again."}


def _bad(e: Exception) -> HTTPException:
    return HTTPException(400, str(e))


# ── 手机报的 ──

@router.post("/me/active")
async def active(body: dict = Body(default={}), acc: UUID = Depends(account), a: Api = Depends(api)):
    """app 开着时每几分钟报一声「在」（深夜靠它判断醒没醒）。带 tz = 手机换了时区，每个联系人跟着换。
    心跳因为连错暂停过的，这里恢复，回一句 notice 给 app 显示。"""
    pool, now = a.deps.pool, a.deps.now()
    await pool.execute("UPDATE accounts SET last_active_at = $2 WHERE id = $1", acc, now)
    comps = await accounts.list_companions(pool, acc)
    if body.get("tz"):
        try:
            ZoneInfo(str(body["tz"]))
        except Exception:
            raise HTTPException(400, "不认识这个时区") from None
        for cid in comps:
            s = await archive.get_settings(pool, cid)
            if s.get("tz") != body["tz"]:
                await archive.save_settings(pool, cid, {**s, "tz": str(body["tz"])})
    paused = await pool.fetch("UPDATE clocks SET spec = '{}'::jsonb WHERE account_id = $1 AND kind = 'heartbeat' "
                              "AND (spec->>'paused')::boolean RETURNING companion_id", acc)
    notice = None
    if paused:
        lang = Settings.from_dict(await archive.get_settings(pool, paused[0]["companion_id"])).lang
        notice = PAUSED_NOTICE[lang]
    return {"ok": True, "notice": notice}


@router.post("/me/devices", status_code=204)
async def device(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    token = str(body.get("apns_token") or "").strip()
    if not token or len(token) > 200:
        raise HTTPException(400, "要带 apns_token")
    # Mele Host（10-04）：走推送中转的手机带 relay:<编号>、中转口令、加密钥匙
    relay_secret = str(body.get("relay_secret") or "").strip()[:200] or None
    push_key = str(body.get("push_key") or "").strip()[:100] or None
    if token.startswith("relay:") and not (relay_secret and push_key):
        raise HTTPException(400, "走中转的设备要带 relay_secret 和 push_key")
    await a.deps.pool.execute(
        """INSERT INTO devices (account_id, apns_token, updated_at, relay_secret, push_key) VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (account_id, apns_token) DO UPDATE SET updated_at = $3, relay_secret = $4, push_key = $5""",
        acc, token, a.deps.now(), relay_secret, push_key)
    await _drop_older(a.deps.pool, acc, token, push_key)
    return Response(status_code=204)


async def _drop_older(pool, acc: UUID, keep: str, push_key: str | None) -> None:
    """同一部手机（加密钥匙一样）只留最新登记的那个（10-12 内测：每次打开 App 都登记出一个新编号，
    一条消息推好几遍、越开越多）"""
    if push_key:
        await pool.execute("DELETE FROM devices WHERE account_id = $1 AND push_key = $2 AND apns_token <> $3",
                           acc, push_key, keep)


async def _relay_register(relay: str, token: str, sandbox: bool, voip: bool = False) -> tuple[str, str] | None:
    import httpx
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.post(f"{relay.rstrip('/')}/register", json={"token": token, "sandbox": sandbox, "voip": voip})
    if r.status_code != 200:
        return None
    j = r.json()
    rid, secret = j.get("relay_id"), j.get("relay_secret")
    return (str(rid), str(secret)) if rid and secret else None


@router.post("/me/devices/relay")
async def device_via_host(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """手机连不上推送中转站时（10-12 内测：国内打不开 workers.dev，设备一直没登记、29 条推送全落空），
    把苹果设备号交给自己的 Host，Host 替它去中转站登记。"""
    token = str(body.get("token") or "").strip()
    push_key = str(body.get("push_key") or "").strip()[:100]
    if not token or len(token) > 200 or not push_key:
        raise HTTPException(400, "要带 token 和 push_key")
    if not a.cfg.push_relay:
        raise HTTPException(409, "这台 Host 没开推送中转")
    try:
        got = await _relay_register(a.cfg.push_relay, token, bool(body.get("sandbox")))
    except Exception:
        got = None
    if got is None:
        raise HTTPException(502, "Host 也连不上推送中转站")
    rid, secret = got
    await a.deps.pool.execute(
        """INSERT INTO devices (account_id, apns_token, updated_at, relay_secret, push_key) VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (account_id, apns_token) DO UPDATE SET updated_at = $3, relay_secret = $4, push_key = $5""",
        acc, f"relay:{rid}", a.deps.now(), secret, push_key)
    await _drop_older(a.deps.pool, acc, f"relay:{rid}", push_key)
    return {"relay_id": rid}


@router.post("/me/voip", status_code=204)
async def voip_device(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """TA 打给你（10-31）：手机在推送中转登记了 VoIP 设备号，把编号、口令、加密钥匙交给 Host"""
    rid = str(body.get("relay_id") or "").strip()[:100]
    secret = str(body.get("relay_secret") or "").strip()[:200]
    push_key = str(body.get("push_key") or "").strip()[:100]
    if not (rid and secret and push_key):
        raise HTTPException(400, "要带 relay_id、relay_secret、push_key")
    await _save_voip(a, acc, rid, secret, push_key)
    return Response(status_code=204)


@router.post("/me/voip/relay")
async def voip_via_host(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """手机连不上推送中转站（国内）：VoIP 设备号交给 Host，Host 替它去登记"""
    token = str(body.get("token") or "").strip()
    push_key = str(body.get("push_key") or "").strip()[:100]
    if not token or len(token) > 200 or not push_key:
        raise HTTPException(400, "要带 token 和 push_key")
    if not a.cfg.push_relay:
        raise HTTPException(409, "这台 Host 没开推送中转")
    try:
        got = await _relay_register(a.cfg.push_relay, token, bool(body.get("sandbox")), voip=True)
    except Exception:
        got = None
    if got is None:
        raise HTTPException(502, "Host 也连不上推送中转站")
    await _save_voip(a, acc, got[0], got[1], push_key)
    return {"relay_id": got[0]}


async def _save_voip(a: Api, acc: UUID, rid: str, secret: str, push_key: str) -> None:
    await a.deps.pool.execute(
        """INSERT INTO voip_devices (account_id, push_key, relay_id, relay_secret, updated_at) VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (account_id, push_key) DO UPDATE SET relay_id = $3, relay_secret = $4, updated_at = $5""",
        acc, push_key, rid, secret, a.deps.now())


# ── 你定的钟 ──

def _clock(c: store.Clock) -> dict:
    return {"id": c.id, "shape": c.shape, "spec": c.spec, "note": c.note,
            "next_at": c.next_at.isoformat() if c.next_at else None}


async def _tz(a: Api, cid: UUID) -> str:
    return Settings.from_dict(await archive.get_settings(a.deps.pool, cid)).tz


def _plan(shape: str, spec: dict, tz: str, now):
    spec = validate_spec(shape, spec, tz=tz)
    at = next_fire(shape, spec, now, tz)
    if at is None:
        raise ValueError("这个时间已经过了")
    return spec, at


@router.get("/companions/{cid}/clocks")
async def list_clocks(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    return [_clock(c) for c in await store.list_clocks(a.deps.pool, acc, cid)]


@router.post("/companions/{cid}/clocks", status_code=201)
async def add_clock(cid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{shape: at|once|every|window, spec: {...}, note}（spec 的样子见 patrol/clocks.py 开头）。"""
    await own_companion(a, acc, cid)
    try:
        spec, at = _plan(str(body.get("shape") or ""), body.get("spec") or {}, await _tz(a, cid), a.deps.now())
    except (ValueError, TypeError, KeyError) as e:
        raise _bad(e) from e
    c = await store.add_clock(a.deps.pool, acc, cid, kind="user", shape=body["shape"], spec=spec,
                              note=str(body.get("note") or "").strip()[:200], next_at=at)
    return _clock(c)


@router.patch("/clocks/{clock_id}")
async def patch_clock(clock_id: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    c = await store.get_clock(a.deps.pool, acc, clock_id)
    if c is None:
        raise HTTPException(404, "没有这个钟")
    kw = {}
    if "shape" in body or "spec" in body:
        shape = str(body.get("shape") or c.shape)
        try:
            kw["spec"], kw["next_at"] = _plan(shape, body.get("spec", c.spec), await _tz(a, c.companion_id), a.deps.now())
        except (ValueError, TypeError, KeyError) as e:
            raise _bad(e) from e
        kw["shape"] = shape
    if "note" in body:
        kw["note"] = str(body["note"] or "").strip()[:200]
    return _clock(await store.update_clock(a.deps.pool, acc, clock_id, **kw))


@router.delete("/clocks/{clock_id}", status_code=204)
async def delete_clock(clock_id: int, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await store.delete_clock(a.deps.pool, acc, clock_id):
        raise HTTPException(404, "没有这个钟")
    return Response(status_code=204)


# ── 醒来账、估价 ──

def _count_by_day(ats: list, tz: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for at in ats:
        d = at.astimezone(ZoneInfo(tz)).date().isoformat()
        out[d] = out.get(d, 0) + 1
    return out


@router.get("/companions/{cid}/wakes")
async def wakes(cid: UUID, days: int = 7, acc: UUID = Depends(account), a: Api = Depends(api)):
    await own_companion(a, acc, cid)
    pool, now = a.deps.pool, a.deps.now()
    tz = await _tz(a, cid)
    rows = await pool.fetch("SELECT w.at, w.reason, w.outcome, w.cost_usd, w.clock_id, w.detail, w.message_id, w.conversation_id, m.text "
                            "FROM wake_log w LEFT JOIN chat_messages m ON m.id = w.message_id "
                            "WHERE w.companion_id = $1 AND w.at >= $2 ORDER BY w.at DESC LIMIT 500",
                            cid, now - timedelta(days=max(1, min(days, 60))))
    today = now.astimezone(ZoneInfo(tz)).date()
    todays = [r for r in rows if r["at"].astimezone(ZoneInfo(tz)).date() == today]
    return {
        "today": {"woke": sum(r["outcome"] in store.WOKE for r in todays),
                  "said": sum(r["outcome"] == "said" for r in todays),
                  "cost_usd": round(sum(r["cost_usd"] for r in todays), 4)},
        "items": [{"at": r["at"].isoformat(), "reason": r["reason"], "outcome": r["outcome"],
                   "cost_usd": r["cost_usd"], "message_id": r["message_id"] if r["text"] is not None else None,
                   "text": r["text"],
                   "conversation_id": str(r["conversation_id"]) if r["conversation_id"] else None} for r in rows],
        "silent_by_day": _count_by_day([r["at"] for r in rows if r["outcome"] == "silent"], tz),
        "skipped_user_clocks": [{"at": r["at"].isoformat(), "note": json.loads(r["detail"] or "{}").get("note", "")}
                                for r in rows if r["reason"] == "user" and r["outcome"] == "skipped_cap"],
    }


@router.get("/companions/{cid}/patrol/estimate")
async def estimate(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """四档各「一个月最多大概醒几次、花多少」，外加现在这一档（带高级设置里改过的数字）。"""
    pool, now = a.deps.pool, a.deps.now()
    await own_companion(a, acc, cid)
    s = Settings.from_dict(await archive.get_settings(pool, cid))
    conv = await pool.fetchval("SELECT id FROM conversations WHERE companion_id = $1 LIMIT 1", cid)
    try:
        route = await resolve_route(a.deps.keys, Scope(acc, cid, conv or cid))
    except TrialOver:
        return {"model": None, "levels": None, "current": None}
    avg = await pool.fetchval("SELECT avg(cost_usd) FROM wake_log WHERE companion_id = $1 AND at >= $2 "
                              "AND outcome IN ('said', 'silent') AND cost_usd > 0", cid, now - timedelta(days=30))
    each = per_wake_usd(route.chat_model, avg)
    mine = wakes_per_day(patrol_numbers(s), s.sleep_from, s.sleep_to) * DAYS
    return {"model": route.chat_model, "per_wake_usd": each,
            "levels": levels_table(route.chat_model, avg, s.sleep_from, s.sleep_to),
            "current": {"level": s.patrol_level, "wakes_per_month": mine,
                        "usd_per_month": round(mine * each, 2) if each is not None else None}}


# ── 哨兵 ──

@router.post("/conversations/{conv}/focus/start", status_code=201)
async def focus_start(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{minutes, label}：它写一串越来越急的提醒交回来（手机里的屏幕使用时间小插件按分心分钟数一条条弹）。"""
    scope = await own_conversation(a, acc, conv)
    try:
        minutes = int(body.get("minutes") or 0)
    except (TypeError, ValueError):
        minutes = 0
    if not 5 <= minutes <= 600:
        raise HTTPException(400, "专注时长要在 5 到 600 分钟之间")
    try:
        route = await resolve_route(a.deps.keys, scope, chore="focus")
    except TrialOver:
        route = None
    s = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion))
    day = a.deps.now().astimezone(ZoneInfo(s.tz)).date()
    fid, lines, lock_after, peek = await F.start(a.deps, route, get_adapter(a.deps, route) if route else None, scope,
                                                 minutes, str(body.get("label") or ""), day,
                                                 allow_lock=bool(body.get("allow_lock")),
                                                 lock_now=bool(body.get("lock_now")))   # 没钥匙也给出厂的几句，哨兵照样能响
    return {"id": str(fid), "lines": lines, "lock_after": lock_after, "peek_line": peek}


@router.post("/focus/{fid}/end", status_code=204)
async def focus_end(fid: UUID, body: dict = Body(default={}), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        times, mins = int(body.get("distracted_times") or 0), int(body.get("distracted_minutes") or 0)
    except (TypeError, ValueError):
        raise HTTPException(400, "分心次数和分钟数要是整数") from None
    if not await F.end(a.deps.pool, acc, fid, times=max(0, times), minutes=max(0, mins), now=a.deps.now(),
                       early=bool(body.get("early"))):
        raise HTTPException(404, "没有这次专注（或者已经结束了）")
    return Response(status_code=204)


@router.post("/focus/{fid}/said")
async def focus_said(fid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{items: [{key, at, text}]}：专注时手机替它弹过的话，回到 app 时报上来，按原时间存进聊天（同一个 key 只存一次）。"""
    items = body.get("items")
    if not isinstance(items, list) or len(items) > 50:
        raise HTTPException(400, "items 要是一个不超过 50 条的列表")
    added = await F.said(a.deps.pool, acc, fid, items, a.deps.now())
    if added is None:
        raise HTTPException(404, "没有这次专注")
    return {"added": added}
