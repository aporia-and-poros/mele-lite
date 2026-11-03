"""表情包库（10-01 Aporia，设计 specs/2026-10-01-stickers-design.md）。

一个账号一个库，所有联系人共用；某几张可以标「只给谁」（only_for 空 = 都能用）。最多 300 张。
- 收：上传的图（相册多选）或聊天里的一个附件；同一张（按原始字节的指纹）不重复收。原样存，不转 JPEG，gif 能动。
- 描述：会看图的模型写一次（先查指纹，看过的直接用），TA 能改；名字 + 描述算向量，它按意思找。
- 它发：工具 sticker 搜到几张、挑一张发（挂一张 kind=sticker 的卡）；TA 发：面板点一张变成这个窗口的附件。"""
from __future__ import annotations

import hashlib
import io
import logging
import re
import shutil
import uuid
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from uuid import UUID

from PIL import Image

from memory.embed import embed_one

log = logging.getLogger(__name__)

MAX_STICKERS = 300
MAX_BYTES = 2 * 1024 * 1024
MAX_GIF_BYTES = 5 * 1024 * 1024
NAME_MAX, CAPTION_MAX = 20, 300
SEARCH_LIMIT = 5
FORMATS = {"PNG": ("image/png", ".png"), "JPEG": ("image/jpeg", ".jpg"), "GIF": ("image/gif", ".gif"),
           "WEBP": ("image/webp", ".webp")}

PROMPT = {"zh": "这是一张聊天用的表情包。用一两句话写：画面上是什么（有字就照抄），它表达的情绪或意思、适合在什么时候发。不评价。",
          "en": "This is a chat sticker. In one or two sentences: what's in it (copy any text exactly), the feeling or meaning "
                "it conveys, and when it fits to send. No judging."}


class StickerError(ValueError):
    """给用户看的人话。"""


@dataclass
class Sticker:
    id: int
    account_id: UUID
    sha: str
    path: str
    mime: str
    size: int
    caption: str
    name: str
    only_for: list[UUID]
    use_count: int
    created_at: datetime

    def to_dict(self) -> dict:
        return {"id": self.id, "name": self.name, "caption": self.caption, "mime": self.mime,
                "only_for": [str(c) for c in self.only_for], "use_count": self.use_count}


_COLS = "id, account_id, sha, path, mime, size, caption, name, only_for, use_count, created_at"


def _row(r) -> Sticker:
    d = dict(r)
    d["only_for"] = list(d["only_for"] or [])
    return Sticker(**d)


def sniff(data: bytes) -> tuple[str, str]:
    """认图：返回 (mime, 后缀)；不是图、太大都报人话。"""
    try:
        with Image.open(io.BytesIO(data)) as im:
            fmt = im.format
    except Exception as e:
        raise StickerError("这个文件不是图片") from e
    if fmt not in FORMATS:
        raise StickerError("表情包只认 PNG / JPEG / GIF / WebP")
    if len(data) > (MAX_GIF_BYTES if fmt == "GIF" else MAX_BYTES):
        raise StickerError("这张太大了（动图最多 5MB，别的 2MB）")
    return FORMATS[fmt]


def still(data: bytes) -> tuple[str, bytes]:
    """给看图模型的那一张：动图取第一帧，一律转 PNG。"""
    with Image.open(io.BytesIO(data)) as im:
        im.seek(0)
        out = io.BytesIO()
        im.convert("RGBA").save(out, "PNG")
    return "image/png", out.getvalue()


async def _embed(pool, embedder, sticker_id: int, name: str, caption: str) -> None:
    text = " ".join(x for x in (name, caption) if x).strip()
    vec = await embed_one(embedder, text) if text else None
    await pool.execute("UPDATE stickers SET embedding = $2 WHERE id = $1", sticker_id, vec)


