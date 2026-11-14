"""Tests of Scripts/ci_ui_select.py: tiers, budgets and what a push selects."""
import unittest

import ci_ui_select as sel

LIST = """
# a comment
stub_a.py AlphaUITests/test_one --smoke
stub_a.py AlphaUITests/test_two
stub_a.py AlphaUITests/test_three --release
stub_b.py BetaUITests/test_four --media x.png --erase
stub_b.py BetaUITests/test_five --release
"""

SOURCE = """final class AlphaUITests: XCTestCase {

    private func helper() {
        tap()
    }

    /// One.
    func test_one() throws {
        helper()
        check()
    }

    func test_two() throws {
        helper()
    }

    func test_three() throws {
        helper()
    }
}
"""


def names(lines, indices):
    return [lines[index][1].split("/")[1] for index in indices]


class Tiers(unittest.TestCase):
    def setUp(self):
        self.lines = sel.parse_list(LIST)

    def test_parse_drops_comments_and_blanks(self):
        self.assertEqual(len(self.lines), 5)
        self.assertEqual([sel.tier(words) for words in self.lines],
                         ["smoke", "core", "release", "core", "release"])

    def test_a_line_cannot_be_smoke_and_release(self):
        with self.assertRaises(sel.ListError):
            sel.parse_list("stub.py A/test --smoke --release")

    def test_a_line_needs_a_stub_and_a_selector(self):
        with self.assertRaises(sel.ListError):
            sel.parse_list("stub.py")

    def test_all_runs_every_line(self):
        self.assertEqual(sel.select(self.lines, "all"), [0, 1, 2, 3, 4])

    def test_core_leaves_the_release_lines(self):
        self.assertEqual(names(self.lines, sel.select(self.lines, "core")), ["test_one", "test_two", "test_four"])

    def test_unknown_scope(self):
        with self.assertRaises(sel.ListError):
            sel.select(self.lines, "changed")

    def test_budgets(self):
        sel.check_budgets(self.lines, smoke_max=1, core_max=3)
        with self.assertRaises(sel.ListError):
            sel.check_budgets(self.lines, smoke_max=0, core_max=3)
        with self.assertRaises(sel.ListError):
            sel.check_budgets(self.lines, smoke_max=1, core_max=2)


class Gate(unittest.TestCase):
    def setUp(self):
        self.lines = sel.parse_list(LIST)
        self.base = {sel.key(words) for words in self.lines}

    def gate(self, **arguments):
        arguments.setdefault("base_keys", self.base)
        return names(self.lines, sel.select(self.lines, "gate", **arguments))

    def test_nothing_changed_runs_the_smoke_lines(self):
        self.assertEqual(self.gate(), ["test_one"])

    def test_a_new_line_runs_first_whatever_its_tier(self):
        base = self.base - {"stub_b.py BetaUITests/test_five"}
        self.assertEqual(self.gate(base_keys=base), ["test_five", "test_one"])

    def test_a_change_of_tier_is_not_an_edit(self):
        lines = sel.parse_list(LIST.replace("test_two", "test_two --release"))
        self.assertEqual(names(lines, sel.select(lines, "gate", base_keys=self.base)), ["test_one"])

    def test_an_edited_option_is_an_edit(self):
        lines = sel.parse_list(LIST.replace("--media x.png", "--media y.png"))
        self.assertEqual(names(lines, sel.select(lines, "gate", base_keys=self.base)), ["test_four", "test_one"])

    def test_a_changed_test_runs_its_line_even_release(self):
        self.assertEqual(self.gate(classes={"AlphaUITests": {"test_three"}}), ["test_three", "test_one"])

    def test_a_changed_helper_runs_the_class_but_its_release_lines(self):
        self.assertEqual(self.gate(classes={"AlphaUITests": sel.WHOLE}), ["test_one", "test_two"])

    def test_comments_alone_run_nothing_more(self):
        self.assertEqual(self.gate(classes={"AlphaUITests": set()}), ["test_one"])

    def test_a_changed_stub_runs_its_lines_but_the_release_ones(self):
        self.assertEqual(self.gate(changed=["UITests/stubs/immich_stub_x.py", "UITests/stubs/stub_b.py"]), ["test_one"])
        lines = sel.parse_list(LIST.replace("stub_b.py", "immich_stub_b.py"))
        base = {sel.key(words) for words in lines}
        selected = sel.select(lines, "gate", changed=["UITests/stubs/immich_stub_b.py"], base_keys=base)
        self.assertEqual(names(lines, selected), ["test_four", "test_one"])

    def test_shared_code_runs_the_smoke_lines_only(self):
        said = []
        selected = sel.select(self.lines, "gate", changed=["Scripts/ci.sh", "UITests/stubs/immich_stub_base.py"],
                              base_keys=self.base, log=said.append)
        self.assertEqual(names(self.lines, selected), ["test_one"])
        self.assertIn("shared UI-test code changed", said[0])


