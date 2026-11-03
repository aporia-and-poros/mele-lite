"""打电话（10-31，第 3 步：连着 Host 时你打给 TA）。设计 docs/superpowers/specs/2026-10-31-call-design.md。

手机那边跟 Lite 本机一样：判断说完、灰字、一条时间线连着放、插嘴都在手机上。Host 管三样手机没有的：
- 听：说完那句的录音（AAC）传上来，Host 用账号钥匙串里的 ElevenLabs key 走 Scribe 转写（/call/hear）
- 想：/call/turn 跑一轮，大脑边写边切句子，一句一行按事件流推给手机（line）
- 说：/call/tts 拿 Host 的 ElevenLabs key 流式合成，24k PCM 边到边转给手机；顺手存一份，通话记录里能重听
被打断（/call/cut）、准确字回来（/call/fix）、挂断（/call/end）、通话记录（/calls）跟 Lite 的 LocalBrain / LocalCalls 一个意思。"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import struct
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import Response, StreamingResponse

from brain import archive, call_speech, voice as V
from brain.call_speech import CallCtx
from brain.monologue import _ZH_PRONOUN
from brain.settings import Settings
from brain.turn import run_turn
from llm.tts import NOTE_MODEL, TTSError

from .deps import Api, account, api, own_conversation

router = APIRouter()
log = logging.getLogger(__name__)

FAST_MODEL = "eleven_flash_v2_5"
ACTIVE: dict[str, CallCtx] = {}            # 通话编号 → 正在跑 / 刚跑完的那一轮（打断、改字要找它）
TASKS: dict[str, asyncio.Task] = {}        # 通话编号 → 那一轮的任务（挂断时等它收完，纸条排在后面）


def _audio_dir(a: Api) -> Path:
    d = (a.deps.files_dir or Path(".local/files")) / "calls"
    d.mkdir(parents=True, exist_ok=True)
    return d


def audio_name(call_id: str, line: str) -> str:
    """TA 那一句的声音：通话编号 + 这句话（同一通里同一句共用一个）"""
    return "call-ta-" + hashlib.sha256(f"{call_id}\n{line}".encode()).hexdigest()[:24]


async def _scope(a: Api, acc: UUID, conv: UUID):
    scope = await own_conversation(a, acc, conv)
    if scope.companion is None:
        raise HTTPException(400, "群里还不能打电话")
    return scope


@router.get("/conversations/{conv}/call/info")
async def info(conv: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """接通前问一声：Host 能不能替手机听（Scribe）、能不能出声（ElevenLabs），TA 用哪把嗓子、哪种电话声音"""
    scope = await _scope(a, acc, conv)
    settings = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion))
    try:
        await V.engine(a.deps, acc)
        has = True
    except V.VoiceError:
        has = False
    return {"hear": has, "voice": has, "call_voice": settings.call_voice, "lang": settings.lang,
            "voice_id": settings.voice_id or V.default_voice()}


@router.post("/conversations/{conv}/call/hear")
async def hear(conv: UUID, audio: UploadFile = File(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """说完那一句的准确转写。转不出来给空字符串，手机就用它自己识别的那句。"""
    await _scope(a, acc, conv)
    data = await audio.read()
    if not data or len(data) > 4 * 1024 * 1024:
        raise HTTPException(400, "这段录音不对")
    try:
        tts, _own = await V.engine(a.deps, acc)
        got = await tts.transcribe(data, audio.content_type or "audio/mp4", name="call.m4a")
    except (V.VoiceError, TTSError) as e:
        log.info("call hear failed: %s", getattr(e, "kind", e))
        return {"text": ""}
    text = re.sub(r"\s*[(\[（][^)\]）]{1,30}[)\]）]\s*", " ", got.get("text") or "").strip()
    return {"text": text}


@router.post("/conversations/{conv}/call/turn")
async def turn(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """电话里说完一句：跑一轮，切好的句子按事件流推回去（line），最后 done。手机断开了这一轮照样跑完、存下。"""
    scope = await _scope(a, acc, conv)
    text = str(body.get("text") or "").strip()
    call_id = str(body.get("call_id") or "").strip()[:64]
    answered = bool(body.get("answered"))           # TA 打来、你接了（第 4 步）：没有你说的话，TA 先开口
    if (not text and not answered) or not call_id:
        raise HTTPException(400, "要带 text 和 call_id")
    aside = None
    if answered:
        settings = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion))
        pronoun = _ZH_PRONOUN.get(settings.user_pronoun, "TA") if settings.lang == "zh" else settings.user_pronoun
        aside = call_speech.answered_nudge(settings.lang, pronoun, str(body.get("reason") or ""))
    q: asyncio.Queue = asyncio.Queue()
    ctx = CallCtx(call_id, on_line=lambda line: q.put_nowait({"type": "line", "text": line}))
    prev = TASKS.get(call_id)
    ACTIVE[call_id] = ctx

    async def emit(ev: dict) -> None:
        await a.rooms.publish(conv, ev)            # 聊天页开着的话跟着刷新
        if ev.get("type") == "error":
            q.put_nowait({"type": "error", "message": ev.get("message", "")})

    async def run() -> None:
        try:
            if prev is not None and not prev.done():         # 上一轮（被打断的）先收完
                await asyncio.wait([prev], timeout=20)
            room = a.rooms.room(conv)
            if room.running is not None and not room.running.done():   # 打字那边正在跑：等它说完
                await asyncio.wait([room.running], timeout=60)
            await run_turn(a.deps, scope, text, emit, call=ctx, aside=aside)
        except Exception:
            log.exception("call turn crashed")
            q.put_nowait({"type": "error", "message": "这一句没接上，再说一遍"})
        finally:
            q.put_nowait({"type": "done"})
            q.put_nowait(None)

    TASKS[call_id] = asyncio.create_task(run())

    async def stream():
        while (ev := await q.get()) is not None:
            yield f"data: {json.dumps(ev, ensure_ascii=False)}\n\n"
    return StreamingResponse(stream(), media_type="text/event-stream")


@router.post("/conversations/{conv}/call/cut")
async def cut(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """她开口打断 / 挂了：spoken = 已经念出来（或正念着）的那几句。还在写的停下；写完存好了的改成只留念到的。"""
    await _scope(a, acc, conv)
    ctx = ACTIVE.get(str(body.get("call_id") or ""))
    if ctx is None:
        return {"ok": False}
    spoken = [str(x) for x in body.get("spoken") or []]
    ctx.stop(spoken)
    if ctx.assistant_msg is not None and len(spoken) < len(ctx.lines):
        said = ctx.saved_text()
        await archive.set_call_text(a.deps.pool, ctx.assistant_msg, said, {"id": ctx.id, "cut": True})
    return {"ok": True}


@router.post("/conversations/{conv}/call/fix")
async def fix(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """准确的字回来了（比 1.5 秒慢的那次）：把存档里手机识别的那句换掉"""
    await _scope(a, acc, conv)
    ctx = ACTIVE.get(str(body.get("call_id") or ""))
    text = str(body.get("text") or "").strip()
    if ctx is None or not text:
        return {"ok": False}
    for _ in range(50):                            # 这一轮刚开始，你那句可能还没存下
        if ctx.user_msg is not None:
            break
        await asyncio.sleep(0.1)
    if ctx.user_msg is None:
        return {"ok": False}
    await archive.set_call_text(a.deps.pool, ctx.user_msg, text, {"id": ctx.id})
    return {"ok": True}


@router.post("/conversations/{conv}/call/end")
async def end(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """挂了：聊天里多一行「📞 通话时长」，正文是递给它的纸条（不然挂了以后你打的字它还当电话、用电话腔回）"""
    scope = await _scope(a, acc, conv)
    call_id = str(body.get("call_id") or "")
    seconds = max(0, int(body.get("seconds") or 0))
    task = TASKS.pop(call_id, None)
    if task is not None and not task.done():
        await asyncio.wait([task], timeout=30)
    ACTIVE.pop(call_id, None)
    lang = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion)).lang
    m = await archive.add_message(a.deps.pool, conv, "user", call_speech.hang_up_note(seconds, lang), now=a.deps.now(),
                                  call={"id": call_id, "end": True, "seconds": seconds,
                                        "line": call_speech.duration_line(seconds, lang)})
    await a.rooms.publish(conv, {"type": "done"})
    return {"message": m.id}


@router.post("/conversations/{conv}/call/tts")
async def tts(conv: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """一句一合成：Host 的 ElevenLabs key 流式合成，24k 16 位 PCM 边到边转给手机；收齐了存一份 wav 给通话记录"""
    scope = await _scope(a, acc, conv)
    text = str(body.get("text") or "").strip()
    if not text:
        raise HTTPException(400, "这句是空的")
    settings = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion))
    try:
        engine, own = await V.engine(a.deps, acc)
    except V.VoiceError as e:
        raise HTTPException(403, e.kind) from None
    if not own and await V.quota(a.deps.pool, acc) < len(text):
        raise HTTPException(402, "quota")
    expressive = (body.get("kind") or settings.call_voice) == "expressive"
    model = NOTE_MODEL if expressive else FAST_MODEL
    said = V.DEFAULT_TAG + text if expressive else text
    voice_id = settings.voice_id or V.default_voice()
    chunks = engine.stream_pcm(said, voice_id, model, previous_text=str(body.get("prev") or "") or None)
    try:
        first = await chunks.__anext__()          # 第一块先拿到：出错能回正经的状态码，不是半截流
    except StopAsyncIteration:
        first = b""
    except TTSError as e:
        raise HTTPException(502 if e.kind in ("server", "network") else 400, e.kind) from None
    call_id = str(body.get("call_id") or "")
    path = _audio_dir(a) / (audio_name(call_id, text) + ".wav") if call_id else None

    async def relay():
        got = bytearray(first)
        yield first
        try:
            async for c in chunks:
                got += c
                yield c
        except TTSError as e:
            log.info("call tts broke midway: %s", e.kind)
            return
        if not own:
            await a.deps.pool.execute("UPDATE voice_quota SET chars_left = GREATEST(chars_left - $2, 0) WHERE account_id = $1",
                                      acc, len(text))
        if path is not None and got:
            path.write_bytes(_wav(bytes(got)))
    return StreamingResponse(relay(), media_type="audio/L16;rate=24000;channels=1")


def _wav(pcm: bytes, rate: int = 24_000) -> bytes:
    pcm = pcm[: len(pcm) - len(pcm) % 2]
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
            + b"data" + struct.pack("<I", len(pcm)) + pcm)


@router.get("/call/audio/{name}")
async def audio(name: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    if not re.fullmatch(r"call-ta-[0-9a-f]{24}", name):
        raise HTTPException(404, "没有这段")
    p = _audio_dir(a) / f"{name}.wav"
    if not p.exists():
        raise HTTPException(404, "没有这段")
    return Response(p.read_bytes(), media_type="audio/wav")


def group_calls(msgs: list[archive.StoredMsg], have_audio) -> list[dict]:
    """按通话编号收拢一通（跟 Lite 的 LocalCalls 一样）：没留下挂断那条的也收，标出来"""
    out: list[dict] = []
    cur: dict | None = None

    def close(end: archive.StoredMsg | None) -> None:
        nonlocal cur
        if cur is None:
            return
        lines = []
        for m in cur["rows"]:
            if m.role == "user":
                lines.append({"mine": True, "text": m.text, "audio": None})
                continue
            for part in [p for p in m.text.split("\n") if p]:
                plain = part[:-2] if part.endswith("——") else part
                name = audio_name(cur["id"], plain)
                lines.append({"mine": False, "text": part, "audio": f"call/audio/{name}" if have_audio(name) else None})
        seconds = (end.call or {}).get("seconds") if end is not None else None
        if seconds is None:
            seconds = int((cur["last"] - cur["first"]).total_seconds())
        out.append({"id": cur["id"], "at": cur["first"].isoformat(), "seconds": seconds,
                    "end_message": end.id if end is not None else None, "lines": lines})
        cur = None

    for m in msgs:
        c = m.call or {}
        if c.get("ring"):                          # TA 打来没接通的那行（第 4 步）不是一通电话
            close(None)
            continue
        if c.get("end"):
            if cur is None:
                cur = {"id": c.get("id") or f"end-{m.id}", "first": m.created_at, "last": m.created_at, "rows": []}
            close(m)
        elif c:
            if cur is not None and cur["id"] != c.get("id"):
                close(None)
            if cur is None:
                cur = {"id": c.get("id"), "first": m.created_at, "last": m.created_at, "rows": []}
            cur["rows"].append(m)
            cur["last"] = m.created_at
        elif cur is not None:
            close(None)
    close(None)
    return out


@router.get("/conversations/{conv}/calls")
async def calls(conv: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    """通话记录：新的在前，藏起来的不给"""
    await _scope(a, acc, conv)
    msgs = [m for m in await archive.after(a.deps.pool, conv, 0, 100_000) if m.call]
    hidden = set((await archive.get_state(a.deps.pool, conv)).get("calls_hidden") or [])
    folder = _audio_dir(a)
    got = group_calls(msgs, lambda name: (folder / f"{name}.wav").exists())
    return [c for c in reversed(got) if c["id"] not in hidden]


@router.post("/conversations/{conv}/calls/{call_id}/hide")
async def hide(conv: UUID, call_id: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    """左滑「藏起来」：只藏通话记录页，聊天那行和它的记性都不动"""
    await _scope(a, acc, conv)
    state = await archive.get_state(a.deps.pool, conv)
    state["calls_hidden"] = sorted(set(state.get("calls_hidden") or []) | {call_id})
    await archive.save_state(a.deps.pool, conv, state)
    return {"ok": True}


# ── TA 打给你（第 4 步）：手机收到 VoIP 推送、系统横幅在响的时候来问 / 接 / 拒 ──

def _ringer(a: Api):
    if a.deps.ringer is None:
        raise HTTPException(409, "这台 Host 没开打电话")
    return a.deps.ringer


@router.get("/conversations/{conv}/call/ring/{call_id}")
async def ring_state(conv: UUID, call_id: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    """这通还在不在响：ringing / answered / missed / declined / withdrawn；Host 重启过、早清掉了 = gone"""
    await _scope(a, acc, conv)
    r = _ringer(a).rings.get(call_id)
    if r is None or r.conversation != conv:
        return {"state": "gone"}
    return {"state": r.state, "reason": r.reason, "companion": str(r.companion)}


@router.post("/conversations/{conv}/call/ring/{call_id}/answer")
async def ring_answer(conv: UUID, call_id: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _scope(a, acc, conv)
    return {"ok": await _ringer(a).answer(call_id)}


@router.post("/conversations/{conv}/call/ring/{call_id}/decline")
async def ring_decline(conv: UUID, call_id: str, acc: UUID = Depends(account), a: Api = Depends(api)):
    await _scope(a, acc, conv)
    return {"ok": await _ringer(a).decline(call_id)}
