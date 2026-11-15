import pytest

from brain.persona import FACTORY, PRODUCT_BASE, Persona, persona_cost, render_base
from brain.settings import SENTINELS, Injection, Settings
from brain.tokens import estimate_tokens


def test_estimate_tokens():
    assert estimate_tokens("") == 0
    assert estimate_tokens("你好世界") == 4
    assert estimate_tokens("abcdefgh") == 2
    assert estimate_tokens("你好 abcd") == 2 + 2        # 空格和字母一起按四个一个算


def test_settings_defaults_and_roundtrip():
    s = Settings.from_dict(None)
    assert s.lang == "zh" and s.max_bubbles == 6 and s.recall_level == "medium"
    assert s.sentinels == {"thinking_style": True, "tool_reminder": True, "remembered": True}
    s2 = Settings.from_dict({"lang": "en", "max_bubbles": None, "unknown_key": 1,
                             "injections": [{"id": "a", "name": "口吻", "text": "〔口吻〕…", "mode": "every_n", "n": 2}]})
    assert s2.lang == "en" and s2.max_bubbles is None
    assert s2.injections == [Injection(id="a", name="口吻", text="〔口吻〕…", mode="every_n", n=2)]
    assert Settings.from_dict(s2.to_dict()) == s2


def test_settings_fills_new_sentinels_with_defaults():
    s = Settings.from_dict({"sentinels": {"tool_reminder": False}})
    assert s.sentinels == {"thinking_style": True, "tool_reminder": False, "remembered": True}


@pytest.mark.parametrize("bad", [
    {"lang": "fr"}, {"recall_level": "max"}, {"max_bubbles": 0}, {"tz": "Mars/Base"},
    {"injections": [{"id": "a", "name": "x", "text": "y", "mode": "sometimes"}]},
])
def test_settings_rejects_bad_values(bad):
    with pytest.raises(ValueError):
        Settings.from_dict(bad)


def test_persona_from_dict_fills_factory():
    p = Persona.from_dict({"name": "阿澄"}, "zh")
    assert p.name == "阿澄" and p.personality == FACTORY["zh"].personality
    assert Persona.from_dict(None, "en") == FACTORY["en"]


def test_render_base_character_and_core():
    text = render_base(Persona.from_dict({"call_user": "小满"}, "zh"), ["她对芒果过敏", "她叫小满"], "zh")
    assert text.startswith(PRODUCT_BASE["zh"].split("{relationship}")[0].strip())
    assert "名字：Lumi" in text and "怎么称呼对方：小满" in text
    assert text.endswith("## 一直记着的\n- 她对芒果过敏\n- 她叫小满")


def test_imported_persona_replaces_character_not_base():
    text = render_base(Persona.from_dict({"imported": "你是一只会说话的猫。"}, "zh"), [], "zh")
    assert PRODUCT_BASE["zh"].split("{relationship}")[1].strip() in text and "你是一只会说话的猫。" in text
    assert "名字：" not in text and "一直记着的" not in text


def test_render_base_english():
    assert "## Who you are" in render_base(FACTORY["en"], [], "en")


def test_persona_cost():
    low, high = persona_cost("字" * 10_000, "deepseek-flash")
    assert low == pytest.approx(10_000 * 0.006 / 1e6) and high == pytest.approx(10_000 * 0.30 / 1e6)
    assert persona_cost("x", "custom-model") is None


def test_render_base_puts_character_after_handbook_before_core():
    text = render_base(FACTORY["zh"], ["她叫小满"], "zh")
    handbook, who, core = text.index("# 说明书"), text.index("## 你是谁"), text.index("## 一直记着的")
    assert handbook < who < core                     # 10-01：人设是聊天记录之前最后看到的那段，防脱离人设
    assert "## 手册 · memory" in text and "note_about_user" in text


