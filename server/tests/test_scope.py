"""三层分开以后：人物卡大家共享，记忆各记各的，聊天各窗口各的（Aporia 09-27 定的 D 方案）。"""
from conftest import unstamp
from datetime import datetime, timezone

import pytest

import memory as M
from brain import accounts, archive
from brain.scope import Scope
from brain.turn import Deps, run_turn
from llm.fake import FakeModel
from llm.router import Route
from memory.embed import FakeEmbedder

NOW = datetime(2026, 9, 27, 12, tzinfo=timezone.utc)


class OneKey:
    def route_for(self, account_id):
        return Route("fake", "k", "fake-chat", "fake-ledger")


def deps(pool, model):
    async def nosleep(_):
        return None
    return Deps(pool=pool, embedder=FakeEmbedder(), keys=OneKey(), adapter_for=lambda r: model, now=lambda: NOW,
                sleep=nosleep)


async def events(d, scope, text):
    out = []

    async def emit(e):
        out.append(e)
    await run_turn(d, scope, text, emit)
    return out


async def test_people_shared_memories_and_chats_separate(pool):
    acc = await accounts.create_account(pool)
    lumi, kai = await accounts.create_companion(pool, acc), await accounts.create_companion(pool, acc)
    w1 = await accounts.new_conversation(pool, acc, lumi)
    w2 = await accounts.new_conversation(pool, acc, kai)
    m = FakeModel([{"calls": [("memory_remember", {"content": "小满对芒果过敏"}),
                              ("person_card", {"action": "write", "name": "阿杰", "impression": "她的男朋友"})]},
                   "记下啦", "嗯？"])
    d = deps(pool, m)
    await events(d, Scope(acc, lumi, w1), "我对芒果过敏，阿杰是我男朋友")
    assert [x.content for x in await M.list_memories(pool, lumi, kind="memory")] == ["小满对芒果过敏"]
    assert await M.list_memories(pool, kai, kind="memory") == []                      # 记忆各记各的
    assert [p.name for p in await M.list_people(pool, acc)] == ["阿杰"]                 # 人物卡归账号
    await events(d, Scope(acc, kai, w2), "阿杰今天来了")
    assert "〔人物卡 · 阿杰〕" in m.requests[2].messages[-1].text                        # 另一个联系人也认识阿杰
    assert "芒果" not in "".join(x.text for x in m.requests[2].messages)               # 但不知道芒果的事
    assert [x.text for x in await archive.unrolled(pool, w2)] == ["阿杰今天来了", "嗯？"]  # 聊天各窗口各的


async def test_new_window_remembers_but_starts_blank(pool):
    acc = await accounts.create_account(pool)
    lumi = await accounts.create_companion(pool, acc)
    w1 = await accounts.new_conversation(pool, acc, lumi)
    m = FakeModel([{"calls": [("memory_remember", {"content": "小满对芒果过敏"})]}, "记下啦", "好"])
    d = deps(pool, m)
    await events(d, Scope(acc, lumi, w1), "我对芒果过敏")
    w2 = await accounts.new_conversation(pool, acc, lumi)
    await events(d, await accounts.scope_for(pool, acc, w2), "小满对芒果过敏")
    req = m.requests[2]
    assert len(req.messages) == 1 and "〔记忆浮上来〕\n- 小满对芒果过敏" in req.messages[0].text   # 没有旧聊天，但记得 TA
    assert {c.id for c in await accounts.list_conversations(pool, acc, lumi)} == {w1, w2}


async def test_cannot_reach_someone_elses_window(pool):
    a, b = await accounts.create_account(pool), await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, a)
    w = await accounts.new_conversation(pool, a, comp)
    with pytest.raises(PermissionError):
        await accounts.scope_for(pool, b, w)
    with pytest.raises(PermissionError):
        await accounts.new_conversation(pool, b, comp)


async def test_incognito_does_not_know_them_and_leaves_no_trace(pool):
    from brain import rewind
    acc = await accounts.create_account(pool)
    lumi = await accounts.create_companion(pool, acc)
    w = await accounts.new_conversation(pool, acc, lumi)
    await archive.save_settings(pool, lumi, {"user_name": "小满", "user_pronoun": "she"})
    m = FakeModel([{"calls": [("memory_remember", {"content": "小满对芒果过敏"})]}, "记下啦",
                   {"calls": [("memory_remember", {"content": "偷偷记一条"})]}, "嗯", "你好呀"])
    d = deps(pool, m)
    await events(d, Scope(acc, lumi, w), "我对芒果过敏")
    inc = await rewind.start_incognito(pool, acc, lumi)
    await events(d, inc, "我对芒果过敏")
    req = m.requests[2]
    body = "".join([b.text for b in req.system] + [x.text for x in req.messages])
    assert "小满" not in body and "〔记忆浮上来〕\n-" not in body and len(req.messages) == 1   # 不知道对面是谁
    assert [t.name for t in req.tools] == ["read_manual"]                                     # 记东西的工具都拿掉
    assert [x.content for x in await M.list_memories(pool, lumi, kind="memory")] == ["小满对芒果过敏"]  # 想偷记也记不上
    await rewind.end_incognito(pool, inc)
    assert await archive.unrolled(pool, inc.conversation) == []
    assert inc.conversation not in {c.id for c in await accounts.list_conversations(pool, acc, lumi)}
    await events(d, Scope(acc, lumi, w), "在吗")
    assert [unstamp(x.text) for x in m.requests[4].messages[:2]] == ["我对芒果过敏", "记下啦"]            # 接着无痕之前聊


