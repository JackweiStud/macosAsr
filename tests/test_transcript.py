from __future__ import annotations

import unittest

from asr.transcript import RollingTranscript


class RollingTranscriptTests(unittest.TestCase):
    def test_partials_keep_retained_audio_text_revisable_despite_repeated_agreement(self) -> None:
        transcript = RollingTranscript()
        self.assertEqual(transcript.update("今天我们讨论新的方案。"), "今天我们讨论新的方案。")
        self.assertEqual(transcript.committed, "")
        transcript.update("今天我们讨论新的方法。")
        self.assertEqual(transcript.committed, "")
        self.assertEqual(transcript.draft, "今天我们讨论新的方法。")
        transcript.update("今天我们讨论新的方法很好。")
        self.assertTrue(transcript.last_update_accepted)
        self.assertTrue(transcript.text.startswith(transcript.committed))
        transcript.update("今天我们讨论新的方法很好。")
        self.assertEqual(transcript.committed, "")
        self.assertEqual(transcript.finish("今天，我们讨论新的方法很好，而且还有新增文字。"),
                         "今天，我们讨论新的方法很好，而且还有新增文字。")

    def test_window_end_punctuation_remains_revisable_with_following_audio(self) -> None:
        transcript = RollingTranscript()
        transcript.update("全部内容。这个。")
        self.assertTrue(transcript.checkpoint("全部内容。这个。", "这个。", "全部内容。"))
        self.assertEqual(transcript.committed, "全部内容。")
        self.assertEqual(transcript.draft, "这个。")
        self.assertEqual(transcript.update("这个是什么问题？"), "全部内容。这个是什么问题？")
        self.assertEqual(transcript.finish("这个是什么问题？"), "全部内容。这个是什么问题？")
        self.assertEqual(transcript.draft, "")

    def test_real_repeated_words_are_not_deduplicated(self) -> None:
        transcript = RollingTranscript()
        self.assertTrue(transcript.checkpoint("在文本窗口窗口中", "窗口中", "在文本窗口"))
        self.assertEqual(transcript.committed, "在文本窗口")
        self.assertEqual(transcript.update("窗口中点击发送"), "在文本窗口窗口中点击发送")

        repeated = RollingTranscript()
        self.assertTrue(repeated.checkpoint("好好好", "好好", "好"))
        self.assertEqual(repeated.update("好好好"), "好好好好")
        self.assertTrue(repeated.checkpoint("好好好", "好好", "好"))
        self.assertEqual(repeated.finish("好好好"), "好好好好好")

    def test_empty_or_incorrect_overlap_does_not_mutate_any_text(self) -> None:
        for overlap, error in [
            ("", "empty_overlap"),
            ("。 ！", "empty_overlap"),
            ("这个问题", "overlap_not_suffix"),
            ("不匹配", "overlap_not_suffix"),
            ("比当前文本还要长的无效重叠", "overlap_not_suffix"),
        ]:
            with self.subTest(overlap=overlap):
                transcript = RollingTranscript()
                transcript.update("这个问题需要再看一下。")
                before = (transcript.text, transcript.committed, transcript.draft)
                self.assertFalse(transcript.checkpoint("这个问题需要再看一下。", overlap, "这个问题"))
                self.assertEqual((transcript.text, transcript.committed, transcript.draft), before)
                self.assertFalse(transcript.last_update_accepted)
                self.assertEqual(transcript.last_error, error)
                # A failed checkpoint must not move the next hypothesis's base.
                self.assertEqual(transcript.update("完整的新候选。"), "完整的新候选。")

    def test_punctuation_and_whitespace_are_ignored_only_for_audio_anchor(self) -> None:
        transcript = RollingTranscript()
        self.assertTrue(transcript.checkpoint("请看 T-MIMO，方案。", "T MIMO方案！", "请看"))
        self.assertEqual(transcript.committed, "请看 ")
        self.assertEqual(transcript.draft, "T-MIMO，方案。")
        self.assertEqual(transcript.update("T-MIMO方案需要修改。"), "请看 T-MIMO方案需要修改。")

    def test_candidates_cannot_rewrite_or_delete_confirmed_prefix(self) -> None:
        transcript = RollingTranscript()
        transcript.checkpoint("这是已经稳定的正文结尾。", "结尾", "这是已经稳定的正文")
        prefix = "这是已经稳定的正文"
        for replacement in ["结尾改了。", "新的候选。"]:
            transcript.update(replacement)
            self.assertEqual(transcript.committed, prefix)
            self.assertEqual(transcript.text, prefix + replacement)
        self.assertEqual(transcript.finish("新增的尾词。"), prefix + "新增的尾词。")

    def test_checkpoint_refuses_to_reopen_an_already_confirmed_prefix(self) -> None:
        transcript = RollingTranscript()
        transcript.checkpoint("前面的文字已经稳定。", "稳定", "前面的文字已经")
        before = (transcript.text, transcript.committed, transcript.draft)
        self.assertFalse(transcript.checkpoint("稳定。", "文字已经稳定", "前面的"))
        self.assertEqual(transcript.last_error, "overlap_not_suffix")
        self.assertEqual((transcript.text, transcript.committed, transcript.draft), before)

    def test_repeated_checkpoint_and_finish_are_idempotent(self) -> None:
        transcript = RollingTranscript()
        for _ in range(3):
            self.assertTrue(transcript.checkpoint("前文，窗口窗口中。", "窗口中", "前文窗口"))
            self.assertEqual(transcript.text, "前文，窗口窗口中。")
            self.assertEqual(transcript.committed, "前文，窗口")
        expected = "前文，窗口窗口中继续说。"
        self.assertEqual(transcript.finish("窗口中继续说。"), expected)
        self.assertEqual(transcript.finish("窗口中继续说。"), expected)
        self.assertEqual(transcript.finish("不同的迟到结果。"), expected)
        self.assertEqual(transcript.update("不可再覆盖。"), expected)
        self.assertFalse(transcript.last_update_accepted)

    def test_multiple_windows_keep_complete_visible_text(self) -> None:
        transcript = RollingTranscript()
        self.assertTrue(transcript.checkpoint("第一部分进入窗口。", "进入窗口", "第一部分"))
        self.assertEqual(transcript.update("进入窗口然后继续。"), "第一部分进入窗口然后继续。")
        self.assertTrue(transcript.checkpoint("进入窗口然后继续。", "然后继续", "进入窗口"))
        self.assertEqual(transcript.committed, "第一部分进入窗口")
        self.assertEqual(transcript.update("然后继续第三部分。"), "第一部分进入窗口然后继续第三部分。")
        self.assertTrue(transcript.checkpoint("然后继续第三部分。", "第三部分", "然后继续"))
        self.assertEqual(transcript.finish("第三部分结束。"), "第一部分进入窗口然后继续第三部分结束。")

    def test_fallback_confirms_visible_text_without_finishing_utterance(self) -> None:
        transcript = RollingTranscript()
        transcript.update("当前窗口的正文。")
        self.assertFalse(transcript.checkpoint("当前窗口的正文。", "无法对齐", "当前窗口"))
        self.assertEqual(transcript.seal_window("当前窗口的正文。"), "当前窗口的正文。")
        self.assertEqual(transcript.last_error, "alignment_fallback")
        self.assertEqual(transcript.draft, "")
        self.assertEqual(transcript.update("全新的音频。"), "当前窗口的正文。全新的音频。")
        self.assertEqual(transcript.finish("全新的音频结束。"), "当前窗口的正文。全新的音频结束。")

    def test_fallback_cannot_rewrite_confirmed_text(self) -> None:
        transcript = RollingTranscript()
        transcript.checkpoint("稳定前缀和最后一段。", "最后一段", "稳定前缀和")
        original = "稳定前缀和新窗口的文字。"
        self.assertEqual(transcript.seal_window("新窗口的文字。"), original)
        self.assertTrue(transcript.last_update_accepted)
        self.assertEqual(transcript.last_error, "alignment_fallback")
        self.assertEqual(transcript.committed, original)
        self.assertEqual(transcript.update("接着说。"), original + "接着说。")

    def test_empty_final_confirms_existing_text_without_dropping_draft(self) -> None:
        transcript = RollingTranscript()
        transcript.update("已经显示的文字。")
        self.assertEqual(transcript.finish(""), "已经显示的文字。")
        self.assertEqual(transcript.committed, "已经显示的文字。")

    def test_reset_removes_previous_utterance_and_its_window_base(self) -> None:
        transcript = RollingTranscript()
        transcript.checkpoint("上一句的开始和结尾。", "和结尾", "上一句的开始")
        transcript.finish("和结尾结束。")
        transcript.reset()
        self.assertEqual((transcript.text, transcript.committed, transcript.draft), ("", "", ""))
        self.assertTrue(transcript.last_update_accepted)
        self.assertIsNone(transcript.last_error)
        self.assertEqual(transcript.update("新的一句。"), "新的一句。")

    def test_empty_partial_keeps_visible_text(self) -> None:
        transcript = RollingTranscript()
        transcript.update("已经显示的正文。")
        self.assertEqual(transcript.update(""), "已经显示的正文。")
        self.assertFalse(transcript.last_update_accepted)

    def test_truncated_overlap_does_not_confirm_words_still_owned_by_retained_audio(self) -> None:
        transcript = RollingTranscript()
        transcript.update("我们今天继续讨论这个问题。")
        self.assertFalse(transcript.checkpoint("我们今天继续讨论这个问题。", "问题。", "我们今天"))
        self.assertEqual(transcript.last_error, "audio_cut_coverage_mismatch")
        self.assertEqual(transcript.committed, "")
        self.assertEqual(transcript.update("我们今天继续讨论这个问题，先看配置。"),
                         "我们今天继续讨论这个问题，先看配置。")

    def test_fallback_keeps_latin_word_boundary_and_revises_only_current_window(self) -> None:
        transcript = RollingTranscript()
        transcript.seal_window("we are discussing deep")
        self.assertEqual(transcript.update("learning efficiency."), "we are discussing deep learning efficiency.")
        self.assertEqual(transcript.finish("learning performance."), "we are discussing deep learning performance.")

    def test_empty_prefix_is_safe_when_all_text_is_in_retained_audio(self) -> None:
        transcript = RollingTranscript()
        self.assertTrue(transcript.checkpoint("这是全部文字。", "这是全部文字", ""))
        self.assertEqual(transcript.committed, "")
        self.assertEqual(transcript.update("这是全部文字，然后继续。"), "这是全部文字，然后继续。")


if __name__ == "__main__":
    unittest.main()