async def add(pool, embedder, files_dir: Path, account: UUID, *, data: bytes, name: str = "", caption: str = "",
              lang: str = "zh") -> tuple[Sticker, bool]:
    """收一张。返回 (这张, 是不是新收的)；同一张收过就返回原来那张。"""
    mime, ext = sniff(data)
    sha = hashlib.sha256(data).hexdigest()
    old = await pool.fetchrow(f"SELECT {_COLS} FROM stickers WHERE account_id = $1 AND sha = $2", account, sha)
    if old is not None:
        return _row(old), False
    if await pool.fetchval("SELECT count(*) FROM stickers WHERE account_id = $1", account) >= MAX_STICKERS:
        raise StickerError(f"表情包最多 {MAX_STICKERS} 张，先删几张")
    if not caption:                                   # 这张图以前在聊天里看过：直接用那段描述
        caption = await pool.fetchval("SELECT caption FROM image_captions WHERE account_id = $1 AND sha = $2 AND lang = $3",
                                      account, sha, lang) or ""
    files_dir.mkdir(parents=True, exist_ok=True)
    path = files_dir / f"sticker-{uuid.uuid4()}{ext}"
    path.write_bytes(data)
    r = await pool.fetchrow(
        f"""INSERT INTO stickers (account_id, sha, path, mime, size, caption, name) VALUES ($1, $2, $3, $4, $5, $6, $7)
            RETURNING {_COLS}""", account, sha, str(path), mime, len(data), caption[:CAPTION_MAX],
        (name or "").strip()[:NAME_MAX])
    s = _row(r)
    if s.caption or s.name:
        await _embed(pool, embedder, s.id, s.name, s.caption)
    return s, True


async def get(pool, account: UUID, sticker_id: int) -> Sticker | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM stickers WHERE id = $1 AND account_id = $2", sticker_id, account)
    return _row(r) if r else None


async def list_all(pool, account: UUID) -> list[Sticker]:
    rows = await pool.fetch(f"SELECT {_COLS} FROM stickers WHERE account_id = $1 ORDER BY created_at DESC, id DESC", account)
    return [_row(r) for r in rows]


async def update(pool, embedder, account: UUID, sticker_id: int, *, name: str | None = None, caption: str | None = None,
                 only_for: list[UUID] | None = None) -> Sticker:
    s = await get(pool, account, sticker_id)
    if s is None:
        raise LookupError("没有这张")
    if only_for is not None:
        mine = {r["id"] for r in await pool.fetch("SELECT id FROM companions WHERE account_id = $1", account)}
        if any(c not in mine for c in only_for):
            raise StickerError("没有这个联系人")
    r = await pool.fetchrow(
        f"""UPDATE stickers SET name = COALESCE($3, name), caption = COALESCE($4, caption),
                   only_for = COALESCE($5::uuid[], only_for)
            WHERE id = $1 AND account_id = $2 RETURNING {_COLS}""",
        sticker_id, account, name.strip()[:NAME_MAX] if name is not None else None,
        " ".join(caption.split())[:CAPTION_MAX] if caption is not None else None,
        list(dict.fromkeys(only_for)) if only_for is not None else None)
    s = _row(r)
    if name is not None or caption is not None:
        await _embed(pool, embedder, s.id, s.name, s.caption)
    return s


async def delete(pool, account: UUID, sticker_id: int) -> bool:
    path = await pool.fetchval("DELETE FROM stickers WHERE id = $1 AND account_id = $2 RETURNING path", sticker_id, account)
    if path is None:
        return False
    Path(path).unlink(missing_ok=True)
    return True


async def search(pool, embedder, account: UUID, companion: UUID, query: str, *, limit: int = SEARCH_LIMIT) -> list[Sticker]:
    """它按意思找：向量最像的 + 名字 / 描述里有这个词的，只给别人的那几张不算；没写好描述的也不给（它不知道是什么）。"""
    where = "account_id = $1 AND caption <> '' AND (cardinality(only_for) = 0 OR $2 = ANY(only_for))"
    q = (query or "").strip()
    vec = await embed_one(embedder, q) if q else None
    hits: dict[int, float] = {}
    if vec is not None:
        for r in await pool.fetch(f"SELECT id, 1 - (embedding <=> $3) AS sim FROM stickers WHERE {where} "
                                  f"AND embedding IS NOT NULL ORDER BY embedding <=> $3 LIMIT $4",
                                  account, companion, vec, limit * 2):
            hits[r["id"]] = float(r["sim"])
    if q:
        for r in await pool.fetch(f"SELECT id FROM stickers WHERE {where} AND (name ILIKE $3 OR caption ILIKE $3) LIMIT $4",
                                  account, companion, f"%{q}%", limit):
            hits[r["id"]] = hits.get(r["id"], 0.0) + 1.0          # 字面上碰到的排前面
    if not hits:
        return []
    ids = sorted(hits, key=lambda i: -hits[i])[:limit]
    rows = await pool.fetch(f"SELECT {_COLS} FROM stickers WHERE id = ANY($1::bigint[])", ids)
    by = {r["id"]: _row(r) for r in rows}
    return [by[i] for i in ids if i in by]


