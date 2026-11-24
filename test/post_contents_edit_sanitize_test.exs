defmodule Bonfire.Social.PostContentsEditSanitizeTest do
  @moduledoc """
  An edit stores a post's title, content warning and body as safely as publishing does, whoever sends it: the edit form, the Mastodon API, an import's update (eg. Ghost's), or a remote server's `Update`. Titles and remote bodies are rendered as stored, so markup that would run must never be stored.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Posts
  alias Bonfire.Social.PostContents

  @moduletag :backend

  @payloads [
    {"a script", "<script>alert(1)</script>Safe"},
    {"an event handler", "<img src=x onerror=alert(1)>Safe"},
    {"entity-encoded markup", "&lt;script&gt;alert(1)&lt;/script&gt; Safe"}
  ]

  setup do
    me = fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{name: "A title", html_body: "A body"}},
        boundary: "public"
      )

    {:ok, me: me, post: post}
  end

  defp stored(post), do: Bonfire.Common.Repo.get!(Bonfire.Data.Social.PostContent, id(post))

  # a remote `Update` carries the whole object, so the fields not under test keep their values
  defp ap_note(field, value) do
    Map.put(
      %{"type" => "Note", "name" => "A title", "content" => "A body"},
      %{name: "name", summary: "summary", html_body: "content"}[field],
      value
    )
  end

  defp refute_live_markup(value) do
    refute value =~ ~r/<script/i
    refute value =~ ~r/onerror/i
    assert value =~ "Safe"
  end

  for field <- [:name, :summary, :html_body], {label, payload} <- @payloads do
    test "#{label} in an edited #{field} isn't stored as markup", %{me: me, post: post} do
      assert {:ok, _} = PostContents.edit(me, id(post), %{unquote(field) => unquote(payload)})

      refute_live_markup(Map.get(stored(post), unquote(field)))
    end

    test "#{label} in a #{field} edited by a remote server's Update isn't stored as markup", %{
      me: me,
      post: post
    } do
      assert {:ok, _, _} =
               PostContents.ap_receive_update(
                 me,
                 %{"type" => "Update"},
                 ap_note(unquote(field), unquote(payload)),
                 id(post)
               )

      refute_live_markup(Map.get(stored(post), unquote(field)))
    end
  end

  # the controls: the same edits keep harmless markup, so the tests above show the edit happened
  for field <- [:name, :summary, :html_body] do
    test "harmless markup in an edited #{field} is kept (control)", %{me: me, post: post} do
      assert {:ok, _} = PostContents.edit(me, id(post), %{unquote(field) => "<b>ok</b> Safe"})

      assert Map.get(stored(post), unquote(field)) =~ "<b>ok</b>"
    end

    test "harmless markup in a #{field} edited by a remote server's Update is kept (control)", %{
      me: me,
      post: post
    } do
      assert {:ok, _, _} =
               PostContents.ap_receive_update(
                 me,
                 %{"type" => "Update"},
                 ap_note(unquote(field), "<b>ok</b> Safe"),
                 id(post)
               )

      assert Map.get(stored(post), unquote(field)) =~ "<b>ok</b>"
    end
  end

  # an edit starts from the stored body, which is already HTML: sanitising it again must not change what it shows
  test "code showing markup survives an edit as written", %{me: me, post: post} do
    body = "<pre><code>&lt;div class=\"x\"&gt;hi&lt;/div&gt;</code></pre>"

    assert {:ok, _} = PostContents.edit(me, id(post), %{html_body: body})

    assert stored(post).html_body =~ "&lt;div class="
  end

  test "an ampersand in an edited title isn't escaped twice", %{me: me, post: post} do
    assert {:ok, _} = PostContents.edit(me, id(post), %{name: "Tom &amp; Jerry"})

    refute stored(post).name =~ "&amp;amp;"
    assert stored(post).name =~ "Tom &"
  end

  test "a mention link in the body survives an edit unchanged", %{me: me} do
    other = fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: "hello @#{other.character.username} there"}},
        boundary: "public"
      )

    before = stored(post).html_body
    assert before =~ other.character.username

    assert {:ok, _} = PostContents.edit(me, id(post), %{html_body: before <> " edited"})

    assert stored(post).html_body == before <> " edited"
  end
end
