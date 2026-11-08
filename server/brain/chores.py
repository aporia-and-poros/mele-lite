"""钥匙串分活（10-15 Aporia）：钥匙串里点一把钥匙勾它干哪些活。一样活同一时间只归一把；没人勾 = 跟 TA 聊天那把。
跟 MeleLiteCore/Model/Chores.swift 同一份规矩，改一边改另一边。表存在 accounts.media 的 chores 键里。"""
from __future__ import annotations

import json
import re
from uuid import UUID

CHORES = ("vision", "draw", "ledger", "dedupe", "food", "caption", "import", "music", "translate",
          "diary", "day", "moments", "tarot", "focus", "voice")
OWN = frozenset({"diary", "day", "moments", "tarot", "focus"})          # TA 亲笔：勾整个杂活不带它们
ODD = frozenset({"dedupe", "food", "caption", "import", "music", "translate"})
_SEES = frozenset({"vision", "caption"})                                 # 要会看图
_NOT = {
    "elevenlabs": frozenset(CHORES) - {"voice"},
    "minimax": frozenset(CHORES) - {"voice"},           # 声音（11-08）：跟 ElevenLabs 一样只管声音
    "deepseek": _SEES | {"draw", "voice"},
    "anthropic": frozenset({"draw", "voice"}),
}


def can(provider: str) -> list[str]:
    no = _NOT.get(provider, frozenset({"voice"}))
    return [c for c in CHORES if c not in no]


def migrate(media: dict) -> dict:
    """旧的 {vision_key, image_key, image_model} → {chores, draw_model}；搬过（有 chores）就原样。不改入参"""
    m = dict(media or {})
    if isinstance(m.get("chores"), dict):
        m.setdefault("draw_model", "")
        return m
    table = {}
    if m.get("vision_key"):
        table["vision"] = str(m["vision_key"])
    if m.get("image_key"):
        table["draw"] = str(m["image_key"])
    m["chores"] = table
    m["draw_model"] = str(m.get("image_model") or "")
    return m


def assign(table: dict[str, str], key_id: str, provider: str, chores: list[str]) -> tuple[dict[str, str], list[dict]]:
    """这把钥匙的活设成 chores：别的钥匙上有的挪过来（记进 moved），这把原来有、这次没勾的取消。"""
    allowed = set(can(provider))
    bad = [c for c in chores if c not in allowed]
    if bad:
        raise ValueError(f"这家干不了：{'、'.join(bad)}")
    out = {c: k for c, k in table.items() if k != key_id}
    moved = []
    for c in CHORES:
        if c not in chores:
            continue
        if c in out:
            moved.append({"chore": c, "from_key": out[c]})
        out[c] = key_id
    return out, moved


_DRAW_ASK = re.compile(r"(画|生成)(一|几|两|三)?(张|幅|个)|生图|出图|(生成|画).{0,10}(图|照片|自拍|头像|壁纸|插画)"
                       r"|\b(draw|paint|generate|make)\b.{0,20}\b(image|picture|photo|selfie|drawing|portrait)s?\b|\bdraw me\b", re.I)


def wants_drawing(text: str) -> bool:
    """用户是不是在叫 TA 画图（10-16：没挑画图钥匙时提醒一句去哪挑）。跟 Chores.wantsDrawing 同一个"""
    return bool(_DRAW_ASK.search(text or ""))


def is_image_model(model: str) -> bool:
    """画图模型（不能拿来聊天）。10-16 内测：钥匙上填了 gpt-image-1 当聊天模型。跟 Chores.isImageModel 同一个规矩"""
    m = (model or "").lower()
    return m.startswith(("gpt-image", "dall-e", "imagen")) or "-image" in m


def pick(table: dict[str, str], chore: str, live: dict[str, str]) -> str | None:
    kid = table.get(chore)
    return kid if kid in live and chore in can(live[kid]) else None


# ── Host 存取 ──

async def get_table(pool, account: UUID) -> dict:
    raw = await pool.fetchval("SELECT media FROM accounts WHERE id = $1", account)
    return migrate(json.loads(raw) if isinstance(raw, str) else (raw or {}))


async def save_table(pool, account: UUID, media: dict) -> None:
    await pool.execute("UPDATE accounts SET media = $2::jsonb WHERE id = $1", account, json.dumps(media))


async def live_keys(pool, account: UUID) -> dict[str, str]:
    rows = await pool.fetch("SELECT id, provider FROM keyring WHERE account_id = $1", account)
    return {str(r["id"]): r["provider"] for r in rows}
