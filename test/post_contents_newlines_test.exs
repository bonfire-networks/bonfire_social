defmodule Bonfire.Social.PostContentsNewlinesTest do
  @moduledoc """
  What the composer sends for each kind of line break, and the HTML the post renders from it. Each Markdown body below is exactly what the Milkdown composer produced for the case (composer-newlines frame, 2026-11-02).
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.PostContents
  alias Bonfire.Common.Text

  @moduletag :backend

  defp stored(html_body) do
    assert %{html_body: body} =
             PostContents.parse_and_prepare_contents(%{html_body: html_body}, fake_user!(),
               output_format: :markdown
             )

    body
  end

  defp rendered(html_body) do
    html_body
    |> stored()
    |> Text.maybe_markdown_to_html()
    |> String.replace(~r/\s+/, " ")
  end

  test "Enter makes two paragraphs" do
    assert rendered("a\n\nb\n") =~ ~r{<p>a</p> ?<p>b</p>}
  end

  test "Shift+Enter makes a line break inside one paragraph" do
    assert rendered("a\\\nb\n") =~ ~r{<p>a<br ?/?> ?b</p>}
  end

  test "an empty line between paragraphs is kept as a break" do
    assert rendered("a\n\n<br />\n\nb\n") =~ ~r{<p>a</p> ?<br ?/?> ?<p>b</p>}
  end

  test "a pasted single newline renders as a line break" do
    assert rendered("a\nb\n") =~ ~r{<p>a<br ?/?> ?b</p>}
  end

  test "a line break inside a list item stays in that item" do
    html = rendered("* one\\\n  cont\n* two\n\n")

    assert html =~ ~r{<li>one<br ?/?> ?cont</li>}
    assert html =~ "<li>two</li>"
  end

  test "a blank line inside a code block is kept" do
    # the highlighter renders each source line as a span, so the blank one is an empty line span
    assert rendered("```js\nx = 1\n\ny = 2\n```\n\n") =~ ~s(data-line="2"></span>)
  end

  test "the stored body keeps blockquote markers" do
    assert stored("> a\\\n> b\n") =~ ~r/^> a/
  end

  test "a blockquote with a line break and two paragraphs renders as a quote" do
    html = rendered("> a\\\n> b\n>\n> c\n\n")

    assert html =~ "<blockquote>"
    refute html =~ "&gt;"
    assert html =~ ~r{<p>a<br ?/?> ?b</p> ?<p>c</p>}
  end
end
