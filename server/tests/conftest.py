"""每次跑测试建一个临时数据库，跑完删掉；每个测试开始前清空表。

需要本机 Postgres 在跑（brew services start postgresql@17）。
管理连接默认连本机的 postgres 库，可用 MEMORY_TEST_ADMIN_DSN 覆盖。
"""
import asyncio
import os
import uuid

import asyncpg
import pytest

from brain.archive import apply_brain_schema
from memory.db import apply_schema, create_pool

ADMIN_DSN = os.environ.get("MEMORY_TEST_ADMIN_DSN", "postgresql://localhost/postgres")


def _dsn_for(dbname: str) -> str:
    base = ADMIN_DSN.rsplit("/", 1)[0]
    return f"{base}/{dbname}"


@pytest.fixture(scope="session")
def test_dsn():
    dbname = f"newapp_test_{uuid.uuid4().hex[:10]}"

    async def _create():
        conn = await asyncpg.connect(ADMIN_DSN)
        try:
            await conn.execute(f'CREATE DATABASE "{dbname}"')
        finally:
            await conn.close()
        await apply_schema(_dsn_for(dbname))
        await apply_brain_schema(_dsn_for(dbname))

    async def _drop():
        conn = await asyncpg.connect(ADMIN_DSN)
        try:
            await conn.execute(f'DROP DATABASE IF EXISTS "{dbname}" WITH (FORCE)')
        finally:
            await conn.close()

    asyncio.run(_create())
    yield _dsn_for(dbname)
    asyncio.run(_drop())


@pytest.fixture
async def pool(test_dsn):
    p = await create_pool(test_dsn, min_size=1, max_size=4)
    await p.execute(
        "TRUNCATE memories, sticky_notes, chat_messages, ledger_days, user_settings, user_state, "
        "personas, turn_logs, usage_daily, memory_edits, conversations, companions, keyring, sessions, login_codes, "
        "trial_devices, reactions, attachments, clocks, wake_log, push_queue, devices, focus_sessions, far_dates, drawer_letters, music_links, music_shelf, music_picks, music_votes, music_heard, music_pools, song_ears, lore, host_pairing, accounts RESTART IDENTITY CASCADE")
    yield p
    await p.close()


@pytest.fixture
def user_a():
    return uuid.uuid4()


@pytest.fixture
def user_b():
    return uuid.uuid4()


@pytest.fixture(autouse=True)
def _billing_clock_at_peak(monkeypatch):
    """记账钟钉在 DeepSeek 高峰（周四 UTC 02:00），老测试按原价算的数不随跑测试的时间变。平峰另有测试。"""
    from datetime import datetime, timezone
    import llm.catalog
    monkeypatch.setattr(llm.catalog, "_clock", lambda: datetime(2026, 10, 1, 2, 0, tzinfo=timezone.utc))


_STAMP = __import__("re").compile(r"^(?:〔\d+月\d+日 周. \d\d:\d\d〕|\[\w{3} \d+ \w{3}, \d\d:\d\d\])\n")


def unstamp(text: str) -> str:
    """去掉历史里 TA 那句前面的时间标记（11-18 turn.stamp），老测试照原话比"""
    return _STAMP.sub("", text)
