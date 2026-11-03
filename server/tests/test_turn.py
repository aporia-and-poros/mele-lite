from datetime import date, datetime, timedelta, timezone

import memory as M
from brain import archive, ledger
from brain.turn import Deps, run_turn
from llm.errors import LLMError
from llm.fake import FakeModel
from llm.router import Route
from memory.embed import FakeEmbedder

NOW = datetime(2026, 9, 26, 12, tzinfo=timezone.utc)
ROUTE = Route("fake", "k", "fake-chat", "fake-ledger")


class OneKey:
    def route_for(self, user_id):
        return ROUTE


def make_deps(pool, model):
    async def nosleep(_):
        return None
    return Deps(pool=pool, embedder=FakeEmbedder(), keys=OneKey(), adapter_for=lambda route: model,
                now=lambda: NOW, sleep=nosleep)


async def turn(deps, user, text):
    events = []

    async def emit(e):
        events.append(e)
    await run_turn(deps, user, text, emit)
    return events


def of(events, kind):
    return [e for e in events if e["type"] == kind]


async def native(pool, user):
    """这几个测的是原生思考那条路（10-04 起没选默认手写独白）"""
    await archive.save_settings(pool, user, {**(await archive.get_settings(pool, user)), "thinking_mode": "native"})


async def test_simple_turn_bubbles_saved_and_accounted(pool, user_a):
    m = FakeModel(["早呀\n\n今天想做点什么？"])
    await native(pool, user_a)
    ev = await turn(make_deps(pool, m), user_a, "早")
    assert [e["text"] for e in of(ev, "bubble")] == ["早呀", "今天想做点什么？"]
    assert len(of(ev, "typing")) == 2 and ev[-1] == {"type": "done"}
    msgs = await archive.unrolled(pool, user_a)
    assert [(x.role, x.text) for x in msgs] == [("user", "早"), ("assistant", "早呀\n\n今天想做点什么？")]
    u = await archive.usage_on(pool, user_a, NOW.date())
    assert u["calls"] == 1 and u["unknown_cost_calls"] == 1          # fake-chat 不在清单里，算不出钱
    assert (await archive.get_state(pool, user_a))["turn_count"] == 1
    req = m.requests[0]
    last = req.messages[-1].text
    assert "\n\n早\n\n〔想事的时候〕\n" in last and "〔现在〕" in last                  # 思考风格压在用户这句后面（照之前自用的 App）
    assert last.index("〔现在〕") < last.index("早")
    assert [t.name for t in req.tools] == ["album", "book", "cancel_self", "diary", "drawer", "food", "list_clocks", "lore", "memory_remember", "memory_search", "moments", "music", "note_about_user", "offer_focus", "person_card", "read_manual", "relationship", "remember_date", "schedule_self", "sticky_note", "tarot", "todo", "wallet"]


async def test_history_keeps_raw_words_not_the_volatile_part(pool, user_a):
    m = FakeModel(["好", "嗯"])
    d = make_deps(pool, m)
    await turn(d, user_a, "第一句")
    await turn(d, user_a, "第二句")
    second = m.requests[1]
    assert [x.text for x in second.messages[:-1]] == ["第一句", "好"]
    assert second.messages[1].cache is True


async def test_tool_loop_runs_tools_and_emits_cards(pool, user_a):
    m = FakeModel([{"calls": [("memory_remember", {"content": "小满对芒果过敏", "importance": 8})]}, "记下啦"])
    ev = await turn(make_deps(pool, m), user_a, "我对芒果过敏")
    assert of(ev, "card")[0]["text"].startswith("记住了：")
    assert [e["text"] for e in of(ev, "bubble")] == ["记下啦"]
    assert len(m.requests[1].rounds) == 1 and m.requests[1].rounds[0].results[0].startswith("已记住")
    assert (await M.list_memories(pool, user_a))[0].content == "小满对芒果过敏"
    assert (await archive.get_state(pool, user_a))["last_tools"] == ["memory_remember"]


