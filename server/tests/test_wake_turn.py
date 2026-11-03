"""大脑的醒来入口（巡逻第 4 步）：〔醒来〕、<silent>、钟的四个工具、倒回撤钟、账本只记一行。测试用小满。"""
from datetime import datetime, timedelta, timezone

import pytest
from cryptography.fernet import Fernet

from brain import todos
from brain import accounts, archive, auth, ledger, rewind
from brain.scope import Scope
from brain.turn import Deps, run_turn
from brain.wake_text import SILENT_DID, render_wake, split_silent
from llm.errors import LLMError
from llm.fake import FakeModel
from llm.types import Usage
from llm.router import Route
from memory.embed import FakeEmbedder
from patrol import store

NOW = datetime(2026, 9, 28, 11, 0, tzinfo=timezone.utc)       # 新加坡 19:00，星期一
TZ = "Asia/Singapore"


class OneKey:
    def route_for(self, user_id):
        return Route("fake", "k", "fake-chat", "fake-ledger")


async def setup(pool, script, keys=None):
    acc = await accounts.create_account(pool)
    comp = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, comp, {"tz": TZ})
    conv = await accounts.new_conversation(pool, acc, comp)
    model = FakeModel(script)

    async def nosleep(_):
        return None
    deps = Deps(pool=pool, embedder=FakeEmbedder(), keys=keys or OneKey(), adapter_for=lambda r: model,
                now=lambda: NOW, sleep=nosleep)
    return deps, Scope(acc, comp, conv), model


async def go(deps, scope, text="", wake=None):
    ev = []

    async def emit(e):
        ev.append(e)
    out = await run_turn(deps, scope, text, emit, wake=wake)
    return out, ev


def wake_text(reason="whim", note=""):
    return render_wake("zh", reason, NOW, TZ, last_at=NOW - timedelta(hours=3), last_by="user", found_today=0, note=note)


def test_render_wake_has_the_full_reasoning():
    t = render_wake("zh", "self", NOW, TZ, last_at=NOW - timedelta(hours=26), last_by="assistant", found_today=2,
                    note="问问面试怎么样")
    assert t.startswith("〔醒来〕") and "星期一 19:00" in t and "26 小时以前" in t and "最后一句是我说的" in t
    assert "我约这个钟时写给自己的：「问问面试怎么样」" in t and "主动找 TA 不是打扰" in t and "<silent>" in t
    assert "我们还没说过话" in render_wake("zh", "whim", NOW, TZ, last_at=None, last_by=None, found_today=0)
    en = render_wake("en", "asleep", NOW, TZ, last_at=None, last_by=None, found_today=0)
    assert en.startswith("〔Wake〕") and "Monday 19:00" in en and "<silent>" in en


def test_must_speak_wakes_have_no_way_out():
    # Aporia 09-28：TA 要它开口的地方（TA 定的钟、初见、记着的日子）它一定要开口——不给「也可以不找」，不提 <silent>
    t = render_wake("zh", "user", NOW, TZ, last_at=None, last_by=None, found_today=0, note="提醒我交房租")
    assert "这是 TA 自己定的约。一定要开口，只用想说什么。" in t and "TA 定这个钟时写的：「提醒我交房租」" in t
    assert "<silent>" not in t and "也可以不找" not in t and "不用想" not in t
    en = render_wake("en", "user", NOW, TZ, last_at=None, last_by=None, found_today=0)
    assert "<silent>" not in en and "I must speak" in en
    assert "<silent>" in render_wake("zh", "self", NOW, TZ, last_at=None, last_by=None, found_today=0)


def test_split_silent():
    assert split_silent("  <silent> ") == (True, "")
    assert split_silent("嗯……<silent>") == (False, "嗯……")
    assert split_silent("诶，面试怎么样") == (False, "诶，面试怎么样")


async def test_silent_leaves_nothing(pool):
    deps, scope, model = await setup(pool, [{"text": "<silent>", "thinking": "TA 在吃饭吧"}])
    out, ev = await go(deps, scope, wake=wake_text())
    assert out.said is False and ev == []                                         # 连「正在输入」都没闪
    assert await archive.recent(pool, scope.conversation) == []
    assert (await archive.usage_on(pool, scope.account, NOW.date()))["calls"] == 1   # 钱照记
    assert model.requests[0].messages[-1].text.count("〔醒来〕") == 1