# ── 给模型看的那张表（10-31）：它写 [表情包：#12] 就发，不走工具。Lite 的同一套在 mele-lite Stickers/StickerMenu.swift ──
# 库小：整张表、每张完整描述，放在壹层（走缓存）。库大：壹层只放短目录（每张一个短名），每一轮再按刚聊的话
# 挑几张最搭的、带完整描述递过去（Aporia 10-31：只给半截描述会用得不贴）。
FULL_UP_TO, SHORT_NAME, PICK_LIMIT, PICK_MIN_SIM = 30, 12, 6, 0.45

MENU_HEAD = {"zh": "## 你的表情包\n想发就写 [表情包：#编号]，可以单独一行，也可以夹在句子里。像真人那样偶尔发：接得上此刻的情绪才发，不每句都发，不连着发。\n",
             "en": "## Your stickers\nTo send one, write [sticker: #number], on its own line or inside a sentence. Send them now and then, like a person would: "
                   "only when one fits the feeling of the moment — not every message, not twice in a row.\n"}
MENU_SHORT = {"zh": "（目录只写了短名；每一轮会递几张跟此刻最搭的完整描述，在〔可以发的表情包〕里）\n",
              "en": "(Short names only; each turn the ones that fit the moment come with full descriptions in [Stickers that fit].)\n"}
PICKS_HEAD = {"zh": "〔可以发的表情包〕跟此刻最搭的几张（想发就写 [表情包：#编号]）：\n",
              "en": "[Stickers that fit] The ones closest to this moment (write [sticker: #number] to send one):\n"}


async def for_companion(pool, account: UUID, companion: UUID) -> list[Sticker]:
    """这个联系人能发的、写好了描述的，按编号排（加一张只动尾巴）。"""
    rows = await pool.fetch(f"SELECT {_COLS} FROM stickers WHERE account_id = $1 AND caption <> '' "
                            f"AND (cardinality(only_for) = 0 OR $2 = ANY(only_for)) ORDER BY id", account, companion)
    return [_row(r) for r in rows]


def _one_line(s: str) -> str:
    return " ".join(s.split())


def _short(s: Sticker) -> str:
    """短名：TA 起的名字；没有就取描述第一个逗号 / 句号前那截，最多 SHORT_NAME 个字。"""
    head = s.name.strip() or re.split(r"[，。,.;；!！?？]", _one_line(s.caption))[0]
    return head if len(head) <= SHORT_NAME else head[:SHORT_NAME] + "…"


def _full(s: Sticker) -> str:
    return f"#{s.id} {_one_line(s.caption)}" + (f"（TA 叫它「{s.name}」）" if s.name else "")


def menu_block(stickers: list[Sticker], lang: str) -> str:
    if not stickers:
        return ""
    lang = "en" if lang == "en" else "zh"
    if len(stickers) <= FULL_UP_TO:
        return MENU_HEAD[lang] + "\n".join(_full(s) for s in stickers)
    return MENU_HEAD[lang] + MENU_SHORT[lang] + "\n".join(f"#{s.id} {_short(s)}" for s in stickers)


async def picks(pool, embedder, stickers: list[Sticker], texts: list[str], *, limit: int = PICK_LIMIT) -> list[Sticker]:
    """库大时这一轮最搭的几张：刚聊的话跟描述的向量够像的 + 字面碰到 TA 起的名字的。库小（整张表都在）不挑。"""
    if len(stickers) <= FULL_UP_TO:
        return []
    q = "\n".join(t for t in texts if t and t.strip())[-600:]
    if not q.strip():
        return []
    by = {s.id: s for s in stickers}
    hits: dict[int, float] = {}
    vec = await embed_one(embedder, q)
    if vec is not None:
        for r in await pool.fetch("SELECT id, 1 - (embedding <=> $2) AS sim FROM stickers WHERE id = ANY($1::bigint[]) "
                                  "AND embedding IS NOT NULL ORDER BY embedding <=> $2 LIMIT $3", list(by), vec, limit * 2):
            if r["sim"] >= PICK_MIN_SIM:
                hits[r["id"]] = float(r["sim"])
    low = q.lower()
    for s in stickers:
        if s.name and s.name.lower() in low:
            hits[s.id] = hits.get(s.id, 0.0) + 1.0
    return [by[i] for i in sorted(hits, key=lambda i: -hits[i])[:limit]]


def picks_block(chosen: list[Sticker], lang: str) -> str:
    if not chosen:
        return ""
    return PICKS_HEAD["en" if lang == "en" else "zh"] + "\n".join(_full(s) for s in chosen)


def _grams(s: str) -> set[str]:
    s = re.sub(r"\s+", "", s.lower())
    return {s[i:i + 2] for i in range(len(s) - 1)}