async def test_tool_call_written_as_text_is_run_not_shown(pool, user_a):
    # 10-15 内测：本机模式 <function_calls><invoke …> 原样进了气泡；</args_json> 还写漏了
    raw = ('<function_calls>\n<invoke name="memory_remember">\n<args_json>{"content": "小满对芒果过敏", "importance": 8}'
           '</invoke>\n</function_calls>')
    m = FakeModel([raw, "记下啦"])
    ev = await turn(make_deps(pool, m), user_a, "我对芒果过敏")
    assert [e["text"] for e in of(ev, "bubble")] == ["记下啦"]
    assert "替你调了" in m.requests[1].messages[-1].text and "已记住" in m.requests[1].messages[-1].text
    assert (await M.list_memories(pool, user_a))[0].content == "小满对芒果过敏"


async def test_text_call_to_unknown_tool_is_just_dropped(pool, user_a):
    m = FakeModel(['好呀<invoke name="nope"><parameter name="x">1</parameter></invoke>'])
    ev = await turn(make_deps(pool, m), user_a, "嗨")
    assert [e["text"] for e in of(ev, "bubble")] == ["好呀"] and len(m.requests) == 1


async def test_tool_rounds_are_capped(pool, user_a):
    script = [{"calls": [("memory_search", {"query": f"第{i}次"})]} for i in range(8)]
    script.append({"text": "不查了", "calls": [("memory_search", {"query": "还要"})]})
    m = FakeModel(script)
    ev = await turn(make_deps(pool, m), user_a, "帮我查查")
    assert len(m.requests) == 9
    assert m.requests[8].rounds[-1].results[0].endswith("（这一轮能调工具的次数用完了，接下来直接回话。）")
    assert [e["text"] for e in of(ev, "bubble")] == ["不查了"]


async def test_model_error_is_told_plainly(pool, user_a):
    m = FakeModel([LLMError("balance", "Insufficient Balance")])
    ev = await turn(make_deps(pool, m), user_a, "在吗")
    err = of(ev, "error")[0]
    assert err["kind"] == "balance" and "余额" in err["message"] and ev[-1]["type"] == "done"
    assert [x.role for x in await archive.unrolled(pool, user_a)] == ["user"]


async def test_recalled_memory_goes_into_the_volatile_part(pool, user_a):
    m = FakeModel(["嗯嗯"])
    d = make_deps(pool, m)
    await M.remember(pool, d.embedder, user_a, "小满对芒果过敏，吃了嘴唇会肿", now=NOW)
    ev = await turn(d, user_a, "小满对芒果过敏，吃了嘴唇会肿")
    assert of(ev, "recall")[0]["full"] == ["小满对芒果过敏，吃了嘴唇会肿"]
    assert "〔记忆浮上来〕\n- 小满对芒果过敏，吃了嘴唇会肿" in m.requests[0].messages[-1].text


async def test_recall_skips_in_context_and_does_not_repeat_within_a_roll(pool, user_a):
    m = FakeModel(["嗯嗯", "嗯", "嗯"])
    d = make_deps(pool, m)
    await M.remember(pool, d.embedder, user_a, "小满对芒果过敏，吃了嘴唇会肿", now=NOW - timedelta(days=1))
    await M.remember(pool, d.embedder, user_a, "小满周二晚上去游泳，游了一千米", now=NOW)   # 聊天中刚记的
    ev = await turn(d, user_a, "小满对芒果过敏，吃了嘴唇会肿")
    assert of(ev, "recall")[0]["full"] == ["小满对芒果过敏，吃了嘴唇会肿"]
    ev = await turn(d, user_a, "小满对芒果过敏，吃了嘴唇会肿")
    assert of(ev, "recall") == []                                               # 这一潮里不再想起
    ev = await turn(d, user_a, "小满周二晚上去游泳，游了一千米")
    assert of(ev, "recall") == []                                               # 原文还在上下文里


