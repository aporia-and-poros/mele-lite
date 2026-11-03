"""声音 · 它发语音条（10-03，设计 docs/specs/2026-10-03-voice-notes-design.md，计划 docs/plans/2026-10-03-voice-notes.md）。

- 它在回复里用 `🎤` 开头标一段 → 分条发时那段自己成一条 → 先落一个占位的语音条（lazy_public：编号 + 估的秒数，不花钱）；
  TA 点了才念（10-31 按需念：/messages/{mid}/speak），念好存成一段 mp3 挂在消息上。
- 钥匙：账号钥匙串里有 ElevenLabs key 就用它的（不扣额度）；没有就用我们的（NEWAPP_ELEVENLABS_KEY），按字数扣声音额度。
- 念过的按「文字 + 嗓子 + 模型」指纹存着，同一句再念（比如「念给我听」点第二次）不再花钱。
- 任何一步不成都抛 VoiceError，调用方回落成文字——不卡、不丢。"""
from __future__ import annotations

import hashlib
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from llm.tts import NOTE_MODEL, TTSError, tts_cost

from . import auth

MARK = "🎤"
FREE_CHARS = 2000                 # 免费账号送的声音额度（字）；会员每月送多少、单买多少钱等Aporia定
# 我们挑好的嗓子（10-03 Aporia听过定的；Lauren 中英都最顺，当出厂默认，一把嗓子中英都用她；ElevenLabs 声音库，付费档直接用、不占声音位）。第一把 = 出厂默认。
# 试听是我们自己用 v4 念的一句中文 + 一句英文（brain/voice_presets/<key>-<zh|en>.mp3），不用库里会过期的链接。
PRESETS: list[dict] = [
    {"key": "lauren", "voice_id": "DODLEQrClDo8wCz460ld", "name": "Lauren", "gender": "female",
     "about": {"zh": "温柔、让人安心", "en": "friendly, comforting, soft"}},
    {"key": "hope", "voice_id": "uYXf8XasLslADfZ2MB4u", "name": "Hope", "gender": "female",
     "about": {"zh": "明亮、活泼、爱聊天", "en": "bubbly, chatty, bright"}},
    {"key": "andrew", "voice_id": "SF9uvIlY93SJRMdV5jeP", "name": "Andrew", "gender": "male",
     "about": {"zh": "清亮、有劲儿（原本是足球解说）", "en": "clear and lively (a football commentator by trade)"}},
    {"key": "jon", "voice_id": "Cz0K1kOv9tD8l0b5Qu53", "name": "Jon", "gender": "male",
     "about": {"zh": "低沉、松弛、好亲近", "en": "relaxed, deep, approachable"}},
]
PRESET_DIR = Path(__file__).with_name("voice_presets")


def presets_public(lang: str) -> list[dict]:
    return [{"key": p["key"], "voice_id": p["voice_id"], "name": p["name"], "gender": p["gender"],
             "about": p["about"].get(lang, p["about"]["en"]), "preview": f"voice/presets/{p['key']}/preview"}
            for p in PRESETS]
_TAG = re.compile(r"\[[^\[\]\n]{1,60}\]")
# 稿子里一个标签都没有时先垫这一个（10-03 Aporia A/B：不带标签的中文念得平、念得怪，带了顺耳）
DEFAULT_TAG = "[warm, relaxed, natural] "


# 「偶尔 / 常常」各一句，放在底子的语气那几行后面（换档会让缓存作废一次）。只写正面那半句（Aporia 10-03）。
MODE_LINES = {
    "zh": {"sometimes": "有些话用说的更好——晚安、安慰、笑出声、想 TA 的时候，就发语音条。格式就是单独一段、以 🎤 开头，后面直接写要说出口的话，比如：\n🎤 [soft, a little tired] 晚安…早点睡，明天见。\n这一段会念成你的语音条。写法细节翻手册 voice。",
           "often": "你喜欢让 TA 听见你的声音，想说出声的时候就发语音条。格式就是单独一段、以 🎤 开头，后面直接写要说出口的话，比如：\n🎤 [soft, a little tired] 晚安…早点睡，明天见。\n这一段会念成你的语音条。写法细节翻手册 voice。"},
    "en": {"sometimes": "Some things land better said out loud — goodnights, comfort, a laugh, missing them — so send a voice note. The format is its own paragraph starting with 🎤, followed by the words you'll say, e.g.:\n🎤 [soft, a little tired] Goodnight… sleep well, see you tomorrow.\nThat paragraph becomes your voice note. Details in the voice manual.",
           "often": "You like letting them hear your voice: whenever you want to say something out loud, send a voice note. The format is its own paragraph starting with 🎤, followed by the words you'll say, e.g.:\n🎤 [soft, a little tired] Goodnight… sleep well, see you tomorrow.\nThat paragraph becomes your voice note. Details in the voice manual."},
}


