from datetime import datetime, timezone

import memory as M
from brain.tools import ToolContext, run_tool, tool_specs
from llm.types import ToolCall
from memory.embed import FakeEmbedder

E = FakeEmbedder()
NOW = datetime(2026, 9, 26, 12, tzinfo=timezone.utc)


def ctx(pool, user):
    return ToolContext(pool=pool, embedder=E, user_id=user, now=NOW)


def test_specs_sorted_and_stable():
    names = [s.name for s in tool_specs()]
    assert names == ["album", "book", "cancel_self", "diary", "drawer", "food", "list_clocks", "lore", "memory_remember", "memory_search", "moments", "music", "note_about_user", "offer_focus", "person_card", "read_manual", "relationship", "remember_date", "schedule_self", "sticky_note", "tarot", "todo", "wallet"]
    assert tool_specs() == tool_specs()          # 每次一模一样（缓存靠它）


async def test_remember_then_search(pool, user_a):
    c = ctx(pool, user_a)
    r = await run_tool(c, ToolCall("1", "memory_remember", {"content": "小满对芒果过敏", "importance": 8}))
    assert r.startswith("已记住 #") and c.cards[-1].kind == "remember"
    assert "小满对芒果过敏" in c.cards[-1].text
    s = await run_tool(c, ToolCall("2", "memory_search", {"query": "芒果"}))
    assert "小满对芒果过敏" in s and c.cards[-1].text == "翻了些记忆"


async def test_search_nothing_found(pool, user_a):
    assert await run_tool(ctx(pool, user_a), ToolCall("1", "memory_search", {"query": "火星"})) == "没找到相关的记忆。"


async def test_person_card_write_then_get_by_alias(pool, user_a):
    c = ctx(pool, user_a)
    w = await run_tool(c, ToolCall("1", "person_card", {
        "action": "write", "name": "阿杰", "relation": "大学室友", "impression": "爱开玩笑", "aliases": ["杰哥"]}))
    assert "〔人物卡 · 阿杰" in w and c.cards[-1].text == "写了人物卡：阿杰"
    g = await run_tool(c, ToolCall("2", "person_card", {"action": "get", "name": "杰哥"}))
    assert "是谁：大学室友" in g and "你的印象：爱开玩笑" in g
    assert (await M.list_people(pool, user_a))[0].created_by == "ai"
    assert await run_tool(c, ToolCall("3", "person_card", {"action": "get", "name": "秀兰"})) == "没有这张卡。"


async def test_ai_cannot_overwrite_what_user_wrote(pool, user_a):
    await M.upsert_person(pool, E, user_a, "秀兰", relation="妈妈", facts="生日 3 月 14 日")
    await run_tool(ctx(pool, user_a), ToolCall("1", "person_card", {
        "action": "write", "name": "秀兰", "facts": "生日 5 月", "impression": "很温柔"}))
    p = (await M.list_people(pool, user_a))[0]
    assert p.content == "生日 3 月 14 日" and p.impression == "很温柔"


async def test_sticky_note(pool, user_a):
    c = ctx(pool, user_a)
    assert await run_tool(c, ToolCall("1", "sticky_note", {"text": "明早问她面试怎么样"})) == "便利贴已更新。"
    assert await M.get_sticky(pool, user_a) == "明早问她面试怎么样" and c.cards[-1].kind == "sticky"


async def test_unknown_tool_and_errors_do_not_raise(pool, user_a):
    c = ctx(pool, user_a)
    assert await run_tool(c, ToolCall("1", "fly", {})) == "没有这个工具：fly"
    r = await run_tool(c, ToolCall("2", "memory_remember", {"content": "  "}))
    assert r.startswith("工具出错：") and c.cards[-1].kind == "error"
    r2 = await run_tool(c, ToolCall("3", "person_card", {"action": "delete", "name": "x"}))
    assert r2.startswith("工具出错：")


async def test_note_about_user_is_quiet_and_hidden(pool, user_a):
    c = ctx(pool, user_a)
    r = await run_tool(c, ToolCall("1", "note_about_user", {"content": "燕麦拿铁要半糖"}))
    assert r.startswith("已悄悄记下 #") and c.cards == []           # 不挂小卡片
    assert await M.list_memories(pool, user_a) == []                 # TA 看不到
    assert [m.content for m in await M.list_memories(pool, user_a, kind="about")] == ["燕麦拿铁要半糖"]