async def test_last_turn_tools_show_up_next_turn_and_history_stays_stable(pool, user_a):
    m = FakeModel([{"calls": [("memory_remember", {"content": "小满对芒果过敏", "importance": 8}),
                              ("sticky_note", {"text": "下周问考试成绩"})]}, "记下啦", "好呀", "嗯"])
    d = make_deps(pool, m)
    await native(pool, user_a)
    await archive.save_settings(pool, user_a, {**(await archive.get_settings(pool, user_a)), "thinking_style_every": 1})   # 每轮都贴风格，好看位置
    await turn(d, user_a, "我对芒果过敏")
    stored = await archive.unrolled(pool, user_a)
    assert stored[1].tools == "记住「小满对芒果过敏」\n写了便利贴"
    await turn(d, user_a, "那吃什么好")
    note = "〔上一轮你用过：记住「小满对芒果过敏」、写了便利贴〕\n那吃什么好"
    last = m.requests[2].messages[-1].text
    assert note in last and last.index(note) < last.index("〔想事的时候〕")          # 这一轮：贴在用户这句前面，思考风格压最后
    await turn(d, user_a, "晚安")
    assert m.requests[3].messages[2].text == note                               # 进了历史：逐字节一样，缓存接得上
    assert m.requests[3].messages[1].text == "记下啦" and "〔上一轮" not in m.requests[3].messages[-1].text


async def test_several_searches_in_one_turn_show_one_card(pool, user_a):
    m = FakeModel([{"calls": [("memory_search", {"query": "芒果"}), ("memory_search", {"query": "游泳"})]},
                   {"calls": [("memory_search", {"query": "阿杰"})]}, "查完了"])
    ev = await turn(make_deps(pool, m), user_a, "你还记得我什么")
    assert [e["text"] for e in of(ev, "card")] == ["翻了些记忆"]


async def test_monologue_mode_cuts_the_monologue_out(pool, user_a):
    await archive.save_settings(pool, user_a, {"thinking_mode": "monologue"})
    m = FakeModel([{"text": "[独白]\n她记着芒果。\n[/独白]", "calls": [("memory_search", {"query": "芒果"})]},
                   "[独白]查到了，放心了。[/独白]\n\n记得呢，芒果碰不得。", "嗯"])
    d = make_deps(pool, m)
    ev = await turn(d, user_a, "你还记得我对什么过敏吗")
    req = m.requests[0]
    assert req.thinking is False and "## 独白" in req.system[0].text                    # 规矩常驻壹层，原生思考关掉
    assert req.messages[-1].text.endswith("收尾，再换成对TA说话。\n〔你是Lumi〕照你自己的性格和口吻回。大多数时候一两句就够，像随手回微信。")   # 短提醒 + 人设锚（日常模式带「一两句」）压在最后
    assert of(ev, "thinking")[0]["text"] == "她记着芒果。\n\n查到了，放心了。"
    assert [e["text"] for e in of(ev, "bubble")] == ["记得呢，芒果碰不得。"]
    saved = (await archive.unrolled(pool, user_a))[-1]
    assert saved.text == "记得呢，芒果碰不得。" and "[独白]" not in saved.text and saved.thinking.startswith("她记着芒果")
    # 10-05 Aporia：「思考过程」换成「思考了 x 秒」——这一轮从开口到说完花了多久，推给 App 也存下来
    assert isinstance(of(ev, "thinking")[0]["ms"], int) and of(ev, "thinking")[0]["ms"] >= 0
    assert saved.thinking_ms == of(ev, "thinking")[0]["ms"]


async def test_person_card_offered_when_named(pool, user_a):
    m = FakeModel(["哦？"])
    d = make_deps(pool, m)
    await M.upsert_person(pool, d.embedder, user_a, "阿杰", relation="大学室友")
    await turn(d, user_a, "阿杰今天来找我了")
    assert "〔人物卡 · 阿杰〕是谁：大学室友" in m.requests[0].messages[-1].text


async def test_remembered_sentinel_fires_next_turn(pool, user_a):
    await archive.save_settings(pool, user_a, {"sentinels": {"remembered": True}})   # 出厂关着，用户自己打开
    m = FakeModel(["好，记住了", "嗯"])
    d = make_deps(pool, m)
    await turn(d, user_a, "我下周二考试")
    await turn(d, user_a, "在干嘛")
    assert "〔记住了〕" not in m.requests[0].messages[-1].text
    assert "〔记住了〕" in m.requests[1].messages[-1].text


