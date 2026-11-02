defmodule Bonfire.Social.PostContentsSanitizeTest do
  @moduledoc """
  The Markdown body is sanitized when rendered, so it is stored as written; titles and content warnings are federated and shown as they are stored, so they are still sanitized on input.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.PostContents

  @moduletag :backend

  defp prepared(attrs) do
    PostContents.parse_and_prepare_contents(attrs, fake_user!(), output_format: :markdown)
  end

  test "a title is sanitized on input" do
    assert %{name: name} = prepared(%{name: "<b onmouseover=alert(1)>title</b>", html_body: "hi"})

    refute name =~ "onmouseover"
    assert name =~ "title"
  end

  test "a content warning is sanitized on input" do
    assert %{summary: summary} =
             prepared(%{summary: "<img src=x onerror=alert(1)>careful", html_body: "hi"})

    refute summary =~ "onerror"
    assert summary =~ "careful"
  end

  test "the body keeps quote markers on input" do
    assert %{html_body: body} = prepared(%{html_body: "> quoted\n"})

    assert body =~ ~r/^> quoted/
  end
end
