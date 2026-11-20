"""看图（2026-09-27，iOS 第一块第 4 步；Aporia定：DeepSeek 看不见图，先请一个会看图的便宜模型写描述）。

每张图写一段描述，存在附件上，只写一次：
- 聊天的模型自己会看图（Claude / OpenAI / Gemini）→ 它自己写；这一轮它还另外看原图。
- 不会看（DeepSeek、兼容口）→ 用户钥匙串里有会看图的 key 就用那把；没有就用我们配的描述模型（Deps.caption_route）。
  用我们的：试用期不限，自带 key 的每天 OURS_DAILY 张（数字等会员那块定）。
之后的历史里一律只用描述：图很占 token，每轮都带会越来越贵，缓存也乱。描述写不出来就空着，它看到「还没看清是什么」。"""
from __future__ import annotations

import base64
import logging
from datetime import date
from pathlib import Path

from llm.catalog import cost, sees_images
from llm.router import Route, call
from llm.types import Block, ChatRequest, ImagePart, Msg

from . import archive
from .attachments import Attachment
from .context import user_tag

log = logging.getLogger(__name__)
OURS_DAILY = 20

SYSTEM = {"zh": "你在帮一个聊天伙伴看图。只描述，不聊天。",
          "en": "You're looking at a photo for a chat companion. Describe only; don't chat."}
PROMPT = {
    "zh": "把这张图写成一段客观、具体的描述（100～200 字）：图里有什么、在哪、什么样子、颜色和光线，有字就照抄。"
          "这是写给以后看不到这张图的自己看的，不评价、不客套、不猜拍的人在想什么。",
    "en": "Write an objective, concrete description of this photo (60–120 words): what's in it, where, what it looks like, "
          "colours and light; copy any text exactly. It's for your future self who can't see the image — no judging, "
          "no pleasantries, no guessing what the person was thinking.",
}


async def _describer(deps, scope, chat_route: Route) -> tuple[Route | None, str]:
    if sees_images(chat_route.provider, chat_route.base_url, chat_route.chat_model):
        return chat_route, "chat"
    box = getattr(deps.keys, "box", None)
    from . import media
    picked = await media.vision_route(deps.pool, box, scope.account)     # Me 里挑的看图钥匙（10-15）
    if picked is not None:
        return picked, "key"
    if box is not None:
        r = await deps.pool.fetchrow(
            "SELECT provider, chat_model, base_url, secret FROM keyring WHERE account_id = $1 "
            "AND provider = ANY($2::text[]) ORDER BY created_at LIMIT 1", scope.account, ["anthropic", "openai", "gemini"])
        if r is not None:
            return Route(r["provider"], box.unlock(r["secret"]), r["chat_model"], r["chat_model"],
                         base_url=r["base_url"]), "key"
    return deps.caption_route, "ours"


async def describe(deps, scope, chat_route: Route, att: Attachment, lang: str, day: date, adapter_for) -> str:
    """给一张图写描述（写过就直接用），存到附件上；写不出来返回空串。adapter_for(route) = 大脑的接头缓存。"""
    if att.caption or att.kind != "image":
        return att.caption
    pool = deps.pool
    if att.sha:                                   # 同一张图看过了（10-01）：直接用那段描述，不花钱
        seen = await pool.fetchval("SELECT caption FROM image_captions WHERE account_id = $1 AND sha = $2 AND lang = $3",
                                   scope.account, att.sha, lang)
        if seen:
            await pool.execute("UPDATE attachments SET caption = $2, caption_source = 'seen' WHERE id = $1", att.id, seen)
            att.caption = seen
            return seen
    route, source = await _describer(deps, scope, chat_route)
    if route is None:
        return ""
    if source == "ours":
        plan = await pool.fetchval("SELECT plan FROM accounts WHERE id = $1", scope.account)
        used = await pool.fetchval("SELECT count(*) FROM attachments WHERE account_id = $1 AND caption_source = 'ours' "
                                   "AND created_at >= now() - interval '1 day'", scope.account)
        if plan == "byok" and used >= OURS_DAILY:
            return ""
    caption = await look(deps, scope, route, att.mime, Path(att.path).read_bytes(), lang, day, adapter_for)
    await pool.execute("UPDATE attachments SET caption = $2, caption_source = $3 WHERE id = $1", att.id, caption, source)
    if att.sha and caption:
        await remember_caption(pool, scope.account, att.sha, lang, caption, source)
    att.caption = caption
    return caption


async def remember_caption(pool, account, sha: str, lang: str, caption: str, source: str) -> None:
    await pool.execute("""INSERT INTO image_captions (account_id, sha, lang, caption, source) VALUES ($1, $2, $3, $4, $5)
                          ON CONFLICT (account_id, sha, lang) DO UPDATE SET caption = EXCLUDED.caption, source = EXCLUDED.source""",
                       account, sha, lang, caption, source)


async def look(deps, scope, route: Route, mime: str, data: bytes, lang: str, day: date, adapter_for,
               prompt: str | None = None) -> str:
    """让 route 那个会看图的模型看一张图、写一段描述（钱记到账号上）。"""
    req = ChatRequest(model=route.chat_model, system=[Block(SYSTEM[lang])], messages=[Msg(
        "user", prompt or PROMPT[lang], images=(ImagePart(mime, base64.b64encode(data).decode()),))],
        max_tokens=600, thinking=False, user_tag=user_tag(scope.account))
    reply = await call(adapter_for(route), req)
    await archive.add_usage(deps.pool, scope.account, day, route.chat_model, reply.usage, cost(reply.usage, route.chat_model))
    return " ".join(reply.text.split())


async def describer_for(deps, scope, chat_route: Route) -> tuple[Route | None, str]:
    return await _describer(deps, scope, chat_route)
