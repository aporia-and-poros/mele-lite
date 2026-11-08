"""登录、账号、我的设定、钥匙串。"""
from __future__ import annotations

import json
import logging
import os
import secrets
from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response

from brain import accounts, archive, auth, avatars, chores as CH, context_line, media

from .deps import Api, account, api, bearer

log = logging.getLogger(__name__)
router = APIRouter()


def _bad(e: Exception) -> HTTPException:
    return HTTPException(400, str(e))


def _no_email_in_host(a: Api) -> None:
    """Host 单人模式没有邮箱登录：主人扫配对码进来（/host/pair）。"""
    if a.cfg.host_mode:
        raise HTTPException(404, "Mele Host 不用邮箱登录，请在 App 里扫配对码")


# ── 登录 ──

@router.post("/auth/email/code", status_code=204)
async def email_code(body: dict = Body(...), a: Api = Depends(api)):
    _no_email_in_host(a)
    try:
        email = auth.normalize_email(str(body.get("email") or ""))
        code = await auth.request_code(a.deps.pool, email, secret=a.cfg.secret, now=a.deps.now())
    except auth.AuthError as e:
        raise _bad(e) from e
    if a.cfg.send_code:
        await a.cfg.send_code(email, code)
    else:
        log.warning("login code for %s: %s（还没接发信服务，本机打印）", email, code)
    return Response(status_code=204)


@router.post("/auth/email/verify")
async def email_verify(body: dict = Body(...), a: Api = Depends(api)):
    _no_email_in_host(a)
    pool, now = a.deps.pool, a.deps.now()
    try:
        acc = await auth.verify_code(pool, str(body.get("email") or ""), str(body.get("code") or ""),
                                     secret=a.cfg.secret, now=now)
    except auth.AuthError as e:
        raise _bad(e) from e
    if body.get("device_id"):
        await auth.claim_trial_device(pool, acc, str(body["device_id"]), secret=a.cfg.secret)
    token = await auth.new_session(pool, acc, secret=a.cfg.secret, now=now)
    return {"token": token, "account": await _me(a, acc)}


@router.post("/auth/apple")
async def apple():
    raise HTTPException(501, "Apple 登录等 app 有了标识再接")


@router.post("/auth/logout", status_code=204)
async def logout(request: Request, acc: UUID = Depends(account), a: Api = Depends(api)):
    await auth.logout(a.deps.pool, bearer(request), secret=a.cfg.secret)
    return Response(status_code=204)


# ── 账号 ──

async def _me(a: Api, acc: UUID) -> dict:
    pool = a.deps.pool
    r = await pool.fetchrow("SELECT email, plan FROM accounts WHERE id = $1", acc)
    out = {"id": str(acc), "email": r["email"], "plan": r["plan"]}
    keys = a.deps.keys
    policy = getattr(keys, "policy", None)
    if policy is not None and not a.cfg.host_mode:          # 免费额度（Host 没有）：只给比例和下次补的时间，不给轮数（09-28）
        comps = await accounts.list_companions(pool, acc)
        tz = (await archive.get_settings(pool, comps[0])).get("tz") or "UTC" if comps else "UTC"
        now = a.deps.now()
        bal = await auth.trial_balance(pool, acc, now, tz, policy)
        out["trial"] = {"ratio": round(min(1.0, bal / policy.full), 3),
                        "refill_at": auth.next_refill(now, tz, policy).isoformat()}
    return out


