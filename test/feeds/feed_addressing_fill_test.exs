defmodule Bonfire.Social.FeedAddressingFillTest do
  @moduledoc """
  Old custom-boundary posts (published the legacy way, with no global feed row) must still appear in the addressed `:local` feed. We publish with addressing OFF (so the post gets NO bucket row, like legacy custom posts), switch the query to `:addressed` and watch the author NOT see their own post (RED), then run the fill and watch it appear (GREEN) via a synthesised `local_custom` row.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Feeds.Addressing.Fill, as: Fill
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  @local_custom "3SERSFR0MY0VR10CA11NSTANCE"

  defp run_fill, do: Fill.base_query() |> repo().all() |> Fill.migrate()

  defp feeds_of(post),
    do: FeedActivities.feeds_for_activity(e(post, :activity, :id, nil) || raise("no activity"))

  test "fills a local_custom row for an old custom post so it shows in addressed :local" do
    author = Fake.fake_user!()

    # published with addressing OFF → a legacy custom post: no global/bucket feed row at all
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "old custom post"}},
        boundary: "mentions"
      )

    refute @local_custom in feeds_of(post),
           "precondition: legacy custom post has no local bucket row"

    # switch the read path to addressed; RED — the author can't find their own post in :local yet
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_origin_strategy], :addressed)

    refute FeedLoader.feed_contains?(:local, post, current_user: author),
           "RED: without a bucket row the addressed :local query misses the old custom post"

    run_fill()

    assert @local_custom in feeds_of(post), "fill added a local_custom row"

    assert FeedLoader.feed_contains?(:local, post, current_user: author),
           "GREEN: the old custom post now shows in addressed :local via local_custom"
  end
end
