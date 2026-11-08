"""声音的接口（10-03，声音第一块）：取语音、念给我听、官方嗓子、描述一把、存嗓子、额度、声音 key。
11-08 加 MiniMax：设置页的接口都带 provider（elevenlabs / minimax，不带 = elevenlabs，老 App 照旧）；
念、电话、收语音按 TA 设定里的 voice_provider 走。"""
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
from llm.tts import MM_HOSTS, TTSError, minimax_region, models_public, tts_cost

from .deps import Api, account, api, own_companion, own_conversation

router = APIRouter()
_VOICE_ID = re.compile(r"[A-Za-z0-9_-]{8,64}")     # 会拼进 ElevenLabs 的地址里，只放这些字符
_MM_VOICE_ID = re.compile(r"[\w ().,'-]{1,120}")   # MiniMax 的官方嗓子带空格和括号（Chinese (Mandarin)_Warm_Girl），只放进请求体
ERRORS = {"quota": "声音额度用完了", "no_key": "还没有可用的声音钥匙", "no_voice": "还没给它选嗓子",
          "auth": "{who} 的 key 不对或者没开权限", "server": "{who} 那边出错了，等会儿再试",
          "network": "连不上 {who}", "bad_request": "这句念不了", "too_long": "语音最长 2 分钟",
          "voice_not_found": "{who} 找不到这把嗓子，检查一下音色 ID", "model_not_found": "这把 key 用不了这个模型，换一个试试",
          "missing_permissions": "这把 ElevenLabs key 少了权限：在 ElevenLabs 后台给它打开 Text to Speech、Speech to Text 和 Voices",
          "sensitive": "{who} 说这句内容过不了审，念不了", "slots": "{who} 的声音位满了，先在那边删掉一把再存"}
_WHO = {"elevenlabs": "ElevenLabs", "minimax": "MiniMax"}
SAMPLE = {"zh": "嗨，是我。今天过得怎么样？", "en": "Hey, it's me. How was your day?"}


def _provider(raw) -> str:
    return raw if raw in V.PROVIDERS else "elevenlabs"


def _voice_label(name: str) -> str:
    """音色库里的名字常常是「Adam - Distinct, Deep and Engaging」：只留破折号前面。"""
    return re.split(r"\s[-–—]\s", re.sub(r"\s+", " ", name).strip())[0][:30]


def _err(kind: str, status: int = 400, provider: str = "elevenlabs") -> HTTPException:
    return HTTPException(402 if kind == "quota" else status, ERRORS.get(kind, kind).replace("{who}", _WHO.get(provider, provider)))


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
    p = V.provider_of(s)
    try:
        c = await V.speak(a.deps, acc, text=text, voice_id=V.voice_id_of(s), purpose="note" if note else "speak", message_id=mid,
                          prev=near(i - 1), nxt=near(i + 1), model=await V.model_for(a.deps, acc, s), provider=p)
    except V.VoiceError as e:
        raise _err(e.kind, provider=p) from e
    return c.public()


@router.get("/voice/presets")
async def presets(lang: str = "zh", provider: str = "elevenlabs", acc: UUID = Depends(account)):
    return V.presets_public("en" if lang == "en" else "zh", _provider(provider))


@router.get("/voice/sample")
async def sample(voice_id: str, provider: str = "minimax", lang: str = "zh", acc: UUID = Depends(account), a: Api = Depends(api)):
    """试听（11-08）：MiniMax 没有现成的试听，拿 TA 自己的 key 念一句（念过存着，再点不花钱）。"""
    p, lang = _provider(provider), "en" if lang == "en" else "zh"
    if not (_MM_VOICE_ID if p == "minimax" else _VOICE_ID).fullmatch(voice_id):
        raise HTTPException(400, "这不像音色 ID")
    model = V.note_model(p)
    try:
        c = await V.speak(a.deps, acc, text=SAMPLE[lang], voice_id=voice_id, purpose="sample", model=model, provider=p)
    except V.VoiceError as e:
        raise _err(e.kind, provider=p) from e
    return FileResponse(c.path, media_type="audio/mpeg", headers={"Cache-Control": "private, max-age=604800"})