async def test_silent_but_did_things_leaves_a_note(pool):
    """10-30 内测：醒来去做了自己的事（用了工具）但没找 TA——留一条〔醒来〕，下一轮看得到、账本记一行"""
    deps, scope, model = await setup(pool, [
        {"calls": [("memory_search", {"query": "论坛"})]}, "<silent>", "嗯，我在"])
    out, ev = await go(deps, scope, wake=wake_text())
    assert out.said is False and ev == []
    msgs = await archive.recent(pool, scope.conversation)
    assert [m.role for m in msgs] == ["wake"] and msgs[0].text.startswith(SILENT_DID["zh"]) and "论坛" in msgs[0].text
    await go(deps, scope, "你醒啦")
    req = model.requests[-1]
    assert [m.role for m in req.messages] == ["user"]                 # 那条和 TA 的话并成一段，不连着两条
    said = req.messages[0].text
    assert SILENT_DID["zh"] in said and said.index(SILENT_DID["zh"]) < said.index("你醒啦")
    day = ledger.day_transcripts(await archive.recent(pool, scope.conversation), TZ, "zh")
    assert "做了自己的事" not in str(day) and "论坛" in str(day) and "去找 TA" not in str(day)


async def test_said_saves_wake_then_reply_and_next_turn_sees_it(pool):
    deps, scope, model = await setup(pool, ["诶，面试怎么样了？", "那就好"])
    out, ev = await go(deps, scope, wake=wake_text())
    assert out.said and [e["text"] for e in ev if e["type"] == "bubble"] == ["诶，面试怎么样了？"]
    assert ev[-1] == {"type": "done"}
    msgs = await archive.recent(pool, scope.conversation)
    assert [m.role for m in msgs] == ["wake", "assistant"] and msgs[0].text.startswith("〔醒来〕")
    await go(deps, scope, "还行，过了")
    req = model.requests[1]
    assert [m.role for m in req.messages] == ["user", "assistant", "user"]
    assert req.messages[0].text.startswith("〔醒来〕") and req.messages[1].text == "诶，面试怎么样了？"


async def test_wake_error_is_not_pushed(pool):
    deps, scope, _ = await setup(pool, [LLMError("balance", "no money")])
    out, ev = await go(deps, scope, wake=wake_text())
    assert out.error == "balance" and ev == [] and await archive.recent(pool, scope.conversation) == []


async def test_trial_only_spent_when_it_speaks(pool):
    box = auth.KeyBox(Fernet.generate_key())
    trial = Route("fake", "ours", "deepseek-flash", "deepseek-flash", trial=True)
    deps, scope, _ = await setup(pool, [{"text": "<silent>", "usage": Usage(input=100_000)},
                                        {"text": "在吗", "usage": Usage(input=100_000)}], keys=None)
    deps.keys = auth.DbKeys(pool, box, trial)
    await pool.execute("UPDATE accounts SET trial_micro = 50000, trial_day = '2999-01-01' WHERE id = $1", scope.account)
    await go(deps, scope, wake=wake_text())          # 醒了没开口：成本我们认，不扣
    assert await pool.fetchval("SELECT trial_micro FROM accounts WHERE id = $1", scope.account) == 50000
    await go(deps, scope, wake=wake_text())          # 开口了：按真花的扣（0.03 美元）
    assert await pool.fetchval("SELECT trial_micro FROM accounts WHERE id = $1", scope.account) == 20000


async def test_reminder_and_self_clock_tools(pool):
    deps, scope, _ = await setup(pool, [
        {"calls": [("todo", {"action": "add", "what": "交房租", "at": "2026-09-29 08:00"}),
                   ("schedule_self", {"at": "2026-09-29 20:00", "note": "问问面试怎么样"})]},
        "好，明早八点提醒你"])
    out, ev = await go(deps, scope, "明早八点提醒我交房租，我明天下午面试")
    cards = [e for e in ev if e["type"] == "card"]
    assert [(c["kind"], c["text"], c["private"]) for c in cards] == [
        ("todo", "加了待办：交房租 · 9/29 08:00", False), ("self_clock", "给自己约了：2026-09-29 20:00 问问面试怎么样", True)]
    [t] = await todos.list_all(pool, scope.account)
    assert (t.what, t.created_by) == ("交房租", "ai")
    at = await pool.fetchval("SELECT next_at FROM clocks WHERE todo_id = $1", t.id)
    assert at == datetime(2026, 9, 29, 0, 0, tzinfo=timezone.utc)                          # 新加坡 8 点 = UTC 0 点
    self_clocks = await store.list_clocks(pool, scope.account, scope.companion, kinds=("self",))
    assert [c.note for c in self_clocks] == ["问问面试怎么样"]
    msgs = await archive.recent(pool, scope.conversation)
    assert "待办：加了「交房租」" in msgs[-1].tools