SCRIPT_ROLL = ["好的，以后不给你推荐芒果", "游得开心吗", ""]


async def test_rolls_the_ledger_when_context_is_full(pool, user_a, monkeypatch):
    monkeypatch.setattr(ledger, "KEEP_COUNT", 2)
    await archive.save_settings(pool, user_a, {"memory_length": 1})       # 每轮都「满了」
    m = FakeModel(SCRIPT_ROLL + ["TA 说自己对芒果过敏，吃了嘴唇会肿，我答应以后不给 TA 推荐芒果。"])
    d = make_deps(pool, m)
    await turn(d, user_a, "我对芒果过敏，吃了嘴唇会肿")      # 只有一来一回，没东西可卷
    ev = await turn(d, user_a, "今天去游泳了")
    assert len(m.requests) == 4
    pick, write = m.requests[2], m.requests[3]
    assert pick.system == m.requests[1].system                                 # 挑记忆那一轮前缀跟上一轮一样
    assert [x.text for x in pick.messages[:2]] == ["我对芒果过敏，吃了嘴唇会肿", "好的，以后不给你推荐芒果"]
    assert pick.messages[-1].text.startswith("〔系统〕这不是用户在说话")
    assert write.model == "fake-ledger" and write.thinking is False
    assert {"type": "ledger", "status": "done", "count": 2} in ev
    assert [x.text for x in await archive.unrolled(pool, user_a)] == ["今天去游泳了", "游得开心吗"]
    assert "芒果过敏" in (await archive.get_ledger(pool, user_a))[date(2026, 9, 26)]
    assert (await archive.get_state(pool, user_a))["voice_samples"] == ["好的，以后不给你推荐芒果"]
    assert (await archive.get_state(pool, user_a))["recall_seen"] == []              # 卷完 = 新的一潮
    await archive.save_settings(pool, user_a, {"memory_length": 10 ** 9})
    m.script.append("嗯")
    await turn(d, user_a, "晚安")
    assert m.requests[4].system[1].text.startswith("〔账本〕") and "〔腔调样本〕" in m.requests[4].system[1].text


