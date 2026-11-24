defmodule Bonfire.Social.Feeds.TrendingPresetCacheTest do
  # the `trending` preset is served from a cached list of its ranked, preloaded entries, one list for guests and one for everyone signed in, paged by position in that list
  use Bonfire.Social.DataCase, async: false
  use Bonfire.Common.Utils

  import Bonfire.Posts.Fake

  alias Bonfire.Social.Boosts
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Me.Fake

  @moduletag :backend

  setup do
    author = Fake.fake_user!("trending author")
    boosters = for n <- 1..8, do: Fake.fake_user!("trending booster #{n}")

    [low, mid, high] =
      for {name, count} <- [{"low", 1}, {"mid", 2}, {"high", 3}] do
        post = fake_post!(author, "public", %{post_content: %{name: name, html_body: name}})
        for booster <- Enum.take(boosters, count), do: {:ok, _} = Boosts.boost(booster, post)
        post
      end

    %{author: author, boosters: boosters, low: low, mid: mid, high: high}
  end

  defp page(opts) do
    %{edges: edges, page_info: page_info} = FeedLoader.feed(:trending, %{}, opts)
    {Enum.map(edges, &e(&1, :activity, :object_id, nil)), page_info}
  end

  defp end_cursor(page_info), do: e(page_info, :end_cursor, nil)

  test "pages through the cached list in popularity order, then has no more", %{
    low: low,
    mid: mid,
    high: high
  } do
    {page1, info1} = page(paginate: [limit: 1], cache: :refresh)
    assert page1 == [high.id]
    assert is_binary(end_cursor(info1))

    {page2, info2} = page(paginate: [limit: 1, after: end_cursor(info1)])
    assert page2 == [mid.id]

    {page3, info3} = page(paginate: [limit: 1, after: end_cursor(info2)])
    assert page3 == [low.id]

    assert is_nil(end_cursor(info3)),
           "expected no more pages, got cursor #{inspect(end_cursor(info3))}"
  end

  test "serves later requests, by anyone signed in, from the cached list until it is refreshed",
       %{
         low: low,
         high: high,
         boosters: boosters
       } do
    viewer = Fake.fake_user!("trending viewer")
    other_viewer = Fake.fake_user!("trending other viewer")

    {page1, _} = page(current_user: viewer, paginate: [limit: 1], cache: :refresh)
    assert page1 == [high.id]

    # the least boosted post becomes the most boosted
    for booster <- Enum.drop(boosters, 3), do: {:ok, _} = Boosts.boost(booster, low)

    {cached, _} = page(current_user: other_viewer, paginate: [limit: 1])
    assert cached == [high.id], "expected the cached ranking for another signed-in user"

    {refreshed, _} = page(current_user: other_viewer, paginate: [limit: 1], cache: :refresh)
    assert refreshed == [low.id]
  end

  test "guests and signed-in users get separate lists, each loaded with its own boundaries", %{
    author: author,
    boosters: boosters
  } do
    local_only =
      fake_post!(author, "local", %{post_content: %{name: "local only", html_body: "local only"}})

    for booster <- boosters, do: {:ok, _} = Boosts.boost(booster, local_only)

    viewer = Fake.fake_user!("trending local viewer")

    {signed_in, _} = page(current_user: viewer, paginate: [limit: 1], cache: :refresh)
    assert signed_in == [local_only.id], "expected the local-only post first for a signed-in user"

    {guest, _} = page(paginate: [limit: 10], cache: :refresh)
    refute local_only.id in guest
    assert guest != [], "expected the public posts for guests"
  end

  test "caches at least one page, whatever the configured number of pages", %{high: high} do
    Process.put([:bonfire_social, Bonfire.Social.FeedLoader, :cached_preset_pages], 0)

    {page1, info1} = page(paginate: [limit: 1], cache: :refresh)
    assert page1 == [high.id]
    assert is_nil(end_cursor(info1)), "expected one cached page, so no more"
  end
end
