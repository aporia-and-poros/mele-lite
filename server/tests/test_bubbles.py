from brain.bubbles import balance, sentences, split_reply, typing_delay


def test_blank_lines_make_bubbles():
    assert split_reply("早呀\n\n今天怎么样？\n\n\n我在。") == ["早呀", "今天怎么样？", "我在。"]


def test_short_paragraph_kept_whole():
    p = "我今天去了海边。风很大。"
    assert split_reply(p) == [p]


def test_long_paragraph_split_at_sentence_ends():
    p = "这是一句话，里面有一些字。" * 30
    out = split_reply(p, cap=None)
    assert len(out) == 4 and all(len(b) <= 120 for b in out)
    assert "".join(out) == p and all(b.endswith("。") for b in out)


def test_closing_quote_stays_with_its_sentence():
    assert sentences("她说：「好。」然后走了。") == ["她说：「好。」", "然后走了。"]
    assert sentences("真的吗？！太好了") == ["真的吗？！", "太好了"]


def test_english_sentences_rejoined_with_spaces():
    p = ("This is a sentence that goes on. " * 12).strip()
    out = split_reply(p, cap=None)
    assert len(out) > 1 and " ".join(out) == p


def test_long_mode_does_not_split_paragraphs():
    p = "这是一句话，里面有一些字。" * 30
    assert split_reply(p, long_mode=True) == [p]


def test_tag_only_bubble_merges_back():
    assert split_reply("好的\n\n<mood>calm</mood>") == ["好的 <mood>calm</mood>"]


def test_balance_evenly():
    assert balance(["一" * 10] * 9, 3) == ["\n\n".join(["一" * 10] * 3)] * 3


def test_balance_keeps_order_and_minimises_the_largest():
    assert balance(["x" * 100, "y" * 10, "z" * 10, "w" * 10], 2) == [
        "x" * 100, "\n\n".join(["y" * 10, "z" * 10, "w" * 10])]


def test_no_cap_or_under_cap_untouched():
    assert balance(["a", "b"], None) == ["a", "b"]
    assert balance(["a", "b"], 6) == ["a", "b"]


def test_split_reply_respects_cap_and_loses_nothing():
    text = "\n\n".join(f"第{i}段" for i in range(10))
    out = split_reply(text, cap=4)
    assert len(out) == 4 and "\n\n".join(out) == text


def test_empty():
    assert split_reply("   ") == []


def test_typing_delay_grows_and_caps():
    assert typing_delay("") == 0.4
    assert typing_delay("字" * 1000) == 2.5


def test_code_block_and_list_stay_whole():
    code = "看这个：\n\n```python\nprint(1)\n\nprint(2)\n```\n\n好了"
    assert split_reply(code, 6) == ["看这个：", "```python\nprint(1)\n\nprint(2)\n```", "好了"]
    items = "\n".join(f"- 第{i}条，这一条写得比较长比较长比较长比较长比较长比较长比较长比较长比较长。" for i in range(12))
    assert split_reply(items, 6) == [items]
