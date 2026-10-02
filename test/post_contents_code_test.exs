defmodule Bonfire.Social.PostContentsCodeTest do
  @moduledoc """
  Code in a Markdown post (fenced blocks, inline spans and indented blocks) must be stored exactly as written and rendered with one level of HTML escaping, so `IO.puts("Hello world")` never shows as `IO.puts(&quot;Hello world&quot;)` (bonfire-app#2370).
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.PostContents
  alias Bonfire.Common.Text

  @moduletag :backend

  @code ~s|IO.puts("Hello world") && 'a' < b > c &amp;|

  defp prepared_body(html_body, me) do
    assert %{html_body: body} =
             PostContents.parse_and_prepare_contents(
               %{html_body: html_body},
               me,
               output_format: :markdown
             )

    body
  end

  for {kind, markdown} <- [
        fenced: "```elixir\n#{@code}\n```",
        fenced_without_language: "```\n#{@code}\n```",
        inline: "some `#{@code}` code",
        indented: "text\n\n    #{@code}"
      ] do
    test "#{kind} code is stored verbatim" do
      assert prepared_body(unquote(markdown), fake_user!()) =~ @code
    end

    test "#{kind} code is rendered with a single level of escaping" do
      html =
        unquote(markdown)
        |> prepared_body(fake_user!())
        |> Text.maybe_markdown_to_html()

      # decoding the visible text once must give back exactly what was typed
      assert html |> String.replace(~r/<[^>]*>/, "") |> decode_once() =~ @code
    end
  end

  test "code is stored verbatim when the format comes from the user's editor, as the composer submits it" do
    assert %{html_body: body} =
             PostContents.parse_and_prepare_contents(
               %{html_body: "```\n#{@code}\n```"},
               fake_user!(),
               []
             )

    assert body =~ @code
  end

  test "mentions, hashtags and emoticons in code are left as typed, while the same outside code is still processed" do
    me = fake_user!()
    other = fake_user!()
    mention = "@#{other.character.username}"
    code = "#{mention} #tag :) a\\_b"

    body = prepared_body("#{mention} `#{code}`", me)

    assert body =~ "`#{code}`"
    refute body =~ ~r/^#{Regex.escape(mention)} /
  end

  defp decode_once(text) do
    Regex.replace(~r/&(quot|#39|#x27|lt|gt|amp);/, text, fn
      _, "quot" -> ~s(")
      _, "lt" -> "<"
      _, "gt" -> ">"
      _, "amp" -> "&"
      _, _ -> "'"
    end)
  end
end