async def test_todo_tool_place_done_delete(pool):
    deps, scope, model = await setup(pool, [
        {"calls": [("todo", {"action": "add", "what": "买东西", "place": "图书馆", "on": "leave"})]},
        {"calls": [("todo", {"action": "add", "what": "买东西", "place": "学校", "on": "leave"})]},
        {"calls": [("todo", {"action": "list"})]}, {"calls": [("todo", {"action": "done", "id": 0})]},
        {"calls": [("todo", {"action": "delete", "id": 0})]}, "好"])
    await todos.add_place(pool, scope.account, name="学校", lat=0, lon=0)
    mine = await todos.create(pool, scope.account, scope.companion, what="写作业", now=NOW)
    model.script[3] = {"calls": [("todo", {"action": "done", "id": mine.id})]}
    model.script[4] = {"calls": [("todo", {"action": "delete", "id": mine.id})]}
    await go(deps, scope, "放学后提醒我买东西")
    res = [r.rounds[-1].results[0] for r in model.requests[1:]]
    assert "没找到「图书馆」" in res[0] and "学校" in res[0]
    assert res[1].startswith("加好了") and "离开学校时" in res[1]
    assert "写作业" in res[2] and "离开学校时" in res[2]
    assert res[3] == f"勾掉了 #{mine.id}。" and "你删不了" in res[4]


async def test_clock_tool_errors_go_back_to_the_model(pool):
    deps, scope, model = await setup(pool, [{"calls": [("todo", {"action": "add", "what": "过去", "at": "2026-09-01 08:00"}),
                                                       ("schedule_self", {"at": "明天", "note": "?"})]}, "好"])
    for i in range(20):
        await store.add_clock(pool, scope.account, scope.companion, kind="self", shape="once",
                              spec={"at": NOW.isoformat()}, note=str(i), next_at=NOW + timedelta(days=1))
    await go(deps, scope, "嗯")
    results = model.requests[1].rounds[0].results
    assert "已经过了" in results[0] and "20 个" in results[1]


async def test_cancel_and_list(pool):
    deps, scope, model = await setup(pool, [{"calls": [("list_clocks", {})]}, {"calls": [("cancel_self", {"id": 0})]},
                                            "好"])
    c = await store.add_clock(pool, scope.account, scope.companion, kind="self", shape="once",
                              spec={"at": NOW.isoformat()}, note="看看感冒", next_at=NOW + timedelta(days=1))
    model.script[1] = {"calls": [("cancel_self", {"id": c.id})]}
    await go(deps, scope, "我感冒好了")
    listing = model.requests[1].rounds[0].results[0]
    assert f"#{c.id} 2026-09-29 19:00 看看感冒" in listing and "todo" in listing
    assert await store.count_self(pool, scope.companion) == 0


async def test_rewind_takes_the_todo_back(pool):
    deps, scope, _ = await setup(pool, [{"calls": [("todo", {"action": "add", "what": "交房租", "at": "2026-09-29 08:00"})]},
                                        "好"])
    await go(deps, scope, "明早提醒我交房租")
    user = (await archive.recent(pool, scope.conversation))[0]
    await rewind.rewind_to_user(pool, deps.embedder, scope, user.id)
    assert await todos.list_all(pool, scope.account) == []
    assert await pool.fetchval("SELECT count(*) FROM clocks WHERE kind = 'todo'") == 0


async def test_reply_after_wake_cannot_be_rewound(pool):
    deps, scope, _ = await setup(pool, ["早呀"])
    await go(deps, scope, wake=wake_text())
    reply = (await archive.recent(pool, scope.conversation))[-1]
    with pytest.raises(ValueError):
        await rewind.undo_reply(pool, deps.embedder, scope, reply.id)


async def test_ledger_writes_one_line_for_a_wake(pool):
    deps, scope, _ = await setup(pool, ["早呀"])
    await go(deps, scope, wake=wake_text())
    msgs = await archive.recent(pool, scope.conversation)
    day = ledger.day_transcripts(msgs, TZ, "zh")
    text = "\n".join(next(iter(day.values())))
    assert "〔醒来〕" not in text and "（我自己醒来，去找 TA）" in text and "我：早呀" in text
    assert ledger.plan_roll(msgs, keep_count=1).kept[0].role == "wake"


async def test_monologue_mode_gets_the_think_first_note(pool):
    deps, scope, model = await setup(pool, ["[独白]她大概睡了，但我想说。[/独白]\n晚安"])
    await archive.save_settings(pool, scope.companion, {"tz": TZ, "thinking_mode": "monologue"})
    out, ev = await go(deps, scope, wake=wake_text())
    assert "先写独白：" in model.requests[0].messages[-1].text.split("为什么醒")[0]
    assert out.said and [e["text"] for e in ev if e["type"] == "thinking"] == ["她大概睡了，但我想说。"]
    deps2, scope2, model2 = await setup(pool, ["<silent>"])
    await archive.save_settings(pool, scope2.companion, {"tz": TZ, "thinking_mode": "native"})
    await go(deps2, scope2, wake=wake_text())
    assert "独白" not in model2.requests[0].messages[-1].text
    deps3, scope3, model3 = await setup(pool, ["[独白]房租。[/独白]\n交房租啦"])
    await archive.save_settings(pool, scope3.companion, {"tz": TZ, "thinking_mode": "monologue"})
    await go(deps3, scope3, wake=wake_text("user", "提醒我交房租"))
    head = model3.requests[0].messages[-1].text.split("为什么醒")[0]
    assert "先写独白：" in head and "想不想说" not in head and "<silent>" not in head