async def test_read_manual(pool, user_a):
    c = ctx(pool, user_a)
    assert "## 手册 · sticky" in await run_tool(c, ToolCall("1", "read_manual", {"name": "sticky"}))
    r = await run_tool(c, ToolCall("2", "read_manual", {"name": "astrology"}))
    assert r.startswith("没有这本手册：astrology") and "memory" in r


class Near:
    """假向量：让「芒果」两句的相似度落在 0.75～0.92 之间（像，但不到自动合并）。"""
    dim = 1024

    def embed(self, texts):
        import numpy as np
        out = np.zeros((len(texts), 1024), dtype=np.float32)
        for i, t in enumerate(texts):
            out[i, 0] = 1.0
            if "芒果" in t:
                out[i, 1] = 1.0
            if "冰淇淋" in t:
                out[i, 2] = 0.9
            out[i] /= np.linalg.norm(out[i])
        return out


async def test_similar_memory_is_not_saved_twice(pool, user_a):
    c = ToolContext(pool=pool, embedder=Near(), user_id=user_a, now=NOW)
    first = await run_tool(c, ToolCall("1", "memory_remember", {"content": "小满对芒果过敏"}))
    old_id = int(first.split("#")[1])
    r = await run_tool(c, ToolCall("2", "memory_remember", {"content": "小满吃芒果冰淇淋嘴痒"}))
    assert r.startswith(f"没存：跟已有的 #{old_id}「小满对芒果过敏」很像") and "update_id" in r
    assert len(await M.list_memories(pool, user_a)) == 1
    u = await run_tool(c, ToolCall("3", "memory_remember", {
        "content": "小满对芒果过敏，吃芒果冰淇淋也会嘴痒", "update_id": old_id, "importance": 9}))
    assert u == f"已更新 #{old_id}"
    got = await M.get(pool, user_a, old_id)
    assert got.content == "小满对芒果过敏，吃芒果冰淇淋也会嘴痒" and got.importance == 9
    f = await run_tool(c, ToolCall("4", "memory_remember", {"content": "小满芒果干也不能吃", "force_new": True}))
    assert f.startswith("已记住 #") and len(await M.list_memories(pool, user_a)) == 2


async def test_update_id_must_exist(pool, user_a):
    r = await run_tool(ctx(pool, user_a), ToolCall("1", "memory_remember", {"content": "x", "update_id": 999}))
    assert r == "没有这条可以改：#999"


async def test_sticky_rules_in_description():
    d = next(s for s in tool_specs() if s.name == "sticky_note").description
    assert "最多三条" in d and "这一周内还要跟进" in d and "事实也不写" in d and "没变化就别动" in d


def test_tool_note():
    from brain.tools import tool_note
    assert tool_note("memory_remember", {"content": "小满对芒果过敏"}, "已记住 #3", "zh") == "记住「小满对芒果过敏」"
    assert tool_note("memory_remember", {"content": "x", "update_id": 3}, "已更新 #3", "zh") == "改了记忆 #3「x」"
    assert tool_note("note_about_user", {"content": "爱喝燕麦拿铁"}, "没存：跟已有的 #5 很像", "zh") == \
        "想记「爱喝燕麦拿铁」，跟旧的很像，没存"
    assert tool_note("memory_search", {"query": "芒果"}, "", "zh") == "翻记忆「芒果」"
    assert tool_note("person_card", {"action": "write", "name": "阿杰"}, "", "en") == "wrote 阿杰's card"


def test_sticky_card_is_private():
    from brain.tools import Card
    assert Card("sticky", "写了便利贴").private and not Card("remember", "记住了：x").private


async def test_updating_an_about_entry_never_shows_a_card(pool, user_a):
    import memory as M
    from brain.tools import ToolContext, run_tool
    from llm.types import ToolCall
    from memory.embed import FakeEmbedder
    e = FakeEmbedder()
    about = (await M.remember(pool, e, user_a, "喜欢烘焙", kind="about")).memory
    ctx = ToolContext(pool=pool, embedder=e, user_id=user_a, now=None, lang="zh")
    out = await run_tool(ctx, ToolCall("c1", "memory_remember", {"content": "喜欢烘焙，拿手戚风", "update_id": about.id}))
    assert out.startswith("已更新") and ctx.cards == []
