defmodule Bonfire.Social.PostContentsURLsTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Common.Text
  alias Bonfire.Social.PostContents

  @moduletag :backend
  doctest Text, only: [normalise_markdown_urls: 1], import: true

  test "editor-escaped YouTube URLs are extracted for preview fetching" do
    me = fake_user!()
    input = ~S(https://www.youtube.com/watch?v=17MBllYf6OY&list=RD17MBllYf6OY\&start\_radio=1 test)

    prepared = PostContents.parse_and_prepare_contents(%{html_body: input}, me, output_format: :markdown)

    assert prepared.urls == ["https://www.youtube.com/watch?v=17MBllYf6OY&list=RD17MBllYf6OY&start_radio=1"]
  end

  test "different video IDs remain distinct after normalization" do
    me = fake_user!()
    urls = for video <- ["17MBllYf6OY", "x8SJteSVLnk"], do: "https://www.youtube.com/watch?v=#{video}&start_radio=1"
    input = urls |> Enum.map(&String.replace(&1, "&start_", "\\&start\\_")) |> Enum.join("\n")

    prepared = PostContents.parse_and_prepare_contents(%{html_body: input}, me, output_format: :markdown)

    assert Enum.sort(prepared.urls) == Enum.sort(urls)
  end

  test "code and ordinary Markdown escapes are preserved" do
    url = ~S(https://example.com/a\_b?x=1\&y=2)

    for input <- ["`#{url}`", "```text\n#{url}\n```", "~~~\n#{url}\n~~~", "    #{url}", ~S(keep \_literal\_)] do
      assert Text.normalise_markdown_urls(input) == input
    end

    assert Text.normalise_markdown_urls("`#{url}` #{url}") == "`#{url}` https://example.com/a_b?x=1&y=2"
  end
end