# ── 关系那行 + 初见（iOS 第二块第 6 步，措辞Aporia 09-28 过目）──

def test_relationship_line_in_wake():
    from brain.wake_text import render_wake as rw
    base = dict(last_at=None, last_by=None, found_today=0)
    assert "TA 说我们是朋友。" in rw("zh", "whim", NOW, TZ, relationship="friend", **base)
    assert "不用每句都甜" in rw("zh", "whim", NOW, TZ, relationship="partner", **base)
    assert "TA 说我们的关系是：「饭搭子」。" in rw("zh", "whim", NOW, TZ, relationship="饭搭子", **base)
    assert "TA 说我们" not in rw("zh", "whim", NOW, TZ, relationship="", **base)
    assert "They say we're friends." in rw("en", "whim", NOW, TZ, relationship="friend", **base)


def test_first_meet_text():
    from brain.wake_text import render_first_meet
    t = render_first_meet("zh", NOW, TZ, user_name="小满", relationship="friend")
    assert t.startswith("〔初见〕") and "TA 叫小满" in t and "说我们是朋友" in t and "有什么可以帮你" in t
    bare = render_first_meet("zh", NOW, TZ, user_name="", relationship="")
    assert "TA 叫" not in bare and "说我们是" not in bare and "TA 刚装好 app。" in bare
    assert "They just installed the app, told me their name is Mia" in render_first_meet(
        "en", NOW, TZ, user_name="Mia", relationship="")


async def test_greet_once_and_free(pool):
    from test_api import Env
    e = Env(pool, ["嗨，小满！我是 Lumi。你今天过得怎么样？"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.put("/me/profile", json={"name": "小满", "pronoun": "she", "looks": ""})
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"relationship": "friend"}})
        r = await c.post(f"/companions/{comp['id']}/greet")
        assert r.status_code == 202
        for _ in range(100):
            msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
            if msgs:
                break
            import asyncio
            await asyncio.sleep(0.02)
        assert [m["role"] for m in msgs] == ["assistant"] and "小满" in msgs[0]["text"]
        env = e.model.requests[0].messages[-1].text
        assert "〔初见〕" in env and "TA 叫小满" in env
        assert (await c.post(f"/companions/{comp['id']}/greet")).status_code == 409


async def test_offer_focus_only_hangs_a_card(pool):
    deps, scope, _ = await setup(pool, [{"calls": [("offer_focus", {"minutes": 120, "label": "复习期末"})]}, "去吧，我陪你"])
    out, ev = await go(deps, scope, "我要学两个小时")
    [card] = [e for e in ev if e["type"] == "card"]
    assert (card["kind"], card["text"], card["data"]) == ("focus", "复习期末 · 120 分钟", {"minutes": 120, "label": "复习期末"})
    assert await pool.fetchval("SELECT count(*) FROM focus_sessions") == 0          # 只提议，不开
    msg = (await archive.recent(pool, scope.conversation))[-1]
    assert msg.cards == [{"kind": "focus", "text": "复习期末 · 120 分钟", "data": {"minutes": 120, "label": "复习期末"}}]


async def test_relationship_tool_changes_the_pack_and_hangs_a_card(pool):
    # 09-29 Aporia：TA 表白、它接受了，关系自动从朋友变恋人（只能 TA 先开口，写在工具说明里）；聊天里挂一张卡，设置跟着改
    deps, scope, _ = await setup(pool, [{"calls": [("relationship", {"to": "partner"})]}, "嗯，在一起。"])
    out, ev = await go(deps, scope, "我喜欢你，我们在一起吧")
    [card] = [e for e in ev if e["type"] == "card"]
    assert (card["kind"], card["data"]) == ("relationship", {"to": "partner"}) and card["text"] == "你们在一起了"
    assert card["private"] and {"type": "relationship", "to": "partner"} in ev      # 聊天里不挂卡，只叫手机换图标
    assert (await archive.get_settings(pool, scope.companion))["relationship"] == "partner"
    from brain.tools import _TOOLS, ToolContext
    ctx = ToolContext(pool=pool, embedder=None, user_id=scope.companion, now=deps.now())
    assert "不认识" in await _TOOLS["relationship"][1](ctx, {"to": "soulmate"})
