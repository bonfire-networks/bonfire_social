defmodule Bonfire.Social.PostContentsHardbreaksTest do
  @moduledoc """
  Milkdown serializes `hardBreak` nodes as `\\`+newline, so visually-blank lines (Shift+Enter) arrive as backslash-only lines. CommonMark treats those as line breaks rather than blank lines, so without normalization the whole post renders as ONE paragraph and remote instances show a wall of `<br>`s (bonfire-app#2216).
  `normalise_input/3` must collapse them back into blank lines.

  NOTE: the CRLF variants matter because LiveView serializes forms via `new FormData(form)`, and HTML entry-list construction normalizes every newline to CRLF. So CRLF is what actually arrives in production, while the LF spellings are what a direct API caller sends. See `Bonfire.Common.Text` doctests for the unit-level coverage of the same rules.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.PostContents

  @moduletag :backend

  defp prepared_body(html_body, me) do
    assert %{html_body: body} =
             PostContents.parse_and_prepare_contents(
               %{html_body: html_body},
               me,
               output_format: :markdown
             )

    body
  end

  test "backslash-only lines become blank lines (paragraph breaks)" do
    me = fake_user!()

    body = prepared_body("first paragraph\n\\\n\\\nsecond paragraph", me)

    refute body =~ "\\"
    assert body =~ "first paragraph\n\n"
    assert body =~ "second paragraph"
  end

  test "backslash-only lines become blank lines when submitted with CRLF newlines" do
    me = fake_user!()

    body = prepared_body("first paragraph\r\n\\\r\n\\\r\nsecond paragraph", me)

    refute body =~ "\\"
    assert body =~ "first paragraph"
    assert body =~ "second paragraph"
  end

  test "hard break directly before a blank line does not leave a literal backslash" do
    me = fake_user!()

    body = prepared_body("one\\\n\\\ntwo", me)

    refute body =~ "\\"
    assert body =~ "one\n\n"
    assert body =~ "two"
  end

  test "hard break directly before a blank line does not leave a literal backslash with CRLF" do
    me = fake_user!()

    body = prepared_body("one\\\r\n\\\r\ntwo", me)

    refute body =~ "\\"
    assert body =~ "one"
    assert body =~ "two"
  end

  test "a hard break at the very end of the post does not leave a literal backslash" do
    me = fake_user!()

    refute prepared_body("foo\\", me) =~ "\\"
    refute prepared_body("foo\\\n", me) =~ "\\"
  end

  test "a backslash line padded with non-breaking spaces still becomes a blank line" do
    me = fake_user!()

    body = prepared_body("first\n  \\  \nsecond", me)

    refute body =~ "\\"
    assert body =~ "first"
    assert body =~ "second"
  end

  test "a single hard break between two lines of text is preserved" do
    me = fake_user!()

    body = prepared_body("roses\\\nviolets", me)

    assert body =~ "roses\\\nviolets"
  end

  @tag :todo
  test "a backslash line inside an indented code block is left alone" do
    me = fake_user!()

    # KNOWN GAP: the normalisation is not code-block aware, so it deletes the `\` line and the resulting unindented blank line splits one indented code block into two. Same limitation exists client-side in `serializeMarkdownForSubmit`.
    body = prepared_body("    code\n    \\\n    more", me)

    assert body =~ "    code\n    \\\n    more"
  end
end
