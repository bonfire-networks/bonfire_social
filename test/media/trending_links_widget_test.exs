defmodule Bonfire.Social.TrendingLinksWidgetTest do
  @moduledoc """
  The trending links widget reads the same per-circle list as the other cached feeds (`cache: true` on the `trending_links` preset): one list shared by everyone signed in, built when asked for, and it follows the instance's setting for what widgets show (`[Bonfire.Social.Feeds, :widget_origin]`).
  """
  use Bonfire.Social.DataCase, async: false
  use Bonfire.Common.Utils

  alias Bonfire.Social.Boosts
  alias Bonfire.Social.Media
  alias Bonfire.Me.Fake

  @moduletag :backend

  setup do
    # creating a remote actor fetches it
    Tesla.Mock.mock(fn %{method: :get, url: url} ->
      Tesla.Mock.json(Bonfire.Federate.ActivityPub.Simulate.actor_json(url))
    end)

    me = Fake.fake_user!("trending links viewer")
    other = Fake.fake_user!("trending links other viewer")
    booster = Fake.fake_user!("trending links booster")
    remote = Bonfire.Social.Fake.fake_remote_user!()

    %{me: me, other: other, booster: booster, remote: remote}
  end

  # a link as a fetched preview is stored, attached to a post by `author`, and boosted so it trends
  # a post from another instance is "public_remote" (what federation gives it): a "public" one is addressed to the local buckets
  defp trending_link!(author, booster, name, boundary \\ "public") do
    url = "https://example.org/#{name}/#{Faker.UUID.v4()}"

    {:ok, media} =
      Bonfire.Files.Media.insert(author, url, %{media_type: "link", size: 0}, %{
        url: url,
        metadata: %{"content_type" => "text/html", "facebook" => %{"title" => name}}
      })

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: name}, uploaded_media: [media]},
        boundary: boundary
      )

    {:ok, _} = Boosts.boost(booster, post)
    id(media)
  end

  defp listed(opts), do: Media.trending_links(opts) |> Enum.map(&id/1)

  test "everyone signed in reads one list, until it is refreshed", ctx do
    first = trending_link!(ctx.me, ctx.booster, "first")

    assert first in listed(current_user: ctx.me, cache: :refresh)

    second = trending_link!(ctx.me, ctx.booster, "second")

    cached = listed(current_user: ctx.other)
    assert first in cached
    refute second in cached, "expected the list cached for the circle, not a new one per viewer"

    assert second in listed(current_user: ctx.other, cache: :refresh)
  end

  test "a viewer's own limits apply to the shared list: a silenced author's link is left out",
       ctx do
    author = Fake.fake_user!("trending links author")
    link = trending_link!(author, ctx.booster, "silenced link")

    # the list is loaded for the circle, so both viewers' reads come from it
    assert link in listed(current_user: ctx.me, cache: :refresh)

    Bonfire.Boundaries.Blocks.block(author, :silence, current_user: ctx.other)

    assert link in listed(current_user: ctx.me)
    refute link in listed(current_user: ctx.other), "expected the silenced author's link left out"
  end

  test "the widget origin setting leaves out links from other instances", ctx do
    local = trending_link!(ctx.me, ctx.booster, "local link")
    far = trending_link!(ctx.remote, ctx.booster, "remote link", "public_remote")

    # the positive first, with no filters at all: both are there
    ids = listed(current_user: ctx.me, cache: :refresh)
    assert local in ids, "no filters: expected the local link in #{inspect(ids)}"
    assert far in ids, "no filters: expected the remote link in #{inspect(ids)}"

    filters = Bonfire.Social.Feeds.widget_origin_filters()
    ids = listed(current_user: ctx.me, filters: filters, cache: :refresh)

    assert local in ids,
           "origin everywhere (filters #{inspect(filters)}): expected the local link in #{inspect(ids)}"

    assert far in ids

    Process.put([:bonfire_social, Bonfire.Social.Feeds, :widget_origin], :local)

    ids =
      listed(
        current_user: ctx.me,
        filters: Bonfire.Social.Feeds.widget_origin_filters(),
        cache: :refresh
      )

    assert local in ids
    refute far in ids, "expected no link from another instance when widgets show only local"
  end

  test "the origin filter on its own keeps a local link, cached or not", ctx do
    local = trending_link!(ctx.me, ctx.booster, "local link")

    for cache <- [false, :refresh] do
      ids = listed(current_user: ctx.me, filters: %{origin: :local}, cache: cache)
      assert local in ids, "cache: #{inspect(cache)}, expected the local link in #{inspect(ids)}"
    end
  end
end
