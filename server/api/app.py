"""正式接口（2026-09-27，第二块中第 4 步）：给 app 用的 HTTP 接口。

跟测试台（web/）分开：测试台是本机调试用的，只有一个账号、当前窗口放在全局；这里每个请求凭登录凭证认人，
所有联系人 / 窗口都核对归属。接口清单见 docs/superpowers/plans/2026-09-27-accounts-contacts-api.md。"""
from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI

from brain.turn import Deps
from patrol.loop import patrol_loop
from brain.call_ring import Ringer
from push.apns import push_loop

from . import (routes_account, routes_milestones, routes_album, routes_books, routes_tarot, routes_voice, routes_wallet, routes_attachments, routes_chat, routes_companions, routes_dates, routes_diary, routes_drawer,
               routes_favorites, routes_food, routes_groups, routes_host, routes_lore, routes_mcp, routes_memories, routes_memory_link, routes_music, routes_moments, routes_patrol, routes_people, routes_stickers, routes_todos, routes_call, routes_world)
from .deps import Api, ApiConfig
from .rooms import Rooms

API_VERSION = 1   # 接口版本（10-04，Mele Host）：App 和 Host 对不上时提示谁该升级；接口有不兼容的改动才 +1


def create_app(deps: Deps, cfg: ApiConfig) -> FastAPI:
    rooms = Rooms(cfg.wait_scale)
    if deps.files_dir is None:                     # 语音也存在附件目录下（10-03）
        deps.files_dir = cfg.files_dir
    if deps.ringer is None:                        # TA 打给你（10-31）：VoIP 推送走推送中转
        deps.ringer = Ringer(deps.pool, cfg.push_relay, publish=rooms.publish, now=deps.now)

    @asynccontextmanager
    async def lifespan(_app):
        task = asyncio.create_task(patrol_loop(deps, rooms)) if cfg.patrol else None
        pusher = asyncio.create_task(push_loop(deps.pool, cfg.apns, relay_url=cfg.push_relay)) \
            if (cfg.apns or cfg.push_relay) else None
        try:
            yield
        finally:
            for t in (task, pusher):
                if t:
                    t.cancel()

    app = FastAPI(title="new-app", lifespan=lifespan)
    app.state.api = Api(deps=deps, cfg=cfg, rooms=rooms)
    for r in (routes_account.router, routes_companions.router, routes_chat.router, routes_patrol.router,
              routes_attachments.router, routes_dates.router, routes_drawer.router, routes_food.router,
              routes_music.router, routes_lore.router, routes_people.router, routes_diary.router, routes_todos.router, routes_world.router, routes_stickers.router, routes_moments.router,
              routes_favorites.router, routes_album.router, routes_books.router,
              routes_wallet.router, routes_tarot.router, routes_voice.router, routes_host.router, routes_milestones.router, routes_mcp.router, routes_groups.router, routes_memories.router, routes_memory_link.router,
              routes_call.router):
        app.include_router(r)

    @app.get("/health")
    async def health():
        return {"ok": True}

    return app