class Capacity(unittest.TestCase):
    def setUp(self):
        self.lines = sel.parse_list(LIST)
        self.base = {sel.key(words) for words in self.lines}

    def test_room_for_everything(self):
        warned = []
        selected = sel.select(self.lines, "gate", base_keys=self.base, classes={"AlphaUITests": {"test_two"}},
                              capacity=2, warn=warned.append)
        self.assertEqual(names(self.lines, selected), ["test_two", "test_one"])
        self.assertEqual(warned, [])

    def test_changed_lines_come_before_the_smoke_lines(self):
        warned = []
        selected = sel.select(self.lines, "gate", base_keys=self.base, classes={"AlphaUITests": {"test_two"}},
                              capacity=1, warn=warned.append)
        self.assertEqual(names(self.lines, selected), ["test_two"])
        self.assertEqual(warned, [], "a smoke line left out is no warning")

    def test_a_changed_line_left_out_is_a_warning(self):
        warned = []
        selected = sel.select(self.lines, "gate", base_keys=self.base,
                              classes={"AlphaUITests": {"test_two", "test_three"}}, capacity=1, warn=warned.append)
        self.assertEqual(names(self.lines, selected), ["test_two"])
        self.assertEqual(len(warned), 1)
        self.assertIn("AlphaUITests/test_three", warned[0])
        self.assertIn("1 of the 2", warned[0])

    def test_at_least_one_line(self):
        selected = sel.select(self.lines, "gate", base_keys=self.base, capacity=0)
        self.assertEqual(names(self.lines, selected), ["test_one"])

    def test_the_suites_have_no_capacity(self):
        self.assertEqual(len(sel.select(self.lines, "all", capacity=1)), 5)


class ClassChanges(unittest.TestCase):
    def diff(self, *hunks):
        return "\n".join(["--- a/x", "+++ b/x"] + list(hunks))

    def test_spans(self):
        self.assertEqual(sel.test_spans(SOURCE), [("test_one", 8, 11), ("test_two", 13, 15), ("test_three", 17, 19)])

    def test_a_line_inside_a_test(self):
        diff = self.diff("@@ -10 +10 @@", "-        old()", "+        check()")
        self.assertEqual(sel.class_changes(diff, SOURCE), {"test_one"})

    def test_two_tests(self):
        diff = self.diff("@@ -10 +10 @@", "-        old()", "+        check()", "@@ -14 +14 @@", "-        x()", "+        helper()")
        self.assertEqual(sel.class_changes(diff, SOURCE), {"test_one", "test_two"})

    def test_a_helper_is_the_whole_class(self):
        diff = self.diff("@@ -4 +4 @@", "-        press()", "+        tap()")
        self.assertEqual(sel.class_changes(diff, SOURCE), sel.WHOLE)

    def test_comments_alone(self):
        diff = self.diff("@@ -7 +7 @@", "-    /// Uno.", "+    /// One.")
        self.assertEqual(sel.class_changes(diff, SOURCE), set())

    def test_a_new_test_with_its_comment_and_blank_line(self):
        diff = self.diff("@@ -11,0 +12,5 @@", "+", "+    func test_two() throws {", "+        helper()", "+    }", "+")
        self.assertEqual(sel.class_changes(diff, SOURCE), {"test_two"})

    def test_lines_removed_inside_a_test(self):
        diff = self.diff("@@ -10,2 +9,0 @@", "-        gone()", "-        gone()")
        self.assertEqual(sel.class_changes(diff, SOURCE), {"test_one"})

    def test_lines_removed_between_tests(self):
        diff = self.diff("@@ -12,3 +11,0 @@", "-    func test_gone() {", "-        x()", "-    }")
        self.assertEqual(sel.class_changes(diff, SOURCE), sel.WHOLE)

    def test_a_new_file_is_the_whole_class(self):
        body = ["+" + line for line in SOURCE.split("\n")]
        diff = self.diff("@@ -0,0 +1,%d @@" % len(body), *body)
        self.assertEqual(sel.class_changes(diff, SOURCE), sel.WHOLE)


if __name__ == "__main__":
    unittest.main()
