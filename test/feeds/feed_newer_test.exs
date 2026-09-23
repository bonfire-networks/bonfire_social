defmodule Bonfire.Social.FeedNewerTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.{FeedFilters, FeedLoader}

  import Bonfire.Posts.Fake

  setup do
    Process.put([:bonfire, :default_pagination_limit], 20)

    author = fake_user!("feed newer author")

    Enum.each(1..8, fn index ->
      fake_post!(author, "public", %{
        post_content: %{
          name: "Feed newer post #{index}",
          html_body: "Feed newer post #{index}"
        }
      })
    end)

    {:ok, author: author}
  end

  test "returns adjacent newer pages without gaps or duplicates", %{author: author} do
    filters = %FeedFilters{
      subjects: [author.id],
      activity_types: [:create],
      time_limit: 0
    }

    base_page =
      FeedLoader.feed(:custom, filters,
        current_user: author,
        paginate: [limit: 20]
      )

    base_cursors = Enum.map(base_page.edges, &entry_cursor/1)
    marker_index = 6
    marker_cursor = Enum.at(base_cursors, marker_index)

    first_newer_page =
      FeedLoader.feed_newer(:custom, filters, marker_cursor,
        current_user: author,
        paginate: [limit: 2]
      )

    assert Enum.map(first_newer_page.edges, &entry_cursor/1) ==
             Enum.slice(base_cursors, marker_index - 2, 2)

    next_cursor = unwrap_cursor(first_newer_page.page_info.start_cursor)

    second_newer_page =
      FeedLoader.feed_newer(:custom, filters, next_cursor,
        current_user: author,
        paginate: [limit: 2]
      )

    assert Enum.map(second_newer_page.edges, &entry_cursor/1) ==
             Enum.slice(base_cursors, marker_index - 4, 2)

    final_cursor = unwrap_cursor(second_newer_page.page_info.start_cursor)

    final_newer_page =
      FeedLoader.feed_newer(:custom, filters, final_cursor,
        current_user: author,
        paginate: [limit: 2]
      )

    assert Enum.map(final_newer_page.edges, &entry_cursor/1) ==
             Enum.slice(base_cursors, 0, 2)

    assert is_nil(final_newer_page.page_info.start_cursor)

    all_newer_cursors =
      [first_newer_page, second_newer_page, final_newer_page]
      |> Enum.flat_map(&Enum.map(&1.edges, fn entry -> entry_cursor(entry) end))

    assert length(all_newer_cursors) == MapSet.size(MapSet.new(all_newer_cursors))
  end

  test "chronological sort dedups in place instead of deduping the whole feed in a subquery", %{
    author: author
  } do
    # `feed_newer` sorts by :date_created; that must not take the "sort by another field" dedup path
    for sort_order <- [:asc, :desc] do
      filters = %FeedFilters{
        subjects: [author.id],
        activity_types: [:create],
        time_limit: 0,
        sort_by: :date_created,
        sort_order: sort_order
      }

      query_string =
        FeedLoader.feed(:custom, filters,
          current_user: author,
          query_with_deferred_join: true,
          return: :query
        )
        |> Inspect.Ecto.Query.to_string()

      # an unbounded DISTINCT ON subquery can't receive the cursor/limit, so it would scan the whole feed
      refute query_string =~ "distinct_activity_id_subquery"
    end
  end

  defp entry_cursor(entry) do
    id(entry) || e(entry, :activity, :id, nil) || e(entry, :object, :id, nil) ||
      e(entry, :edge, :id, nil)
  end

  defp unwrap_cursor(cursor) when is_list(cursor), do: List.first(cursor)
  defp unwrap_cursor(cursor), do: cursor
end