def resolve(stickers: list[Sticker], wanted: str) -> Sticker | None:
    """它写的那一段（#12、12、旧写法的描述）→ 哪一张；表里没有的不发。"""
    w = (wanted or "").strip()
    m = re.match(r"^[#＃№]?\s*(\d+)\b", w)
    if m:
        return next((s for s in stickers if s.id == int(m.group(1))), None)
    lw = w.lower()
    if not lw:
        return None
    exact = next((s for s in stickers if s.caption.lower() == lw or (s.name and s.name.lower() == lw)), None)
    if exact:
        return exact
    near = [s for s in stickers if lw in s.caption.lower() or s.caption.lower() in lw]
    if near:
        return max(near, key=lambda s: min(len(s.caption), len(lw)))
    gw = _grams(lw)
    best, score = None, 0.0
    for s in stickers:
        gs = _grams(s.caption)
        if gw and gs:
            sc = len(gw & gs) / min(len(gw), len(gs))
            if sc > score:
                best, score = s, sc
    return best if score >= 0.5 else None


async def usable(pool, account: UUID, companion: UUID, sticker_id: int) -> Sticker | None:
    """这个联系人能不能发这张（没写描述的也能发，只是它搜不到）。"""
    r = await pool.fetchrow(f"SELECT {_COLS} FROM stickers WHERE id = $1 AND account_id = $2 "
                            f"AND (cardinality(only_for) = 0 OR $3 = ANY(only_for))", sticker_id, account, companion)
    return _row(r) if r else None


async def mark_used(pool, sticker_id: int, now: datetime) -> None:
    await pool.execute("UPDATE stickers SET use_count = use_count + 1, last_used_at = $2 WHERE id = $1", sticker_id, now)


async def caption_pending(deps, account: UUID, now: datetime, *, limit: int = 20) -> int:
    """没描述的写描述（上传后在后台跑）。用主联系人的钥匙（会看图的自己看，不会的找会看图的 key / 我们的）。返回写了几张。"""
    from . import accounts, archive, vision
    from .auth import TrialOver
    from .scope import Scope
    from .settings import Settings
    from .turn import get_adapter, resolve_route
    pool = deps.pool
    rows = await pool.fetch(f"SELECT {_COLS} FROM stickers WHERE account_id = $1 AND caption = '' ORDER BY id LIMIT $2",
                            account, limit)
    if not rows:
        return 0
    comps = await accounts.list_companions(pool, account)
    if not comps:
        return 0
    s = Settings.from_dict(await archive.get_settings(pool, comps[0]))
    scope = Scope(account, comps[0], None)
    try:
        chat = await resolve_route(deps.keys, scope, chore="caption")
    except TrialOver:
        chat = getattr(deps.keys, "trial", None)
    route = None
    if chat is not None:
        route, _ = await vision.describer_for(deps, scope, chat)
    if route is None:
        return 0
    day = now.astimezone().date() if now.tzinfo else date.today()
    done = 0
    for st in map(_row, rows):
        try:
            mime, data = still(Path(st.path).read_bytes())
            caption = await vision.look(deps, scope, route, mime, data, s.lang, day, lambda r: get_adapter(deps, r),
                                        prompt=PROMPT.get(s.lang, PROMPT["en"]))
        except Exception:
            log.exception("sticker %s caption failed", st.id)
            continue
        if not caption:
            continue
        await pool.execute("UPDATE stickers SET caption = $2 WHERE id = $1", st.id, caption[:CAPTION_MAX])
        await vision.remember_caption(pool, account, st.sha, s.lang, caption[:CAPTION_MAX], "sticker")
        await _embed(pool, deps.embedder, st.id, st.name, caption)
        done += 1
    return done


async def to_attachment(pool, files_dir: Path, account: UUID, conversation: UUID, sticker_id: int):
    """TA 从面板发一张：复制一份变成这个窗口的附件（删窗口删附件不会删到表情包），描述带上、标成表情包。"""
    from .attachments import _COLS as ACOLS, _row as arow
    s = await get(pool, account, sticker_id)
    if s is None:
        return None
    aid = uuid.uuid4()
    files_dir.mkdir(parents=True, exist_ok=True)
    path = files_dir / f"{aid}{Path(s.path).suffix}"
    shutil.copyfile(s.path, path)
    r = await pool.fetchrow(
        f"""INSERT INTO attachments (id, account_id, conversation_id, kind, name, mime, size, path, caption, caption_source,
                                     sha, sticker_id)
            VALUES ($1, $2, $3, 'image', $4, $5, $6, $7, $8, 'sticker', $9, $10) RETURNING {ACOLS}""",
        aid, account, conversation, s.name, s.mime, s.size, str(path), s.caption, s.sha, s.id)
    return arow(r)
