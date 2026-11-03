"""正文标记（10-31）：表情包、里程碑不走工具，写在正文里；解出来照办，写坏了的也一律剥掉。"""
from datetime import datetime, timezone
from uuid import uuid4

from brain import call_speech, markers, voice
from brain import stickers as ST


def test_number_inside_a_sentence_leaves_no_trace():
    p = markers.parse("好呀[表情包：#12]我们走")
    assert p.stickers == ["#12"] and p.text == "好呀我们走"
    e = markers.parse("sure [sticker: #4] see you")
    assert e.stickers == ["#4"] and e.text == "sure see you"
    assert markers.parse("[表情包：#7] 晚安").text == "晚安"
    m = markers.parse("今天第一次一起看日落。⟪里程碑：第一次一起看日落⟫\n\n真好")
    assert m.milestones == ["第一次一起看日落"] and m.text == "今天第一次一起看日落。\n\n真好"


def test_crooked_brackets_still_count():
    assert markers.parse("嗯【表情包：#2】").stickers == ["#2"]
    assert markers.parse("嗯［表情包：#2］").stickers == ["#2"]
    assert markers.parse("《里程碑：一百天》").milestones == ["一百天"]


def test_broken_markers_are_stripped_not_sent():
    p = markers.parse("好呀 [表情包：#3\n明天见")
    assert p.stickers == [] and p.text == "好呀\n明天见"
    assert markers.parse("哈哈[表情包]你真逗").text == "哈哈你真逗"
    q = markers.parse("⟪里程碑：第一次")
    assert q.milestones == [] and q.text == ""


def test_plain_text_untouched():
    for t in ("普通的话 [小声] 不动", "今天好累", "🎤 [soft] 晚安…"):
        assert markers.parse(t).text == t
    assert markers.scrub("晚安[表情包：#3] ⟪里程碑：一起熬夜⟫") == "晚安"


def test_call_speech_never_reads_a_marker():
    assert call_speech.clean("好呀 [表情包：#3 我们走") == "好呀"
    assert call_speech.clean("[表情包：#3]") is None


def _st(i: int, caption: str, name: str = "") -> ST.Sticker:
    return ST.Sticker(i, uuid4(), "sha", "p", "image/png", 1, caption, name, [], 0, datetime.now(timezone.utc))


def test_small_library_full_list_large_library_short_menu():
    small = ST.menu_block([_st(5, "小猫累瘫在桌上，生无可恋", "累瘫")], "zh")
    assert "#5 小猫累瘫在桌上，生无可恋（TA 叫它「累瘫」）" in small and "[表情包：#编号]" in small
    big = [_st(i, f"第{i}张图，普通的样子") for i in range(1, 41)] + [_st(999, "一只橘猫累瘫在键盘上，眼神空洞")]
    menu = ST.menu_block(big, "zh")
    assert "#999 一只橘猫累瘫在键盘上" in menu and "眼神空洞" not in menu
    assert "#999 一只橘猫累瘫在键盘上，眼神空洞" in ST.picks_block([big[-1]], "zh")
    assert ST.menu_block([], "zh") == ""


def test_resolve_by_number_or_description():
    lib = [_st(5, "小猫累瘫在桌上"), _st(12, "小狗得意地叉腰", "得意")]
    assert ST.resolve(lib, "#12").id == 12
    assert ST.resolve(lib, "＃5").id == 5
    assert ST.resolve(lib, "12 小狗得意").id == 12
    assert ST.resolve(lib, "小狗得意地叉腰").id == 12           # 旧写法
    assert ST.resolve(lib, "小狗得意叉腰").id == 12             # 抄错一个字
    assert ST.resolve(lib, "得意").id == 12                    # TA 起的名字
    assert ST.resolve(lib, "#99") is None and ST.resolve(lib, "完全不相干") is None


def test_lazy_voice_note_has_stable_id_and_rough_length():
    a = voice.lazy_public("🎤 [soft] 晚安…早点睡，明天见。")
    assert a["lazy"] and a["id"] == voice.lazy_public("🎤 [soft] 晚安…早点睡，明天见。")["id"]
    assert a["duration_ms"] // 1000 == 2
    assert voice.estimate_ms("嗯") == 1000