@router.get("/voice/presets/{key}/preview")
async def preset_preview(key: str, lang: str = "zh", acc: UUID = Depends(account)):
    if key not in {p["key"] for p in V.PRESETS}:
        raise HTTPException(404, "没有这把")
    return FileResponse(V.PRESET_DIR / f"{key}-{'en' if lang == 'en' else 'zh'}.mp3", media_type="audio/mpeg",
                        headers={"Cache-Control": "public, max-age=2592000"})


@router.get("/voice/library")
async def library(provider: str = "elevenlabs", lang: str = "zh", acc: UUID = Depends(account), a: Api = Depends(api)):
    """音色库（11-07）：TA 自己那把 key 账号里的嗓子。只给自带 key 的人，别把我们账号里的嗓子列出去。
    MiniMax 没有试听链接：preview 给 /voice/sample 的路径，App 点了再念。"""
    p = _provider(provider)
    try:
        tts, own = await V.engine(a.deps, acc, p)
        if not own:
            raise HTTPException(403, ERRORS["no_key"])
        got = await tts.voices()
    except V.VoiceError as e:
        raise _err(e.kind, 403, p) from e
    except TTSError as e:
        raise _err(e.kind, 400 if e.kind in ("auth", "missing_permissions") else 502, p) from e
    if p == "minimax":
        lang = "en" if lang == "en" else "zh"
        got = [{**v, "preview": v.get("preview") or V.sample_path(v["voice_id"], lang)} for v in got]
    return got


@router.get("/voice/models")
async def models(provider: str = "elevenlabs", acc: UUID = Depends(account), a: Api = Depends(api)):
    """能选的模型（11-07）。key 没开「看模型」权限、或者连不上，就给出厂那张表。MiniMax 就是固定那张。"""
    if _provider(provider) == "minimax":
        return models_public(provider="minimax")
    try:
        tts, own = await V.engine(a.deps, acc)
        return models_public(await tts.models() if own else None)
    except (V.VoiceError, TTSError):
        return models_public()


async def _can_design(a: Api, acc: UUID, provider: str = "elevenlabs") -> bool:
    """设计出来的嗓子占 ElevenLabs 账号的声音位（有上限）：只给会员和自带 key 的人。MiniMax 只有自带 key。"""
    if await auth.voice_key(a.deps.pool, a.cfg.box, acc, provider):
        return True
    return provider == "elevenlabs" and await a.deps.pool.fetchval("SELECT plan FROM accounts WHERE id = $1", acc) == "member"