def mode_lines(lang: str, mode: str) -> list[str]:
    line = MODE_LINES.get(lang, MODE_LINES["zh"]).get(mode)
    return [line] if line else []


class VoiceError(Exception):
    """kind：no_voice（没配嗓子）/ no_key（没有能用的钥匙）/ quota（声音额度不够）/ TTSError 的 kind"""

    def __init__(self, kind: str):
        super().__init__(kind)
        self.kind = kind


@dataclass
class Clip:
    id: UUID
    path: str
    duration_ms: int
    cached: bool = False

    def public(self) -> dict:
        return {"id": str(self.id), "duration_ms": self.duration_ms}


def is_voice(bubble: str) -> bool:
    return bubble.lstrip().startswith(MARK)


def body(bubble: str) -> str:
    """去掉开头的 🎤，留要念的稿子（带音频标签）。"""
    t = bubble.lstrip()
    return t[len(MARK):].strip() if t.startswith(MARK) else bubble.strip()


def strip_tags(text: str) -> str:
    """给人看的逐字稿：去掉 [softly] 这类音频标签。"""
    out = _TAG.sub("", text)
    out = re.sub(r"[ \t]{2,}", " ", out)
    return "\n".join(l.strip() for l in out.splitlines()).strip()


def as_text(bubble: str) -> str:
    """念不成的时候：这一条照常当文字发（去 🎤、去标签）。"""
    return strip_tags(body(bubble))


def estimate_ms(script: str) -> int:
    """占位语音条上的秒数：中文一秒约 4.5 个字、英文一秒约 2.7 个词，加半秒起头；音频标签不算（跟 Lite 的 VoiceNoteLength 一样）。"""
    plain = _TAG.sub(" ", script)
    han = sum(1 for ch in plain if "\u4e00" <= ch <= "\u9fff")
    words = len(re.findall(r"[^\W\d_]+|\d+", re.sub(r"[\u4e00-\u9fff]", " ", plain)))
    return max(1000, int((han / 4.5 + words / 2.7 + 0.5) * 1000))


def lazy_public(bubble: str) -> dict:
    """还没念的语音条：编号按稿子的指纹（事件流里和翻历史时是同一个），App 点了再去念。"""
    b = body(bubble)
    return {"id": "n" + text_sha(b)[:20], "duration_ms": estimate_ms(b), "lazy": True}


async def can_speak(deps, account: UUID, chars: int = 0) -> bool:
    """这个账号现在能不能念：有钥匙；用我们的钥匙的还得剩够字。不能的话语音条直接当文字发。"""
    try:
        _, own = await engine(deps, account)
    except VoiceError:
        return False
    return own or await quota(deps.pool, account) >= chars + len(DEFAULT_TAG)


def fingerprint(text: str, voice_id: str, model: str) -> str:
    return hashlib.sha256(f"{model}\n{voice_id}\n{text}".encode()).hexdigest()


def text_sha(text: str) -> str:
    return hashlib.sha256(text.strip().encode()).hexdigest()


def default_voice() -> str:
    return PRESETS[0]["voice_id"] if PRESETS else ""


