defmodule Bonfire.Social.PostContentsHardbreaksTest do
  @moduledoc """
  Milkdown serializes `hardBreak` nodes as `\\`+newline, so visually-blank lines
  (Shift+Enter) arrive as backslash-only lines. CommonMark treats those as line
  breaks rather than blank lines, so without normalization the whole post renders
  as ONE paragraph and remote instances show a wall of `<br>`s (bonfire-app#2216).
  `normalise_input/3` must collapse them back into blank lines.
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

  test "hard break directly before a blank line does not leave a literal backslash" do
    me = fake_user!()

    body = prepared_body("one\\\n\\\ntwo", me)

    refute body =~ "\\"
    assert body =~ "one\n\n"
    assert body =~ "two"
  end

  test "a single hard break between two lines of text is preserved" do
    me = fake_user!()

    body = prepared_body("roses\\\nviolets", me)

    assert body =~ "roses\\\nviolets"
  end
end