@router.post("/voice/design")
async def design(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{description} → 三把试听（base64 mp3）。"""
    desc = str(body.get("description") or "").strip()
    p = _provider(body.get("provider"))
    if not 8 <= len(desc) <= 400:
        raise HTTPException(400, "描述写 8～400 个字")
    if not await _can_design(a, acc, p):
        raise HTTPException(403, "描述一把嗓子要自带 MiniMax key" if p == "minimax" else "描述一把嗓子是会员或者自带 ElevenLabs key 才能用的")
    try:
        tts, own = await V.engine(a.deps, acc, p)
        previews = await tts.design(desc)
    except V.VoiceError as e:
        raise _err(e.kind, provider=p) from e
    except TTSError as e:
        raise _err(e.kind, 502, p) from e
    await a.deps.pool.execute("INSERT INTO voice_usage (account_id, purpose, model, chars, cost_usd, own_key) "
                              "VALUES ($1, 'design', $5, $2, $3, $4)", acc, len(desc),
                              tts_cost(len(desc), "eleven_v4"), own, "minimax_design" if p == "minimax" else "eleven_ttv_v3")
    return previews


@router.post("/companions/{cid}/voice")
async def choose(cid: UUID, body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """{voice_id, name} 选现成的；或 {generated_voice_id, name, description} 存一把设计出来的（先看声音位够不够）。
    带 provider（11-08）：存进那家的那一格，并且这个 TA 从此用那家。"""
    await own_companion(a, acc, cid)
    pool = a.deps.pool
    p = _provider(body.get("provider"))
    name = _voice_label(str(body.get("name") or ""))
    voice_id = str(body.get("voice_id") or "").strip()
    if body.get("generated_voice_id"):
        if not await _can_design(a, acc, p):
            raise HTTPException(403, "描述一把嗓子要自带 MiniMax key" if p == "minimax" else "描述一把嗓子是会员或者自带 ElevenLabs key 才能用的")
        try:
            tts, _ = await V.engine(a.deps, acc, p)
            used, limit = await tts.slots()
            if limit and used >= limit:
                raise HTTPException(409, "声音位满了，先删掉一把再存")
            voice_id = await tts.save_design(name or "Mele voice", str(body.get("description") or "")[:400],
                                             str(body["generated_voice_id"]))
        except V.VoiceError as e:
            raise _err(e.kind, provider=p) from e
        except TTSError as e:
            raise _err(e.kind, 502, p) from e
    elif voice_id:
        if not (_MM_VOICE_ID if p == "minimax" else _VOICE_ID).fullmatch(voice_id):
            raise HTTPException(400, "这不像音色 ID" if p == "minimax" else "这不像音色 ID：只有英文字母和数字，一般 20 位")
        if not name:                                     # 手填的：查个名字，查不到不拦（公共音色查不到也念得出来）
            try:
                tts, _ = await V.engine(a.deps, acc, p)
                name = _voice_label(await tts.voice_name(voice_id))
            except (V.VoiceError, TTSError):
                pass
            name = name or voice_id[:8] + "…"
    if not voice_id:
        raise HTTPException(400, "要给 voice_id 或 generated_voice_id")
    s = Settings.from_dict(await archive.get_settings(pool, cid))
    if p == "minimax":
        s.mm_voice_id, s.mm_voice_name = voice_id, name
    else:
        s.voice_id, s.voice_name = voice_id, name
    s.voice_provider = p
    await archive.save_settings(pool, cid, s.to_dict())
    return {"voice_id": voice_id, "voice_name": name, "provider": p}


@router.get("/voice/quota")
async def quota(provider: str = "elevenlabs", acc: UUID = Depends(account), a: Api = Depends(api)):
    own = bool(await auth.voice_key(a.deps.pool, a.cfg.box, acc, _provider(provider)))
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


@router.post("/keys/minimax", status_code=201)
async def add_minimax_key(body: dict = Body(...), acc: UUID = Depends(account), a: Api = Depends(api)):
    """MiniMax 的 key（11-08）：国内版、国际版两边都试，认得的那边记下来（base_url）。不试打时（测试）按 region 存，默认国际版。"""
    key = str(body.get("api_key") or "").strip()
    region = body.get("region") if body.get("region") in MM_HOSTS else "intl"
    if a.deps.probe_keys and len(key) >= 8:
        try:
            region = await minimax_region(key, a.deps.minimax_for or V.MiniMax)
        except TTSError as e:
            raise _err(e.kind, provider="minimax") from e
    try:
        await auth.add_voice_key(a.deps.pool, a.cfg.box, acc, key, provider="minimax", base_url=MM_HOSTS[region])
    except auth.AuthError as e:
        raise HTTPException(400, str(e)) from e
    return {"last4": key[-4:], "region": region}


@router.post("/conversations/{conv}/voice", status_code=201)
async def voice_message(conv: UUID, audio: UploadFile = File(...), seconds: float = Form(0),
                        acc: UUID = Depends(account), a: Api = Depends(api)):
    """TA 发语音（声音第二块）：存录音、转文字、量语气 → {attachment, text}。App 再照常发消息：text + attachments=[id]。"""
    scope = await own_conversation(a, acc, conv)
    data = await audio.read(voice_in.MAX_BYTES + 1)
    s = Settings.from_dict(await archive.get_settings(a.deps.pool, scope.companion))
    try:
        att, text = await voice_in.receive(a.deps, acc, conv, data, audio.content_type or "audio/mp4", seconds, s.lang,
                                           provider=V.provider_of(s))
    except V.VoiceError as e:
        raise _err(e.kind, provider=V.provider_of(s)) from e
    return {"attachment": att.public(), "text": text}
