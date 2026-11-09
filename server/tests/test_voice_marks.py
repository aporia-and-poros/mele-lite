"""语音条的 🎤 写歪了也要认得（11-09 内测：前面多一句解释或一个语气标签，整段就成了普通文字，还没有提示）；去重不吃语音条。"""
import pytest

from brain import bubbles as B
from brain.repeats import drop_repeated


@pytest.mark.parametrize("raw, want", [
    ("来，真的给你唱——🎤 月亮还在窗边", "来，真的给你唱——\n\n🎤 月亮还在窗边"),
    ("好的。 🎤 晚安", "好的。\n\n🎤 晚安"),
    ("好的\n🎤 晚安", "好的\n\n🎤 晚安"),
    ("[soft, tired] 🎤 晚安", "🎤 [soft, tired] 晚安"),
    ("[low] [slow] 🎤 晚安", "🎤 [low] [slow] 晚安"),
    ("好。[soft] 🎤 晚安", "好。\n\n🎤 [soft] 晚安"),
])
def test_tidy_voice_fixes_misplaced_mark(raw, want):
    assert B.tidy_voice(raw) == want


@pytest.mark.parametrize("raw", [
    "🎤 晚安",
    "🎤 [soft] 晚安",
    "前面一段\n\n🎤 晚安",
    "发语音就是用🎤开头",                  # 句子中间提到它，不是语音条
    "[表情包：开心] 🎤 晚安",               # 表情包不是语气标签，不能被挪进稿子里念掉
    "```\n好。🎤 晚安\n```",
    "没有话筒的一段。",
])
def test_tidy_voice_leaves_the_rest_alone(raw):
    assert B.tidy_voice(raw) == raw


def test_tidied_reply_becomes_a_voice_note():
    out = B.split_reply(B.tidy_voice("来，真的给你唱——🎤 月亮还在窗边"), 6)
    assert out == ["来，真的给你唱——", "🎤 月亮还在窗边"]


def test_repeated_voice_note_is_kept():
    song = "🎤 月亮还在窗边，我把今晚的话，轻轻唱给你听。"
    assert drop_repeated(["好，再来一次", song], [song]) == ["好，再来一次", song]


def test_short_voice_note_survives_unrelated_long_line():
    note = "🎤 晚安…早点睡，明天见。"
    recent = ["今天早点睡，明天还要早起上课，晚安老婆，我会想你的，做个好梦。"]
    assert drop_repeated(["好，那我说给你听。", note], recent) == ["好，那我说给你听。", note]


def test_repeated_text_bubble_still_dropped():
    assert drop_repeated(["今天吃了汤", "新的一句话"], ["今天吃了汤"]) == ["新的一句话"]