async def quota(pool, account: UUID) -> int:
    """剩多少字。第一次看时送 FREE_CHARS。"""
    left = await pool.fetchval("SELECT chars_left FROM voice_quota WHERE account_id = $1", account)
    if left is None:
        await pool.execute("INSERT INTO voice_quota (account_id, chars_left) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                           account, FREE_CHARS)
        left = await pool.fetchval("SELECT chars_left FROM voice_quota WHERE account_id = $1", account)
    return left


async def engine(deps, account: UUID) -> tuple[object, bool]:
    """（接头, 是不是自带 key）。都没有 → VoiceError("no_key")。"""
    if deps.tts_for is None:
        raise VoiceError("no_key")
    box = getattr(deps.keys, "box", None)
    own = await auth.voice_key(deps.pool, box, account) if box is not None else None
    if own:
        return deps.tts_for(own), True
    if deps.tts_key:
        return deps.tts_for(deps.tts_key), False
    raise VoiceError("no_key")


def _duration_ms(mp3: bytes) -> int:
    return int(len(mp3) * 8 / 128)          # 128kbps 估时长，够气泡上显示用


async def find(pool, account: UUID, fp: str) -> Clip | None:
    r = await pool.fetchrow("SELECT id, path, duration_ms FROM voice_clips WHERE account_id = $1 AND fingerprint = $2",
                            account, fp)
    return Clip(r["id"], r["path"], r["duration_ms"], cached=True) if r else None


async def speak(deps, account: UUID, *, text: str, voice_id: str, purpose: str, message_id: int | None = None,
                prev: str | None = None, nxt: str | None = None, model: str = NOTE_MODEL) -> Clip:
    text = (text or "").strip()
    voice_id = voice_id or default_voice()
    if not voice_id:
        raise VoiceError("no_voice")
    if not text:
        raise VoiceError("bad_request")
    pool = deps.pool
    plain = text                                       # 历史里按 TA 看到的那句找（垫标签之前）
    if not _TAG.search(text):
        text = DEFAULT_TAG + text
    fp = fingerprint(text, voice_id, model)
    hit = await find(pool, account, fp)
    if hit is not None:
        return hit
    tts, own = await engine(deps, account)
    chars = len(text)                                  # 垫的标签也算字（ElevenLabs 照算）
    if not own and await quota(pool, account) < chars:
        raise VoiceError("quota")
    try:
        mp3 = await tts.synth(text, voice_id, model=model, previous_text=prev, next_text=nxt)
    except TTSError as e:
        raise VoiceError(e.kind) from e
    folder = (deps.files_dir or Path(".local/files")) / "voice"
    folder.mkdir(parents=True, exist_ok=True)
    cid = uuid.uuid4()
    path = folder / f"{cid}.mp3"
    path.write_bytes(mp3)
    dur = _duration_ms(mp3)
    async with pool.acquire() as con, con.transaction():
        got = await con.fetchrow("""INSERT INTO voice_clips (id, account_id, fingerprint, text_sha, message_id, path, chars,
                                                             duration_ms)
                                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (account_id, fingerprint) DO NOTHING
                                    RETURNING id""", cid, account, fp, text_sha(plain), message_id, str(path), chars, dur)
        if got is None:                                  # 同时念了同一句：用先存上的那份，这份扔掉、不扣
            path.unlink(missing_ok=True)
            return await find(pool, account, fp)
        if not own:
            await con.execute("UPDATE voice_quota SET chars_left = GREATEST(chars_left - $2, 0) WHERE account_id = $1",
                              account, chars)
        await con.execute("INSERT INTO voice_usage (account_id, purpose, model, chars, cost_usd, own_key) "
                          "VALUES ($1, $2, $3, $4, $5, $6)", account, purpose, model, chars, tts_cost(chars, model), own)
    return Clip(cid, str(path), dur)


async def attach(pool, account: UUID, clip_ids: list[UUID], message_id: int) -> None:
    """存档以后把这一轮念出来的几段挂到那条消息上（倒回、删窗口跟着走）。"""
    if clip_ids:
        await pool.execute("UPDATE voice_clips SET message_id = $3 WHERE account_id = $1 AND id = ANY($2::uuid[]) "
                           "AND message_id IS NULL", account, clip_ids, message_id)


async def clips_for_message(pool, account: UUID, message_id: int) -> dict[str, Clip]:
    """历史里这条消息念好的几段：{文字指纹: Clip}。按文字找，换了嗓子以后老的语音条还在。"""
    rows = await pool.fetch("SELECT id, path, duration_ms, text_sha FROM voice_clips WHERE account_id = $1 AND message_id = $2 "
                            "ORDER BY created_at", account, message_id)
    return {r["text_sha"]: Clip(r["id"], r["path"], r["duration_ms"]) for r in rows}


async def get_clip(pool, account: UUID, cid: UUID) -> Clip | None:
    r = await pool.fetchrow("SELECT id, path, duration_ms FROM voice_clips WHERE id = $1 AND account_id = $2", cid, account)
    return Clip(r["id"], r["path"], r["duration_ms"]) if r else None