async def test_rewind_undoes_what_those_turns_wrote(pool):
    from brain import rewind
    acc = await accounts.create_account(pool)
    lumi = await accounts.create_companion(pool, acc)
    w = await accounts.new_conversation(pool, acc, lumi)
    sc = Scope(acc, lumi, w)
    m = FakeModel([{"calls": [("memory_remember", {"content": "小满对芒果过敏"})]}, "记下啦",
                   {"calls": [("memory_remember", {"content": "小满下周二考驾照"}),
                              ("sticky_note", {"text": "下周二问驾照考得怎么样"}),
                              ("person_card", {"action": "write", "name": "阿杰", "impression": "男朋友"})]}, "加油！",
                   {"calls": [("memory_remember", {"content": "小满对芒果过敏，连芒果味的糖也不行", "update_id": 1})]}, "好"])
    d = deps(pool, m)
    await events(d, sc, "我对芒果过敏")
    await events(d, sc, "我下周二考驾照，阿杰陪我")
    await events(d, sc, "芒果味的糖也不行")
    msgs = await archive.unrolled(pool, w)
    assert len(msgs) == 6
    # 点它第三轮的回复：这一轮撤掉（芒果那条改回去），然后重新回
    await rewind.undo_reply(pool, FakeEmbedder(), sc, msgs[5].id)
    assert [x.text for x in await archive.unrolled(pool, w)][-1] == "芒果味的糖也不行"
    assert "小满对芒果过敏" in [x.content for x in await M.list_memories(pool, lumi, kind="memory")]
    m.script.append("那糖也避开")
    out = []

    async def emit(e):
        out.append(e)
    await run_turn(d, sc, "", emit, resend=True)
    assert [x.text for x in await archive.unrolled(pool, w)][-2:] == ["芒果味的糖也不行", "那糖也避开"]
    # 点第二轮用户那句：回到没发出去的时候，这句和之后的全撤，原文还回来
    msgs = await archive.unrolled(pool, w)
    text = await rewind.rewind_to_user(pool, FakeEmbedder(), sc, msgs[2].id)
    assert text == "我下周二考驾照，阿杰陪我"
    assert [x.text for x in await archive.unrolled(pool, w)] == ["我对芒果过敏", "记下啦"]
    assert [x.content for x in await M.list_memories(pool, lumi, kind="memory")] == ["小满对芒果过敏"]   # 新记的删掉
    assert await M.get_sticky(pool, lumi) == "" and await M.list_people(pool, acc) == []
    with pytest.raises(ValueError):
        await rewind.rewind_to_user(pool, FakeEmbedder(), sc, msgs[1].id)                      # 它的回复不能当用户那句倒
    with pytest.raises(ValueError):
        await rewind.undo_reply(pool, FakeEmbedder(), sc, 999)


async def test_person_found_by_relation_and_by_search(pool):
    from brain.tools import ToolContext, run_tool
    from llm.types import ToolCall
    acc = await accounts.create_account(pool)
    timi = await accounts.create_companion(pool, acc)
    e = FakeEmbedder()
    await M.upsert_person(pool, e, acc, "Mu", relation="男朋友", facts="一起看了星际穿越")
    await M.upsert_person(pool, e, acc, "妈妈", relation="小满的妈妈，一直陪她住在墨尔本")
    hit = await M.match_people(pool, acc, "你记得我男朋友吗")
    assert [p.name for p in hit] == ["Mu"]                                    # 「是谁」是短称呼，也认
    assert [p.name for p in await M.match_people(pool, acc, "我妈今天打电话了")] == ["妈妈"]
    assert await M.match_people(pool, acc, "今天墨尔本下雨") == []            # 长的「是谁」不拿来认人
    ctx = ToolContext(pool=pool, embedder=e, user_id=timi, account_id=acc, now=NOW)
    out = await run_tool(ctx, ToolCall("c", "memory_search", {"query": "Mu 男朋友"}))
    assert "一起看了星际穿越" in out                                            # 翻记忆也翻得到账号下的人物卡
