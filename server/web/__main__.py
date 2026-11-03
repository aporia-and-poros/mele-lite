"""本机测试网页：
    cd server && .venv/bin/python -m web                 # 真模型 + 真向量（bge-m3），浏览器开 http://127.0.0.1:8765
    .venv/bin/python -m web --fake-embed --demo          # 不联网、不花钱：假向量 + 演示模型，只看界面
钥匙在 .local/keys.toml（样子见 llm/keys.py），测试用户的 id 存在 .local/test_user。都不进仓库。"""
from __future__ import annotations

import argparse
import asyncio
import json
import uuid
from pathlib import Path

import uvicorn

import memory as M
from brain import accounts, archive
from brain.scope import Scope
from brain.turn import Deps
from llm.keys import FileKeys
from llm.router import Route
from llm.types import ChatRequest, Reply, Usage

from .app import create_app

LOCAL = Path(__file__).resolve().parent.parent / ".local"


class DemoModel:
    """演示模型：把你的话复述一遍，不联网。只用来看界面。
    被〔醒来〕叫醒时轮流：一次开口、一次回 <silent>，两种样子都看得到。"""

    def __init__(self):
        self.wakes = 0

    async def stream(self, req: ChatRequest) -> Reply:
        if "〔醒来〕" in req.messages[-1].text or "〔Wake〕" in req.messages[-1].text:
            self.wakes += 1
            text = "（演示模型）醒来想起你了——今天过得怎么样？" if self.wakes % 2 else "<silent>"
            return Reply(text, "", [], Usage(), "end_turn", None)
        if "〔现在在打电话〕" in req.messages[-1].text or "[You're on a phone call]" in req.messages[-1].text:
            # 电话（10-31）：一句一行，一个字一个字地推（看边写边念）
            text = "（演示模型）我听着呢。\n你那边现在几点啦？"
            for ch in text:
                if req.on_text:
                    req.on_text(ch)
                await asyncio.sleep(0.02)
            return Reply(text, "", [], Usage(), "end_turn", None)
        chunks = [c for c in req.messages[-1].text.split("\n\n") if c.strip() and not c.startswith("〔")]
        said = chunks[-1] if chunks else ""
        return Reply(f"收到：{said}\n\n（这是演示模型，没有联网）", f"（演示模型的思考）TA 说了「{said[:20]}」，我复述一遍。",
                     [], Usage(), "end_turn", None)


class DemoKeys:
    def route_for(self, user_id) -> Route:
        return Route("demo", "", "demo", "demo")


def test_user() -> uuid.UUID:
    p = LOCAL / "test_user"
    if p.exists():
        return uuid.UUID(p.read_text().strip())
    LOCAL.mkdir(exist_ok=True)
    u = uuid.uuid4()
    p.write_text(str(u))
    return u


async def test_scope(pool) -> Scope:
    """本机测试用的那个账号 + 联系人 + 窗口，记在 .local/test_scope.json。
    第一次跑（09-27 之前只有一个 test_user）时搬家：旧 id 留给联系人 Lumi（记忆、关于 TA、便利贴、人设、设置不用动），
    聊天、账本、状态、每轮日志搬进它的第一个窗口，人物卡和用量搬到账号。"""
    p = LOCAL / "test_scope.json"
    if p.exists():
        d = json.loads(p.read_text())
        scope = Scope(uuid.UUID(d["account"]), uuid.UUID(d["companion"]), uuid.UUID(d["conversation"]))
    else:
        old = test_user()
        scope = Scope(uuid.uuid4(), old, uuid.uuid4())
        await accounts.create_account(pool, scope.account)
        await accounts.create_companion(pool, scope.account, scope.companion)
        await accounts.new_conversation(pool, scope.account, scope.companion, conversation_id=scope.conversation)
        async with pool.acquire() as conn:
            async with conn.transaction():
                for table in ("chat_messages", "ledger_days", "user_state", "turn_logs"):
                    await conn.execute(f"UPDATE {table} SET user_id = $1 WHERE user_id = $2", scope.conversation, old)
                await conn.execute("UPDATE memories SET user_id = $1 WHERE user_id = $2 AND kind = 'person'",
                                   scope.account, old)
                await conn.execute("UPDATE usage_daily SET user_id = $1 WHERE user_id = $2", scope.account, old)
        p.write_text(json.dumps({k: str(getattr(scope, k)) for k in ("account", "companion", "conversation")}))
    await accounts.create_account(pool, scope.account)
    await accounts.create_companion(pool, scope.account, scope.companion)
    await accounts.new_conversation(pool, scope.account, scope.companion, conversation_id=scope.conversation)
    return scope


async def main(args) -> None:
    await M.apply_schema(args.dsn)
    await archive.apply_brain_schema(args.dsn)
    pool = await M.create_pool(args.dsn)
    user = await test_scope(pool)
    if not await archive.get_settings(pool, user.companion):
        await archive.save_settings(pool, user.companion, {"tz": args.tz})
    embedder = M.FakeEmbedder() if args.fake_embed else M.BgeM3Embedder()
    if args.demo:
        demo = DemoModel()
        deps = Deps(pool=pool, embedder=embedder, keys=DemoKeys(), adapter_for=lambda route: demo)
    else:
        deps = Deps(pool=pool, embedder=embedder, keys=FileKeys(args.keys),
                    reranker=None if args.fake_embed else M.BgeReranker(), sentinel=True)
    server = uvicorn.Server(uvicorn.Config(create_app(deps, user), host="127.0.0.1", port=args.port,
                                           log_level="info"))
    try:
        await server.serve()
    finally:
        await pool.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", default=str(LOCAL / "keys.toml"))
    ap.add_argument("--dsn", default="postgresql://localhost/newapp_dev")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--tz", default="Asia/Singapore")
    ap.add_argument("--fake-embed", action="store_true")
    ap.add_argument("--demo", action="store_true")
    asyncio.run(main(ap.parse_args()))