async def test_big_fixed_part_does_not_roll_every_turn(pool, user_a, monkeypatch):
    """10-15 内测（搬家过来）：「开头每轮都 5 万 token，一直在卷」。人设 / 说明书这些固定的部分自己就超过记性长度，
    卷账本只能卷聊天记录、怎么卷都降不下来——原来每轮都卷最老的两句（每轮多一次挑记忆 + 写账）。
    现在攒够记性长度的四分之一再卷。"""
    monkeypatch.setattr(ledger, "KEEP_COUNT", 2)
    m = FakeModel(["好", "嗯", "是呀"])
    d = make_deps(pool, m)
    await turn(d, user_a, "在吗")
    fixed = m.requests[0].estimated_prompt()
    await archive.save_settings(pool, user_a, {"memory_length": fixed // 2})     # 固定部分就超了记性长度
    ev = await turn(d, user_a, "今天好热") + await turn(d, user_a, "去游泳吧")
    assert of(ev, "ledger") == [] and len(m.requests) == 3                      # 没为两三句话专门卷一次
    assert len(await archive.unrolled(pool, user_a)) == 6


async def test_roll_ages_old_days_and_drops_ancient_ones(pool, user_a, monkeypatch):
    monkeypatch.setattr(ledger, "KEEP_COUNT", 2)
    yesterday, ancient = date(2026, 9, 25), date(2026, 9, 12)
    long_day = "TA 说今天去游泳了，游了一千米，很累但是很开心，我夸 TA 坚持得好。" * 50       # 远超昨天的 1000 字
    await archive.put_ledger(pool, user_a, {yesterday: long_day, ancient: "TA 考过了驾照。"})
    await archive.save_settings(pool, user_a, {"memory_length": 1})
    m = FakeModel(SCRIPT_ROLL + ["TA 说自己对芒果过敏，吃了嘴唇会肿，我答应以后不给 TA 推荐芒果。",
                                 "TA 去游泳了，游了一千米，很累但是很开心，我夸 TA 坚持得好。"])
    d = make_deps(pool, m)
    await turn(d, user_a, "我对芒果过敏，吃了嘴唇会肿")
    await turn(d, user_a, "今天去游泳了")
    age = m.requests[4]
    assert age.model == "fake-ledger" and "9月25日（昨天）" in age.messages[0].text        # 压旧天没配就跟写账本同一个
    got = await archive.get_ledger(pool, user_a)
    assert set(got) == {yesterday, date(2026, 9, 26)}                                        # 14 天前那天丢了
    assert got[yesterday] == "TA 去游泳了，游了一千米，很累但是很开心，我夸 TA 坚持得好。"


async def test_bad_ledger_keeps_history_and_counts_failures(pool, user_a, monkeypatch):
    monkeypatch.setattr(ledger, "KEEP_COUNT", 2)
    await archive.save_settings(pool, user_a, {"memory_length": 1})
    m = FakeModel(SCRIPT_ROLL + ["TA 中了彩票。TA 去了火星。"] * 2)                # 两条腿都编造
    d = make_deps(pool, m)
    await turn(d, user_a, "我对芒果过敏，吃了嘴唇会肿")
    ev = await turn(d, user_a, "今天去游泳了")
    assert {"type": "ledger", "status": "failed"} in ev
    assert len(await archive.unrolled(pool, user_a)) == 4
    assert await archive.get_ledger(pool, user_a) == {}
    assert (await archive.get_state(pool, user_a))["ledger_fails"] == 1
    m.script += ["好呀", "", "TA 中了彩票。", "TA 去了火星。"]
    await turn(d, user_a, "晚安")
    pick = m.requests[-3]                                                      # 又写不动：挑记忆只挑上次没挑过的那段
    assert "游得开心吗" in pick.messages[-1].text and "芒果" not in pick.messages[-1].text
    assert (await archive.get_state(pool, user_a))["ledger_fails"] == 2


async def test_users_do_not_see_each_other(pool, user_a, user_b):
    m = FakeModel(["A 的回话", "B 的回话"])
    d = make_deps(pool, m)
    await turn(d, user_a, "我是 A")
    await turn(d, user_b, "我是 B")
    assert len(m.requests[1].messages) == 1 and "我是 A" not in m.requests[1].messages[0].text


async def test_untagged_rewrites_once_when_switched_on(pool, user_a):
    """10-26 Aporia：设置里开了「没打标记重写一次」——没写 [独白] 的那段不留，补一句提醒再叫一次；没开就照常猜，不多花钱"""
    untagged = "她半夜问这个。\n\n哼，那我最喜欢：\n\n1. 额头贴着额头。\n2. 她说完一句话就亲她。"
    await archive.save_settings(pool, user_a, {"thinking_mode": "monologue", "monologue_retry": True})
    m = FakeModel([untagged, "[独白]她半夜问这个。[/独白]\n\n哼，那我最喜欢额头贴着额头。"])
    ev = await turn(make_deps(pool, m), user_a, "列出你最喜欢的接吻方式")
    assert len(m.requests) == 2 and "没写 [独白]" in m.requests[1].messages[-1].text
    assert of(ev, "thinking")[0]["text"] == "她半夜问这个。"
    assert [e["text"] for e in of(ev, "bubble")] == ["哼，那我最喜欢额头贴着额头。"]
    saved = (await archive.unrolled(pool, user_a))[-1]
    assert "没写 [独白]" not in saved.text


async def test_untagged_no_rewrite_by_default(pool, user_a):
    await archive.save_settings(pool, user_a, {"thinking_mode": "monologue", "user_pronoun": "she"})
    m = FakeModel(["她半夜问这个。\n\n哼，那我最喜欢：\n\n1. 额头贴着额头。"])
    ev = await turn(make_deps(pool, m), user_a, "列出你最喜欢的接吻方式")
    assert len(m.requests) == 1 and of(ev, "thinking")[0]["text"] == "她半夜问这个。"


async def test_monologue_without_reply_gets_one_more_try(pool, user_a):
    """09-27 深夜Aporia跟 Lumi 说再见：它只写了一小段独白就停了，正文空的，一个字没回。
    这种时候再叫它一次（这一轮的最后一句后面补一句提醒），用第二次的独白和正文。"""
    await archive.save_settings(pool, user_a, {"thinking_mode": "monologue"})
    m = FakeModel(["[独白]她要走了。[/独白]", "[独白]她要走了，要搬去新家。[/独白]\n\n好，新家见。"])
    ev = await turn(make_deps(pool, m), user_a, "我们要说再见啦")
    assert len(m.requests) == 2 and "只写了独白" in m.requests[1].messages[-1].text
    assert "只写了独白" not in m.requests[0].messages[-1].text
    assert of(ev, "thinking")[0]["text"] == "她要走了，要搬去新家。"                   # 第一次那段不重复挂
    assert [e["text"] for e in of(ev, "bubble")] == ["好，新家见。"]
    saved = (await archive.unrolled(pool, user_a))[-1]
    assert saved.text == "好，新家见。" and "只写了独白" not in saved.text


async def test_monologue_without_reply_only_retries_once(pool, user_a):
    await archive.save_settings(pool, user_a, {"thinking_mode": "monologue"})
    m = FakeModel(["[独白]嗯。[/独白]", "[独白]还是嗯。[/独白]"])
    ev = await turn(make_deps(pool, m), user_a, "晚安")
    assert len(m.requests) == 2 and of(ev, "bubble") == []


async def test_recalled_memory_counts_only_when_the_reply_uses_it(pool, user_a):
    """09-28 召回只读：浮上来不加分；它回复里真用上了才算被想起。"""
    d = make_deps(pool, FakeModel(["记得呢，芒果碰不得，嘴唇会肿的", "游泳记得带泳镜"]))
    m = (await M.remember(pool, d.embedder, user_a, "小满对芒果过敏，吃了嘴唇会肿", now=NOW - timedelta(days=3))).memory
    await turn(d, user_a, "小满对芒果过敏，吃了嘴唇会肿")
    assert (await M.get(pool, user_a, m.id)).recall_count == 1
    await turn(d, user_a, "小满对芒果过敏，吃了嘴唇会肿吗")
    assert (await M.get(pool, user_a, m.id)).recall_count == 1       # 这轮回复没用上（也可能根本没浮），不加


async def test_sentinel_hears_the_line_before_recall(pool, user_a):
    """09-28 召回哨兵：代词句「它回来就蔫蔫的」先让小模型说全，再拿去找；花的钱记账；哨兵挂了照原句。"""
    m = FakeModel(['{"recall": true, "topic": "年糕上周刚打了疫苗", "keywords": ["年糕"], "date_from": null, "date_to": null}',
                   "别担心，打完针蔫一两天正常"])
    d = make_deps(pool, m)
    d.sentinel = True
    mem = (await M.remember(pool, d.embedder, user_a, "年糕上周刚打了疫苗", now=NOW - timedelta(days=3))).memory
    await archive.add_message(pool, user_a, "user", "年糕今天去打针了", now=NOW - timedelta(minutes=5))
    ev = await turn(d, user_a, "它回来就一直蔫蔫的")
    assert "年糕今天去打针了" in m.requests[0].messages[0].text          # 哨兵读到了最近几句
    assert of(ev, "recall")[0]["full"] == ["年糕上周刚打了疫苗"]          # 假向量：只有说全的话题才对得上
    assert mem.id in (await archive.get_state(pool, user_a))["recall_seen"]
    assert await pool.fetchval("SELECT count(*) FROM usage_daily WHERE user_id = $1", user_a) >= 1


async def test_sentinel_failure_falls_back_to_raw_line(pool, user_a):
    m = FakeModel([LLMError("server", "boom"), "嗯嗯"])
    d = make_deps(pool, m)
    d.sentinel = True
    ev = await turn(d, user_a, "它回来就一直蔫蔫的")
    assert [e["text"] for e in of(ev, "bubble")] == ["嗯嗯"]              # 哨兵挂了这一轮照常回


async def test_inner_voice_is_cut_out_stored_and_sent(pool, user_a):
    await archive.save_settings(pool, user_a, {**(await archive.get_settings(pool, user_a)), "inner_voice": True})
    m = FakeModel(["来，下地。\n\n[心声]\n她喊得又急又霸道。\n[/心声]", "嗯"])
    d = make_deps(pool, m)
    ev = await turn(d, user_a, "不想动")
    assert "【心声】" in m.requests[0].system[0].text and "〔心声〕" in m.requests[0].messages[-1].text
    assert [e["text"] for e in of(ev, "bubble")] == ["来，下地。"]
    assert [e["text"] for e in of(ev, "inner_voice")] == ["她喊得又急又霸道。"]
    stored = await archive.unrolled(pool, user_a)
    assert stored[1].text == "来，下地。" and stored[1].inner_voice == "她喊得又急又霸道。"
    await turn(d, user_a, "好吧")
    assert m.requests[1].messages[1].text == "来，下地。\n\n[心声]\n她喊得又急又霸道。\n[/心声]"


async def test_backlog_is_rolled_in_batches_before_the_turn(pool, user_a, monkeypatch):
    """10-13 内测：中转不回 usage 的老版本积了几千条没卷。开口前先分批卷：挑记忆只看这一批，这一轮不再整段发出去。"""
    monkeypatch.setattr(ledger, "KEEP_COUNT", 2)
    monkeypatch.setattr(ledger, "BACKLOG_CHARS", 20)
    monkeypatch.setattr(ledger, "BATCH_CHARS", 10)
    monkeypatch.setattr(ledger, "needs_roll", lambda *a: False)          # 只看开口前那一步
    await archive.save_settings(pool, user_a, {"memory_length": 5})
    for role, text in [("user", "我对芒果过敏，吃了嘴唇会肿"), ("assistant", "好的，以后不给你推荐芒果"),
                       ("user", "今天去游泳了"), ("assistant", "游得开心吗")]:
        await archive.add_message(pool, user_a, role, text, now=NOW)
    m = FakeModel(["", "TA 说自己对芒果过敏，吃了嘴唇会肿，我答应以后不给 TA 推荐芒果。", "晚安呀"])
    ev = await turn(make_deps(pool, m), user_a, "晚安")
    pick, write, chat = m.requests
    assert [x.text for x in pick.messages[:2]] == ["我对芒果过敏，吃了嘴唇会肿", "好的，以后不给你推荐芒果"]
    assert len(pick.messages) == 3                                             # 只有这一批 + 挑记忆的话
    assert write.model == "fake-ledger"
    assert {"type": "ledger", "status": "done", "count": 2} in ev
    assert not any("芒果" in x.text for x in chat.messages)                    # 卷掉的不再跟着这一轮发
    assert "芒果过敏" in chat.system[1].text
    assert [x.text for x in await archive.unrolled(pool, user_a)] == ["今天去游泳了", "游得开心吗", "晚安", "晚安呀"]


async def test_no_backlog_no_extra_calls(pool, user_a):
    m = FakeModel(["在的"])
    await turn(make_deps(pool, m), user_a, "在吗")
    assert len(m.requests) == 1


async def test_too_long_rolls_then_retries_once(pool, user_a, monkeypatch):
    """10-14：模型窗口比记性长度小——卷账本只在成功之后，不先卷就每句都报「太长」。现在先卷，再用短了的历史试一次。"""
    monkeypatch.setattr(ledger, "KEEP_COUNT", 2)
    monkeypatch.setattr(ledger, "needs_roll", lambda *a: False)
    for role, text in [("user", "我对芒果过敏，吃了嘴唇会肿"), ("assistant", "好的，以后不给你推荐芒果"),
                       ("user", "今天去游泳了"), ("assistant", "游得开心吗")]:
        await archive.add_message(pool, user_a, role, text, now=NOW)
    m = FakeModel([LLMError("bad_request", "This model's maximum context length is 8192 tokens"), "",
                   "TA 说自己对芒果过敏，吃了嘴唇会肿，我答应以后不给 TA 推荐芒果。", "晚安呀"])
    ev = await turn(make_deps(pool, m), user_a, "晚安")
    assert not of(ev, "error") and of(ev, "bubble")
    retry = m.requests[-1]
    assert not any("芒果" in x.text for x in retry.messages) and "芒果过敏" in retry.system[1].text


async def test_too_long_twice_says_so(pool, user_a, monkeypatch):
    monkeypatch.setattr(ledger, "KEEP_COUNT", 2)
    for role, text in [("user", "我对芒果过敏，吃了嘴唇会肿"), ("assistant", "好的，以后不给你推荐芒果")]:
        await archive.add_message(pool, user_a, role, text, now=NOW)
    too_long = LLMError("bad_request", "prompt is too long")
    m = FakeModel([too_long, "", "TA 说自己对芒果过敏，吃了嘴唇会肿，我答应以后不给 TA 推荐芒果。", too_long])
    ev = await turn(make_deps(pool, m), user_a, "晚安")
    assert of(ev, "error")[0]["kind"] == "too_long" and "再发一次" in of(ev, "error")[0]["message"]


def test_context_full_reads_the_usual_wordings():
    from llm.errors import context_full
    assert context_full(LLMError("bad_request", "Error: context_length_exceeded"))
    assert context_full(LLMError("other", "请求的上下文长度超过模型限制"))
    assert context_full(LLMError("bad_request", "", status=413))
    assert not context_full(LLMError("bad_request", "invalid tool schema"))
    assert not context_full(LLMError("balance", "token limit reached for this month"))


async def test_bare_mode_keeps_features_drops_mele_voice(pool, user_a):
    # 本体化（11-03 Aporia）：独白、心声照写，只去出厂口气——范文、出厂思考风格 / 心声写法、旋钮、关系口气、「说话」那节、人设锚都不放
    await archive.save_settings(pool, user_a, {"thinking_mode": "monologue", "inner_voice": True, "bare_mode": True,
                                               "relationship": "partner", "thinking_style_every": 1})
    m = FakeModel(["[独白]\n她出差了。\n[/独白]\n\n去哪儿了？\n\n[心声]\n想她\n[/心声]"])
    ev = await turn(make_deps(pool, m), user_a, "我出差了")
    req = m.requests[0]
    system, last = req.system[0].text, req.messages[-1].text
    assert "## 独白" in system and "[独白] 和 [/独白]" in system and "范文" not in system and "怎么想" not in system
    assert "[心声] 和 [/心声]" in system and "诚实、直白" not in system
    assert "TA 说我们是恋人。" in system and "撒娇" not in system.split("底线")[0]
    assert "住在手机 app 里" not in system and "一两句就够" not in system and "## 格式" in system and "memory_remember" in system
    assert "安静的好奇心" not in system                     # 出厂性格不放
    assert "〔你是" not in last and "一两句" not in last and "〔想事的时候〕" not in last
    assert "[独白]" in last and "[心声]" in last          # 两句短提醒照贴
    assert [e["text"] for e in of(ev, "bubble")] == ["去哪儿了？"] and of(ev, "inner_voice")[0]["text"] == "想她"


async def test_bare_mode_keeps_what_the_user_wrote(pool, user_a):
    # 11-03 Aporia：我们加的风格都去掉，用户自己写的思考风格 / 心声写法 / 说话规矩照用
    await archive.save_settings(pool, user_a, {"thinking_mode": "monologue", "inner_voice": True, "bare_mode": True,
                                               "thinking_style_text": "想得慢一点", "inner_voice_style": "只写一句",
                                               "talk_rules": "不用敬语"})
    m = FakeModel(["好"])
    await turn(make_deps(pool, m), user_a, "嗨")
    system = m.requests[0].system[0].text
    assert "怎么想：\n想得慢一点" in system and "只写一句" in system and "- 不用敬语" in system and "范文" not in system
    assert "没有听众" not in system and "打草稿" not in system and "先调工具" in system and "[心声] 和 [/心声]" in system
    assert "诚实、直白" not in system and "一两句就够" not in system