@router.get("/me")
async def me(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await _me(a, acc)


@router.delete("/me", status_code=204)
async def delete_me(acc: UUID = Depends(account), a: Api = Depends(api)):
    for conv in [r["id"] for r in await a.deps.pool.fetch("SELECT id FROM conversations WHERE account_id = $1", acc)]:
        a.rooms.drop(conv)
    companions = await accounts.list_companions(a.deps.pool, acc)
    await accounts.delete_account(a.deps.pool, acc)
    for cid in companions:
        avatars.remove(a.cfg.files_dir, cid)
    return Response(status_code=204)


@router.get("/me/export")
async def export(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await accounts.export_account(a.deps.pool, acc)


@router.get("/me/profile")
async def get_profile(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await accounts.get_profile(a.deps.pool, acc)


@router.put("/me/profile")
async def put_profile(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        return await accounts.save_profile(a.deps.pool, acc, body)
    except (ValueError, TypeError) as e:
        raise _bad(e) from e


# ── 看图和画图（10-15，brain/media.py）──

@router.get("/me/media")
async def get_media(acc: UUID = Depends(account), a: Api = Depends(api)):
    return await media.public(a.deps.pool, acc, a.deps.now())


@router.put("/me/media")
async def put_media(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        await media.put(a.deps.pool, acc, body)
    except LookupError as e:
        raise HTTPException(404, str(e)) from e
    except ValueError as e:
        raise _bad(e) from e
    return await media.public(a.deps.pool, acc, a.deps.now())


@router.put("/me/media/direct/{slot}")
async def put_media_direct(slot: str, body: dict | None = Body(default=None), acc: UUID = Depends(account), a: Api = Depends(api)):
    """直接填看图 / 画图钥匙（10-16）。body 空 = 清掉；回 {..., check: {ok, message}}"""
    try:
        checked = await media.put_direct(a.deps.pool, getattr(a.deps.keys, "box", None), acc, slot,
                                         body if body else None)
    except ValueError as e:
        raise _bad(e) from e
    return {**await media.public(a.deps.pool, acc, a.deps.now()), "check": checked}


# ── 钥匙串 ──

def _key(k: auth.KeyInfo, table: dict | None = None) -> dict:
    t = (table or {}).get("chores", {})
    mine = [c for c in CH.CHORES if t.get(c) == str(k.id)]
    if k.provider in auth.VOICE_PROVIDERS:
        mine = ["voice"]                                   # 一个账号一家只有一把声音 key（ElevenLabs / MiniMax），声音就是它
    return {"id": str(k.id), "provider": k.provider, "chat_model": k.chat_model, "base_url": k.base_url,
            "last4": k.last4, "ledger_model": k.ledger_model, "chores": mine, "can": CH.can(k.provider),
            "draw_model": (table or {}).get("draw_model", "") if "draw" in mine else ""}


@router.get("/keys")
async def list_keys(acc: UUID = Depends(account), a: Api = Depends(api)):
    table = await CH.get_table(a.deps.pool, acc)
    return [_key(k, table) for k in await auth.list_keys(a.deps.pool, acc)]


@router.post("/keys", status_code=201)
async def add_key(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    try:
        auth.check_key_input(str(body.get("provider") or ""), str(body.get("api_key") or ""),
                             str(body.get("chat_model") or ""))
        if a.deps.probe_keys:
            await auth.probe_key(a.deps.adapter_for, str(body.get("provider") or ""), str(body.get("api_key") or ""),
                                 str(body.get("chat_model") or "").strip(),
                                 (str(body["base_url"]).strip() or None) if body.get("base_url") else None)
        kid = await auth.add_key(a.deps.pool, a.cfg.box, acc, provider=str(body.get("provider") or ""),
                                 api_key=str(body.get("api_key") or ""),
                                 chat_model=str(body.get("chat_model") or "").strip(),
                                 base_url=(str(body["base_url"]).strip() or None) if body.get("base_url") else None,
                                 ledger_model=str(body.get("ledger_model") or ""))
    except auth.AuthError as e:
        raise _bad(e) from e
    table = await CH.get_table(a.deps.pool, acc)
    return next(_key(k, table) for k in await auth.list_keys(a.deps.pool, acc) if k.id == kid)


@router.patch("/keys/{key_id}")
async def patch_key(key_id: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """改活（chores / draw_model，10-15）、换聊天模型（chat_model，10-29）；旧 App 还会发 ledger_model。"""
    pool = a.deps.pool
    k = next((x for x in await auth.list_keys(pool, acc) if x.id == key_id), None)
    if k is None:
        raise HTTPException(404, "没有这把钥匙")
    if "ledger_model" in body:
        await auth.set_ledger_model(pool, acc, key_id, str(body.get("ledger_model") or ""))
    if "chat_model" in body and k.provider not in auth.VOICE_PROVIDERS:
        try:
            await auth.set_chat_model(pool, acc, key_id, str(body.get("chat_model") or ""))
        except auth.AuthError as e:
            raise _bad(e) from e
    table, moved = await CH.get_table(pool, acc), []
    if "chores" in body and k.provider not in auth.VOICE_PROVIDERS:
        try:
            table["chores"], moved = CH.assign(table["chores"], str(key_id), k.provider, [str(c) for c in body["chores"] or []])
        except ValueError as e:
            raise _bad(e) from e
    if "draw_model" in body:
        table["draw_model"] = str(body.get("draw_model") or "").strip()[:100]
    await CH.save_table(pool, acc, table)
    k = next(x for x in await auth.list_keys(pool, acc) if x.id == key_id)
    return {**_key(k, table), "moved": moved}


@router.delete("/keys/{key_id}", status_code=204)
async def delete_key(key_id: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not await auth.delete_key(a.deps.pool, acc, key_id):
        raise HTTPException(404, "没有这把钥匙")
    return Response(status_code=204)


@router.get("/models")
async def models(provider: str | None = None, acc: UUID = Depends(account)):
    """加钥匙时选模型：每家有哪些、每百万 token 多少美元（输入 / 缓存命中 / 输出）。"""
    from llm.catalog import CATALOG
    return [{"id": m.id, "provider": m.provider, "label": m.label, "price_in": m.price_in,
             "price_cache_read": m.price_cache_read, "price_out": m.price_out, "thinking": m.thinking}
            for m in CATALOG.values() if provider in (None, m.provider)]


# ── TA 那边（09-28）──

@router.put("/me/context/{kind}", status_code=204)
async def put_context(kind: str, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """手机报：weather / place / calendar / health，每样覆盖最新一份。"""
    if kind not in ("weather", "place", "calendar", "health"):
        raise HTTPException(400, "不认识这一样")
    await context_line.save(a.deps.pool, acc, kind, body, a.deps.now())
    return Response(status_code=204)


async def _hook_token(a: Api, acc: UUID, *, reset: bool = False) -> str:
    pool = a.deps.pool
    box = await pool.fetchval("SELECT hook_box FROM accounts WHERE id = $1", acc)
    if box and not reset:
        return a.cfg.box.unlock(bytes(box))
    token = secrets.token_urlsafe(24)
    await pool.execute("UPDATE accounts SET hook_hash = $2, hook_box = $3 WHERE id = $1",
                       acc, auth._hash(a.cfg.secret, "hook", token), a.cfg.box.lock(token))
    return token


def _public_base(request: Request) -> str:
    """对外地址：Host 有 NEWAPP_PUBLIC_URL 就用它（10-17：Caddy / 隧道后面 request 看到的是 http://，快捷指令拿去连不上）"""
    return os.environ.get("NEWAPP_PUBLIC_URL", "").strip().rstrip("/") or str(request.base_url).rstrip("/")


@router.get("/me/hook")
async def get_hook(request: Request, acc: UUID = Depends(account), a: Api = Depends(api)):
    """快捷指令入口：网址 + 口令（第一次拿时生成）。"""
    return {"url": _public_base(request) + "/hooks/context", "token": await _hook_token(a, acc)}


@router.post("/me/hook/reset")
async def reset_hook(request: Request, acc: UUID = Depends(account), a: Api = Depends(api)):
    return {"url": _public_base(request) + "/hooks/context", "token": await _hook_token(a, acc, reset=True)}


@router.post("/hooks/context", status_code=204)
async def hook_context(request: Request, a: Api = Depends(api)):
    """用户自己的快捷指令往这报一句（「在健身房」）。认的是快捷指令口令，不是登录凭证。
    body 可以是 {"text": "…"} 或者直接一段文字。"""
    token = (request.headers.get("authorization") or "").removeprefix("Bearer ").strip()
    acc = await a.deps.pool.fetchval("SELECT id FROM accounts WHERE hook_hash = $1",
                                     auth._hash(a.cfg.secret, "hook", token)) if token else None
    if acc is None:
        raise HTTPException(401, "口令不对")
    raw = (await request.body()).decode("utf-8", "replace").strip()
    try:
        text = str(json.loads(raw).get("text") or "") if raw.startswith("{") else raw
    except (ValueError, AttributeError):
        text = raw
    text = text.strip()[:200]
    if not text:
        raise HTTPException(400, "要带一句话")
    await context_line.save(a.deps.pool, acc, "shortcut", {"text": text}, a.deps.now())
    return Response(status_code=204)
