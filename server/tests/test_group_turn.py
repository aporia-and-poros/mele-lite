"""群聊里替某个 TA 跑一轮 + 私聊合别的房间（10-11）。测试用阿橘 / 小满。"""
from datetime import timedelta
from uuid import uuid5

from brain import accounts, archive, groups
from brain.scope import Scope
from brain.turn import GROUP_TOOLS, GroupCtx, run_turn
from llm.fake import FakeModel
from test_turn import NOW, make_deps


async def setup(pool):
    acc = await accounts.create_account(pool)
    ju = await accounts.create_companion(pool, acc)
    man = await accounts.create_companion(pool, acc)
    for c, n in ((ju, "阿橘"), (man, "小满")):
        await archive.save_persona(pool, c, {"name": n})
        await archive.save_settings(pool, c, {**(await archive.get_settings(pool, c)), "thinking_mode": "native",
                                              "user_name": "她"})
    g = await groups.create(pool, acc, "三人行", [ju, man], NOW - timedelta(hours=1))
    return acc, ju, man, g["id"]


async def test_group_turn_labels_others_and_saves_speaker(pool):
    acc, ju, man, gid = await setup(pool)
    u = await archive.add_message(pool, gid, "user", "今晚吃什么", now=NOW - timedelta(minutes=2))
    await archive.add_message(pool, gid, "assistant", "火锅！", speaker=man, speaker_name="小满", now=NOW - timedelta(minutes=1))
    m = FakeModel(["〔阿橘〕<ds_safety>[分类]其他</ds_safety>又吃火锅？"])
    events = []

    async def emit(e):
        events.append(e)
    out = await run_turn(make_deps(pool, m), Scope(acc, ju, gid), "今晚吃什么", emit,
                         group=GroupCtx(name="三人行", others=("小满",), user_msg=u.id))
    assert out.said
    req = m.requests[0]
    assert "【群聊】这里是群「三人行」" in req.system[0].text and "留在私聊里" in req.system[0].text
    assert req.messages[-1].text.count("〔她〕今晚吃什么") == 1 and "〔小满〕火锅！" in req.messages[-1].text
    assert {t.name for t in req.tools} == set(GROUP_TOOLS)
    saved = (await archive.unrolled(pool, gid))[-1]
    assert (saved.text, saved.speaker, saved.speaker_name) == ("又吃火锅？", ju, "阿橘")
    assert all(e.get("speaker") == str(ju) for e in events)
    assert (await archive.get_state(pool, uuid5(gid, str(ju))))["turn_count"] == 1
    assert (await pool.fetchval("SELECT last_speaker FROM conversations WHERE id = $1", gid)) == ju


async def test_own_last_line_gets_your_turn(pool):
    acc, ju, man, gid = await setup(pool)
    await archive.add_message(pool, gid, "user", "在吗", now=NOW - timedelta(minutes=2))
    await archive.add_message(pool, gid, "assistant", "在", speaker=ju, speaker_name="阿橘", now=NOW - timedelta(minutes=1))
    m = FakeModel(["还在"])
    await run_turn(make_deps(pool, m), Scope(acc, ju, gid), "在吗", lambda e: _noop(e),
                   group=GroupCtx(name="三人行", others=("小满",)))
    msgs = m.requests[0].messages
    assert msgs[-2].role == "assistant" and msgs[-2].text == "在" and "（轮到你了）" in msgs[-1].text


async def test_private_chat_sees_group_lines(pool):
    acc, ju, man, gid = await setup(pool)
    dm = await accounts.new_conversation(pool, acc, ju)
    await archive.add_message(pool, gid, "user", "群里一句", now=NOW - timedelta(minutes=5))
    await archive.add_message(pool, gid, "assistant", "小满在群里说的", speaker=man, speaker_name="小满",
                              now=NOW - timedelta(minutes=4))
    m = FakeModel(["〔群「三人行」〕嗯"])
    await run_turn(make_deps(pool, m), Scope(acc, ju, dm), "私聊来了", lambda e: _noop(e))
    texts = [x.text for x in m.requests[0].messages]
    assert texts[0] == "〔群「三人行」 · 她〕群里一句\n\n〔群「三人行」 · 小满〕小满在群里说的"
    # 10-31 内测：群里的话被接到私聊里回——告诉它现在在私聊；它学着垫的房间标签去掉
    assert "你现在在私聊" in "".join(b.text for b in m.requests[0].system)
    assert (await archive.recent(pool, dm, 5))[-1].text == "嗯"
    # 关掉就不合
    await archive.save_settings(pool, ju, {**(await archive.get_settings(pool, ju)), "other_rooms_count": 0})
    m2 = FakeModel(["嗯"])
    await run_turn(make_deps(pool, m2), Scope(acc, ju, dm), "再来", lambda e: _noop(e))
    assert all("三人行" not in x.text for x in m2.requests[0].messages)


async def test_late_joiner_sees_recent_history_with_note_or_nothing(pool):
    acc, ju, man, gid = await setup(pool)
    await archive.add_message(pool, gid, "user", "进群前说的", now=NOW - timedelta(minutes=30))
    joined = NOW - timedelta(minutes=10)
    m = FakeModel(["来了", "来了"])
    await run_turn(make_deps(pool, m), Scope(acc, ju, gid), "", lambda e: _noop(e),
                   group=GroupCtx(name="三人行", others=("小满",), joined_at=joined, sees_history=True))
    last = m.requests[0].messages[-1].text
    assert "进群前说的" in last and "你刚被拉进群" in last
    await run_turn(make_deps(pool, m), Scope(acc, man, gid), "", lambda e: _noop(e),
                   group=GroupCtx(name="三人行", others=("阿橘",), joined_at=joined, sees_history=False))
    assert all("进群前说的" not in x.text for x in m.requests[1].messages)


async def _noop(_):
    return None


async def test_group_bilingual_follows_each_ta(pool):
    """10-15 Aporia：群里也能双语——每个 TA 按自己设定里的开关来，你说的话不翻。"""
    acc, ju, man, gid = await setup(pool)
    await archive.save_settings(pool, ju, {**(await archive.get_settings(pool, ju)), "bilingual": True})
    u = await archive.add_message(pool, gid, "user", "今晚吃什么", now=NOW - timedelta(minutes=1))
    events = []

    async def emit(e):
        events.append(e)
    m = FakeModel(["Hotpot again?", '["又吃火锅？"]'])
    await run_turn(make_deps(pool, m), Scope(acc, ju, gid), "今晚吃什么", emit,
                   group=GroupCtx(name="三人行", others=("小满",), user_msg=u.id))
    assert "〔双语〕" in m.requests[0].messages[-1].text
    assert [(e["text"], e.get("translation")) for e in events if e["type"] == "bubble"] == [("Hotpot again?", "又吃火锅？")]
    said = (await archive.unrolled(pool, gid))[-1]
    assert (said.speaker, said.translations) == (ju, ["又吃火锅？"])
    assert (await archive.unrolled(pool, gid))[0].translations is None                 # 你那句不翻
    m2 = FakeModel(["火锅！"])                                                          # 小满没开：不加规矩、不翻
    await run_turn(make_deps(pool, m2), Scope(acc, man, gid), "今晚吃什么", lambda e: _noop(e),
                   group=GroupCtx(name="三人行", others=("阿橘",), user_msg=u.id))
    assert len(m2.requests) == 1 and "〔双语〕" not in m2.requests[0].messages[-1].text
    assert (await archive.unrolled(pool, gid))[-1].translations is None
