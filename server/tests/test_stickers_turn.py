"""表情包（10-31 起不走工具）：壹层里给它一张编号表，它在正文里写 [表情包：#12]，回复写完这边挂一张 kind=sticker 的卡、
跟回复一起存；夹在句子中间也行，正文不留痕；只给别人的、表里没有的不发，标记照样剥掉。测试用小满。"""
from brain import archive
from brain import stickers as S
from brain.tools import tool_specs
from test_stickers import pic
from test_wake_turn import go, setup


def _system(req) -> str:
    return "\n".join(b.text for b in req.system)


async def test_marker_sends_sticker_in_one_round(pool, tmp_path):
    deps, scope, model = await setup(pool, ["", "嗯"])
    smug, _ = await S.add(pool, deps.embedder, tmp_path, scope.account, data=pic((1, 1, 1)),
                          caption="一只叉腰的猫，很得意", name="叉腰")
    model.script[0] = f"哼哼[表情包：#{smug.id}]我就知道"
    out, ev = await go(deps, scope, "我今天被夸了！")
    assert len(model.requests) == 1                                  # 没有工具来回
    assert f"#{smug.id} 一只叉腰的猫，很得意（TA 叫它「叉腰」）" in _system(model.requests[0])
    assert "sticker" not in [t.name for t in model.requests[0].tools]
    cards = [e for e in ev if e["type"] == "card"]
    assert [(c["kind"], c["data"], c["private"]) for c in cards] == [("sticker", {"sticker_id": smug.id}, False)]
    assert [e["text"] for e in ev if e["type"] == "bubble"] == ["哼哼我就知道"]
    msg = (await archive.recent(pool, scope.conversation))[-1]
    assert msg.text == "哼哼我就知道" and f"发了表情包「#{smug.id}" in msg.tools
    assert await pool.fetchval("SELECT use_count FROM stickers WHERE id = $1", smug.id) == 1


async def test_only_for_someone_else_or_unknown_number_not_sent(pool, tmp_path):
    from brain import accounts
    deps, scope, model = await setup(pool, ["", "嗯"])
    other = await accounts.create_companion(pool, scope.account)
    s, _ = await S.add(pool, deps.embedder, tmp_path, scope.account, data=pic((2, 2, 2)), caption="小狗哭")
    await S.update(pool, deps.embedder, scope.account, s.id, only_for=[other])
    model.script[0] = f"呜呜 [表情包：#{s.id}] 好吧 [表情包：#99999"
    out, ev = await go(deps, scope, "嗯")
    assert "小狗哭" not in _system(model.requests[0])
    assert not [e for e in ev if e["type"] == "card"]
    assert [e["text"] for e in ev if e["type"] == "bubble"] == ["呜呜 好吧"]


def test_incognito_has_no_sticker_tool():
    assert "sticker" not in [s.name for s in tool_specs(incognito=True)]
    assert "sticker" not in [s.name for s in tool_specs()]