def test_persona_stores_only_overrides_and_old_factory_text_follows_new():
    from brain.persona import _RETIRED_FACTORY
    p = Persona.from_dict({"name": "阿澄"}, "zh")
    assert p.overrides("zh") == {"name": "阿澄"}                               # 出厂那几项不存
    old = next(t for t in _RETIRED_FACTORY if t.startswith("温和"))
    assert Persona.from_dict({"personality": old}, "zh").personality == FACTORY["zh"].personality


def test_gender_and_tone_lines_in_base():
    from brain.persona import tone_lines
    assert tone_lines("zh") == ["我偶尔开个轻的玩笑，点到为止。"]                 # 刚好那档只有幽默有一句
    assert tone_lines("zh", warmth="high", initiative="low", humor="low") == [
        "我的关心很外露：会多问一句、多叮嘱一句，愿意把暖意说出来。", "我不太主动开话题，多半等对方开口。", "我很少开玩笑，说话偏认真。"]
    base = render_base(Persona.from_dict({"gender": "female"}, "zh"), [], "zh", tone=tone_lines("zh"))
    assert "名字：Lumi\n我是女生。\n性格：我有一种安静的好奇心" in base and "点到为止。" in base
    # 导入的人设也带上性别那句；没设性别的一句都不加（09-28）
    imp = render_base(Persona.from_dict({"gender": "male", "imported": "我叫阿澄。"}, "zh"), [], "zh")
    assert "## 你是谁\n我是男生。\n我叫阿澄。" in imp
    assert "我是女生" not in render_base(Persona.from_dict({}, "zh"), [], "zh")
    assert "性别" not in render_base(FACTORY["zh"], [], "zh")                     # 出厂不说
    assert "我不吃醋、不占有" in render_base(FACTORY["zh"], [], "zh")
    assert "I don't get jealous" in render_base(FACTORY["en"], [], "en")


def test_relationship_pack_swaps_the_friend_paragraph():
    # 09-29 Aporia：关系包——底子里「我跟 TA 是什么关系」按 TA 选的换，只放这一种
    friend, partner = render_base(FACTORY["zh"], [], "zh"), render_base(FACTORY["zh"], [], "zh", relationship="partner")
    assert "不会自己先把关系往恋人那边推" in friend and "TA 说我们是恋人" not in friend
    assert "TA 说我们是恋人" in partner and "不会自己先把关系往恋人那边推" not in partner
    assert "TA 说我们是：「青梅竹马」" in render_base(FACTORY["zh"], [], "zh", relationship="青梅竹马")
    assert "They say we're buddies" in render_base(FACTORY["en"], [], "en", relationship="buddy")
    assert "{relationship}" not in friend and "## 说话" in friend


def test_tone_settings_validated():
    import pytest
    assert Settings().warmth == "mid"
    with pytest.raises(ValueError):
        Settings.from_dict({"humor": "max"})


def test_offline_base_does_not_pin_them_to_a_phone():
    on = render_base(FACTORY["zh"], [], "zh")
    off = render_base(FACTORY["zh"], [], "zh", chat_rules=False)        # 长文 = 线下（10-01）
    assert "住在手机 app 里" in on and "住在手机 app 里" not in off
    assert "是见面还是隔着屏幕，照人设里的场景和你们的对话来" in off and "露骨的性内容不写" in off
    assert "living in a phone app" not in render_base(FACTORY["en"], [], "en", chat_rules=False)


def test_imported_persona_keeps_what_to_call_user():
    """导了卡也认「TA 怎么叫你」（11-12，跟 Lite 本机一样）；没填就不多一行"""
    text = render_base(Persona.from_dict({"imported": "你是一只会说话的猫。", "call_user": "小满"}, "zh"), [], "zh")
    assert "你是一只会说话的猫。" in text and "小满" in text
    plain = render_base(Persona.from_dict({"imported": "你是一只会说话的猫。"}, "zh"), [], "zh")
    assert "小满" not in plain
