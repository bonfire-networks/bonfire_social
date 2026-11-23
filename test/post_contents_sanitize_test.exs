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

  # titles and content warnings are shown with `rich/1`, which outputs a string starting with `<` as HTML, so what is stored must never decode into a tag
  describe "entity-encoded markup in a title or content warning" do
    @encoded "&lt;script&gt;alert(1)&lt;/script&gt; Safe"

    for field <- [:name, :summary] do
      test "is removed when typed (#{field})" do
        assert %{unquote(field) => value} =
                 prepared(%{unquote(field) => @encoded, html_body: "hi"})

        refute value =~ ~r/script/i
        assert value =~ "alert(1)"
        assert value =~ "Safe"
      end

      test "is removed when it comes from a remote server (#{field})" do
        assert %{unquote(field) => value} =
                 PostContents.prepare_remote_content(
                   %{unquote(field) => @encoded, html_body: "hi"},
                   fake_user!(),
                   []
                 )

        refute value =~ ~r/script/i
        assert value =~ "alert(1)"
        assert value =~ "Safe"
      end

      test "typed markup is still removed (#{field}, control)" do
        assert %{unquote(field) => value} =
                 prepared(%{unquote(field) => "<script>alert(1)</script>Safe", html_body: "hi"})

        refute value =~ "<script"
        assert value =~ "Safe"
      end
    end

    for field <- [:name, :summary] do
      test "ends up the same typed or received (#{field})" do
        user = fake_user!()

        assert %{unquote(field) => typed} =
                 prepared(%{unquote(field) => @encoded, html_body: "hi"})

        assert %{unquote(field) => received} =
                 PostContents.prepare_remote_content(
                   %{unquote(field) => @encoded, html_body: "hi"},
                   user,
                   []
                 )

        assert typed == received
      end
    end

    test "a title keeps `&` and `<` shown as text" do
      assert %{name: "Tom & Jerry"} = shown(prepared(%{name: "Tom & Jerry", html_body: "hi"}))
      assert %{name: "a < b"} = shown(prepared(%{name: "a < b", html_body: "hi"}))
    end

    # what a reader sees: the stored string with its entities decoded
    defp shown(%{name: name} = attrs), do: %{attrs | name: HtmlEntities.decode(name)}
  end

  # the body is shown with `rich/1` too (post page, previews, labelled posts): a string starting with `<` is output as HTML as stored
  describe "markup in a body" do
    for {kind, body} <- [
          raw_script: "<script>alert(1)</script>Safe",
          raw_img: "<img src=x onerror=alert(1)>Safe",
          encoded_script: "&lt;script&gt;alert(1)&lt;/script&gt; Safe",
          encoded_img: "&lt;img src=x onerror=alert(1)&gt; Safe"
        ],
        format <- [:markdown, :html] do
      test "typed as #{format} (#{kind}) is not stored as a live tag" do
        assert %{html_body: value} =
                 PostContents.parse_and_prepare_contents(
                   %{html_body: unquote(body)},
                   fake_user!(),
                   output_format: unquote(format)
                 )

        refute value =~ ~r/script|onerror/i
        assert value =~ "Safe"
      end
    end

    for {kind, body} <- [
          raw_script: "<script>alert(1)</script>Safe",
          encoded_script: "&lt;script&gt;alert(1)&lt;/script&gt; Safe",
          encoded_img: "&lt;img src=x onerror=alert(1)&gt; Safe"
        ] do
      test "received (#{kind}) is not stored as a live tag" do
        assert %{html_body: value} =
                 PostContents.prepare_remote_content(
                   %{html_body: unquote(body)},
                   fake_user!(),
                   []
                 )

        refute value =~ ~r/script|onerror/i
        assert value =~ "Safe"
      end
    end
  end

  test "the body keeps quote markers on input" do
    assert %{html_body: body} = prepared(%{html_body: "> quoted\n"})

    assert body =~ ~r/^> quoted/
  end
end
