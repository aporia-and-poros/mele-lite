"""声音的接口（10-03，声音第一块）：取语音、念给我听、官方嗓子、描述一把、存嗓子、额度、ElevenLabs key。"""
from __future__ import annotations

import re
from uuid import UUID

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse

from brain import archive, auth
from brain import voice as V
from brain import voice_in
from brain.bubbles import split_reply
from brain.settings import Settings
from llm.tts import TTSError, tts_cost

from .deps import Api, account, api, own_companion, own_conversation

router = APIRouter()
ERRORS = {"quota": "声音额度用完了", "no_key": "还没有可用的声音钥匙", "no_voice": "还没给它选嗓子",
          "auth": "ElevenLabs 的 key 不对或者没开权限", "server": "ElevenLabs 那边出错了，等会儿再试",
          "network": "连不上 ElevenLabs", "bad_request": "这句念不了", "too_long": "语音最长 2 分钟",
          "missing_permissions": "这把 ElevenLabs key 少了权限：在 ElevenLabs 后台给它打开 Text to Speech、Speech to Text 和 Voices"}


def _err(kind: str, status: int = 400) -> HTTPException:
    return HTTPException(402 if kind == "quota" else status, ERRORS.get(kind, kind))


@router.get("/voice/clips/{cid}")
async def clip(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    c = await V.get_clip(a.deps.pool, acc, cid)
    if c is None:
        raise HTTPException(404, "没有这段")
    return FileResponse(c.path, media_type="audio/mpeg", headers={"Cache-Control": "private, max-age=604800"})


@router.post("/messages/{mid}/speak")
async def speak(mid: int, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """念给我听：{index} = 它那条消息的第几个气泡。念过的直接回。语音条点播放也走这里（10-31 按需念）。"""
    pool = a.deps.pool
    row = await pool.fetchrow(
        """SELECT m.text, coalesce(m.speaker_id, c.companion_id) AS companion_id FROM chat_messages m JOIN conversations c ON c.id = m.user_id
           WHERE m.id = $1 AND c.account_id = $2 AND m.role = 'assistant'""", mid, acc)
    if row is None:
        raise HTTPException(400, "只能念它说的话")
    s = Settings.from_dict(await archive.get_settings(pool, row["companion_id"]))
    bubbles = split_reply(row["text"], s.max_bubbles, s.long_mode)
    i = int(body.get("index", -1))
    if not 0 <= i < len(bubbles):
        raise HTTPException(400, "没有这一条")
    note = V.is_voice(bubbles[i])      # 语音条（10-31 按需念）：点开那一下才念，带上前后句念得顺，念好挂在这条消息上
    near = lambda j: V.as_text(bubbles[j]) if note and 0 <= j < len(bubbles) else None
    text = V.body(bubbles[i]) if note else bubbles[i]
    try:
        c = await V.speak(a.deps, acc, text=text, voice_id=s.voice_id, purpose="note" if note else "speak", message_id=mid,
                          prev=near(i - 1), nxt=near(i + 1))
    except V.VoiceError as e:
        raise _err(e.kind) from e
    return c.public()


@router.get("/voice/presets")
async def presets(lang: str = "zh", acc: UUID = Depends(account)):
    return V.presets_public("en" if lang == "en" else "zh")


@router.get("/voice/presets/{key}/preview")
async def preset_preview(key: str, lang: str = "zh", acc: UUID = Depends(account)):
    if key not in {p["key"] for p in V.PRESETS}:
        raise HTTPException(404, "没有这把")
    return FileResponse(V.PRESET_DIR / f"{key}-{'en' if lang == 'en' else 'zh'}.mp3", media_type="audio/mpeg",
                        headers={"Cache-Control": "public, max-age=2592000"})


async def _can_design(a: Api, acc: UUID) -> bool:
    """设计出来的嗓子占 ElevenLabs 账号的声音位（有上限）：只给会员和自带 key 的人。"""
    if await auth.voice_key(a.deps.pool, a.cfg.box, acc):
        return True
    return await a.deps.pool.fetchval("SELECT plan FROM accounts WHERE id = $1", acc) == "member"


@router.post("/voice/design")
async def design(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{description} → 三把试听（base64 mp3）。"""
    desc = str(body.get("description") or "").strip()
    if not 8 <= len(desc) <= 400:
        raise HTTPException(400, "描述写 8～400 个字")
    if not await _can_design(a, acc):
        raise HTTPException(403, "描述一把嗓子是会员或者自带 ElevenLabs key 才能用的")
    try:
        tts, own = await V.engine(a.deps, acc)
        previews = await tts.design(desc)
    except V.VoiceError as e:
        raise _err(e.kind) from e
    except TTSError as e:
        raise _err(e.kind, 502) from e
    await a.deps.pool.execute("INSERT INTO voice_usage (account_id, purpose, model, chars, cost_usd, own_key) "
                              "VALUES ($1, 'design', 'eleven_ttv_v3', $2, $3, $4)", acc, len(desc),
                              tts_cost(len(desc), "eleven_v4"), own)
    return previews


@router.post("/companions/{cid}/voice")
async def choose(cid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{voice_id, name} 选现成的；或 {generated_voice_id, name, description} 存一把设计出来的（先看声音位够不够）。"""
    await own_companion(a, acc, cid)
    pool = a.deps.pool
    name = re.sub(r"\s+", " ", str(body.get("name") or "")).strip()[:30]
    voice_id = str(body.get("voice_id") or "").strip()
    if body.get("generated_voice_id"):
        if not await _can_design(a, acc):
            raise HTTPException(403, "描述一把嗓子是会员或者自带 ElevenLabs key 才能用的")
        try:
            tts, _ = await V.engine(a.deps, acc)
            used, limit = await tts.slots()
            if limit and used >= limit:
                raise HTTPException(409, "声音位满了，先删掉一把再存")
            voice_id = await tts.save_design(name or "Mele voice", str(body.get("description") or "")[:400],
                                             str(body["generated_voice_id"]))
        except V.VoiceError as e:
            raise _err(e.kind) from e
        except TTSError as e:
            raise _err(e.kind, 502) from e
    if not voice_id:
        raise HTTPException(400, "要给 voice_id 或 generated_voice_id")
    s = Settings.from_dict(await archive.get_settings(pool, cid))
    s.voice_id, s.voice_name = voice_id, name
    await archive.save_settings(pool, cid, s.to_dict())
    return {"voice_id": voice_id, "voice_name": name}


@router.get("/voice/quota")
async def quota(acc: UUID = Depends(account), a: Api = Depends(api)):
    own = bool(await auth.voice_key(a.deps.pool, a.cfg.box, acc))
    return {"chars_left": await V.quota(a.deps.pool, acc), "own_key": own}


@router.post("/keys/elevenlabs", status_code=201)
async def add_key(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    key = str(body.get("api_key") or "").strip()
    if a.deps.probe_keys and a.deps.tts_for is not None:
        try:
            await a.deps.tts_for(key).check()
        except TTSError as e:
            raise _err(e.kind) from e
    try:
        await auth.add_voice_key(a.deps.pool, a.cfg.box, acc, key)
    except auth.AuthError as e:
        raise HTTPException(400, str(e)) from e
    return {"last4": key[-4:]}


@router.post("/conversations/{conv}/voice", status_code=201)
async def voice_message(conv: UUID, audio: UploadFile = File(...), seconds: float = Form(0),
                        acc: UUID = Depends(account), a: Api = Depends(api)):
    """TA 发语音（声音第二块）：存录音、转文字、量语气 → {attachment, text}。App 再照常发消息：text + attachments=[id]。"""
    scope = await own_conversation(a, acc, conv)
    data = await audio.read(voice_in.MAX_BYTES + 1)
    lang = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion)).lang
    try:
        att, text = await voice_in.receive(a.deps, acc, conv, data, audio.content_type or "audio/mp4", seconds, lang)
    except V.VoiceError as e:
        raise _err(e.kind) from e
    return {"attachment": att.public(), "text": text}
