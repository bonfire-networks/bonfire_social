defmodule Bonfire.Social.FeedPaginationNoGapTest do
  @moduledoc """
  Regression test for https://github.com/bonfire-networks/bonfire-app/issues/2245 ("profile timeline misses activities between 2w and 2mo ago").

  `LoadMoreLive` sends `multiply_limit` with every "load more" click, which the live handler turns into `deferred_join_multiply_limit`. `FeedLoader` then took that as a signal to ALSO skip ahead by `2 * limit` rows (`deferred_join_offset`), a behaviour only meant for the "previous window came back empty" fallback. The inner subquery is already cursor-filtered, so the offset dropped rows the reader had not seen: with `limit: 5`, page 2 came back 10 posts too old, and the feed grew a hole after every page.
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  alias Bonfire.Social.FeedLoader

  @post_count 30
  @limit 5

  setup do
    user = fake_user!("no_gap_tester")

    # oldest first, so `posts` is in ascending creation order
    posts =
      for i <- 1..@post_count do
        fake_post!(user, "public", %{
          post_content: %{name: "no gap #{i}", html_body: "Content for post #{i}"}
        })
      end

    original_config = Config.get([Bonfire.Social.Feeds, :query_with_deferred_join])
    Config.put([Bonfire.Social.Feeds, :query_with_deferred_join], true)

    on_exit(fn ->
      Config.put([Bonfire.Social.Feeds, :query_with_deferred_join], original_config)
    end)

    # newest first, matching feed order
    expected_ids = posts |> Enum.map(&id/1) |> Enum.reverse()

    %{user: user, posts: posts, expected_ids: expected_ids}
  end

  defp feed_object_ids(feed),
    do: Enum.map(e(feed, :edges, []), &e(&1, :activity, :object_id, nil))

  describe "deferred join pagination" do
    test "a load_more carrying multiply_limit does not skip any activities", %{
      user: user,
      expected_ids: expected_ids
    } do
      opts = [current_user: user, limit: @limit, preload: false, show_objects_only_once: false]

      page1 = FeedLoader.feed(:custom, %{}, opts)
      assert feed_object_ids(page1) == Enum.take(expected_ids, @limit)

      cursor = e(page1, :page_info, :end_cursor, nil)
      assert is_binary(cursor)

      # exactly what the UI sends on the first "load more": the cursor plus the doubled multiply_limit from `feed_live.sface`
      page2 =
        FeedLoader.feed(
          :custom,
          %{},
          opts ++ [after: cursor, deferred_join_multiply_limit: 4]
        )

      assert feed_object_ids(page2) == expected_ids |> Enum.drop(@limit) |> Enum.take(@limit)
    end

    test "multiply_limit without a cursor still starts at the newest activity", %{
      user: user,
      expected_ids: expected_ids
    } do
      page1 =
        FeedLoader.feed(:custom, %{},
          current_user: user,
          limit: @limit,
          preload: false,
          show_objects_only_once: false,
          deferred_join_multiply_limit: 4
        )

      assert feed_object_ids(page1) == Enum.take(expected_ids, @limit)
    end

    test "paginating all the way through returns every activity exactly once", %{
      user: user,
      expected_ids: expected_ids
    } do
      opts = [current_user: user, limit: @limit, preload: false, show_objects_only_once: false]

      # multiply_limit doubles on each click in `feed_live.sface` (nil -> 4 -> 8 -> ...)
      {collected, _} =
        Enum.reduce_while(1..10, {[], {nil, nil}}, fn _i, {acc, {cursor, multiply_limit}} ->
          page_opts =
            if cursor do
              opts ++ [after: cursor, deferred_join_multiply_limit: multiply_limit]
            else
              opts
            end

          case feed_object_ids(FeedLoader.feed(:custom, %{}, page_opts)) do
            [] ->
              {:halt, {acc, {nil, nil}}}

            ids ->
              {:cont, {acc ++ ids, {List.last(ids), (multiply_limit || 2) * 2}}}
          end
        end)

      assert collected == expected_ids
    end
  end
end
