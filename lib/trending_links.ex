# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.TrendingLinks do
  @moduledoc """
  Provides aggregated trending links grouped by URL with engagement metrics.

  Uses MediaFeedLoader to query with Media as the primary object, which solves
  filter issues that occur when media joins break time_limit/activity_type filters.
  """

  use Bonfire.Common.Utils
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Social.MediaFeedLoader
  alias Bonfire.Files.Media

  @default_limit 5
  # days
  @default_time_limit 7
  @default_exclude_activity_types [:reply, :boost]

  @doc """
  Returns trending links grouped by URL with aggregated metrics.

  Returns a list of maps with:
  - `media` - The first Media object for this URL (contains metadata for preview)
  - `path` - The URL
  - `total_boosts` - Sum of boost counts across all activities sharing this link
  - `sharers` - List of user structs who shared this link (for avatars)
  - `share_activity_ids` - List of activity IDs that shared this link
  - `unique_sharers` - Count of unique users who shared this link
  - `share_count` - Total number of times the link was shared

  ## Options
  - `:time_limit` - Time window in days to consider activities (default: 7)
  - `:limit` - Maximum number of links to return (default: 5)
  - `:exclude_activity_types` - Activity types to exclude (default: [:reply, :boost])

  ## Examples

      list_trending(limit: 10)
      #=> [%{media: %Bonfire.Files.Media{}, path: "https://...", total_boosts: 42, unique_sharers: 5}]
  """
  def list_trending(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    # Use module attribute as default, allow opts to override
    opts =
      Keyword.merge(
        [
          time_limit: @default_time_limit,
          exclude_activity_types: @default_exclude_activity_types
        ],
        opts
      )

    # Use media-first query with DB-side grouping
    query = MediaFeedLoader.trending_links_query(opts)

    raw_results =
      query
      |> limit(^limit)
      |> offset(^offset)
      |> repo().all()

    hydrate_results(raw_results)
  rescue
    e ->
      error(e, "Error fetching trending links")
      []
  end

  @doc """
  Returns trending links in paginated format compatible with FeedLive.

  Uses Bonfire's standard keyset pagination via `repo().many_paginated()`.

  Returns `%{edges: [...], page_info: %{}}` structure.
  Each edge wraps a trending link with `:trending_link` type marker for rendering.

  ## Options
  - `:limit` - Number of items per page (default: 20)
  - `:time_limit` - Days to look back (default: 7)
  - `:sort_by` - Sort order (:date_created for chronological, default is popularity)
  - `:paginate` - Standard Bonfire pagination options (after, before, limit)
  """
  def list_trending_paginated(opts \\ []) do
    opts = to_options(opts)

    sort_by = opts[:sort_by] || e(opts, :feed_filters, :sort_by, nil)
    sort_order = opts[:sort_order] || :desc
    time_limit = get_time_limit(opts)

    # Build the query with subquery wrapper for keyset pagination
    query =
      MediaFeedLoader.trending_links_query(
        time_limit: time_limit,
        sort_by: sort_by,
        exclude_activity_types: @default_exclude_activity_types
      )

    # Merge pagination options with cursor field configuration
    paginate_opts =
      Keyword.merge(
        opts[:paginate] || opts,
        order_pagination_opts(sort_by, sort_order)
      )

    case repo().many_paginated(query, paginate_opts) do
      %{edges: edges, page_info: page_info} ->
        # Check if this is the first page (no cursor)
        is_first_page = is_nil(paginate_opts[:after]) and is_nil(e(opts, :paginate, :after, nil))

        # Hydrate with full Media/User objects and add type markers
        hydrated_edges =
          edges
          |> hydrate_results()
          |> Enum.with_index()
          |> Enum.map(fn {link, index} ->
            link
            |> Map.put(:__type__, :trending_link)
            |> Map.put(:featured, index == 0 and is_first_page)
          end)

        %{edges: hydrated_edges, page_info: page_info}

      error ->
        error(error, "Error paginating trending links")
        %{edges: [], page_info: %{}}
    end
  end

  # Pagination helpers following Activities pattern from deps/bonfire_social/lib/activities.ex
  defp order_pagination_opts(sort_by, sort_order) do
    [
      cursor_fields: order_cursor_fields(sort_by, sort_order || :desc),
      fetch_cursor_value_fun: &fetch_cursor_value_fun/2
    ]
  end

  defp order_cursor_fields(:date_created, sort_order),
    do: [{:newest_activity_id, sort_order}, {:path, sort_order}]

  defp order_cursor_fields(_, sort_order),
    do: [{:share_count, sort_order}, {:path, sort_order}]

  defp fetch_cursor_value_fun(row, :share_count), do: row[:share_count] || 0
  defp fetch_cursor_value_fun(row, :newest_activity_id), do: row[:newest_activity_id]
  defp fetch_cursor_value_fun(row, :path), do: row[:path]
  defp fetch_cursor_value_fun(row, field), do: Map.get(row, field)

  defp get_time_limit(opts) do
    case opts[:time_limit] || e(opts, :feed_filters, :time_limit, nil) do
      nil -> @default_time_limit
      val -> val
    end
  end

  # Load full Media and User objects for the aggregated results
  defp hydrate_results(grouped_rows) when is_list(grouped_rows) and grouped_rows != [] do
    # Pre-convert binary IDs to ULIDs once per row (avoid redundant conversions)
    rows_with_ulids =
      Enum.map(grouped_rows, fn row ->
        %{
          row
          | sharer_ids: convert_binary_ids(row.sharer_ids),
            activity_ids: convert_binary_ids(row.activity_ids)
        }
      end)

    # Load Media objects
    media_ids = rows_with_ulids |> Enum.map(& &1.first_media_id) |> Enum.reject(&is_nil/1)
    media_map = load_media_by_ids(media_ids)

    # Load sharer Users
    all_sharer_ids = rows_with_ulids |> Enum.flat_map(& &1.sharer_ids) |> Enum.uniq()
    sharers_map = load_users_by_ids(all_sharer_ids)

    # Load boost counts for activities
    all_activity_ids = rows_with_ulids |> Enum.flat_map(& &1.activity_ids) |> Enum.uniq()
    boost_counts_map = load_boost_counts_by_activity_ids(all_activity_ids)

    # Build final result structures
    Enum.map(rows_with_ulids, fn row ->
      sharers =
        row.sharer_ids
        |> Enum.map(&Map.get(sharers_map, &1))
        |> Enum.reject(&is_nil/1)

      total_boosts =
        row.activity_ids
        |> Enum.map(&Map.get(boost_counts_map, &1, 0))
        |> Enum.sum()

      media = Map.get(media_map, row.first_media_id)

      %{
        media: media,
        path: row.path,
        # Extract title/description directly to avoid losing them during stream updates
        title: media && Bonfire.Files.Media.media_label(media),
        description: media && Bonfire.Files.Media.description(media),
        total_boosts: total_boosts,
        sharers: sharers,
        share_activity_ids: row.activity_ids,
        unique_sharers: length(sharers),
        share_count: row.share_count || 0
      }
    end)
    |> Enum.reject(fn link -> is_nil(link.media) end)
  end

  defp hydrate_results(_), do: []

  defp load_media_by_ids([]), do: %{}

  defp load_media_by_ids(ids) do
    from(m in Media, where: m.id in ^ids)
    |> repo().all()
    |> Map.new(fn m -> {m.id, m} end)
  end

  defp load_users_by_ids([]), do: %{}

  defp load_users_by_ids(ids) do
    # Use Bonfire.Me.Users or Needle.Pointers to load users with profile
    Bonfire.Common.Needles.list!(ids, skip_boundary_check: true)
    |> repo().maybe_preload([:profile, :character])
    |> Map.new(fn u -> {id(u), u} end)
  end

  defp load_boost_counts_by_activity_ids([]), do: %{}

  defp load_boost_counts_by_activity_ids(ids) do
    # Boost counts are stored in EdgeTotal with the Boost table_id
    # The `object_count` represents how many times the activity was boosted
    boost_table_id = Bonfire.Data.Social.Boost.__pointers__(:table_id)

    try do
      from(et in Bonfire.Data.Edges.EdgeTotal,
        where: et.id in ^ids,
        where: et.table_id == ^boost_table_id,
        select: {et.id, et.object_count}
      )
      |> repo().all()
      |> Map.new()
    rescue
      e ->
        warn(e, "Failed to load boost counts")
        %{}
    end
  end

  # Convert a list of binary IDs to ULID strings, filtering nils
  defp convert_binary_ids(ids) when is_list(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&binary_to_ulid/1)
    |> Enum.reject(&is_nil/1)
  end

  defp convert_binary_ids(_), do: []

  # Convert binary UUID/ULID from PostgreSQL to ULID string
  defp binary_to_ulid(binary) when is_binary(binary) and byte_size(binary) == 16 do
    case Needle.UID.load(binary) do
      {:ok, ulid} -> ulid
      _ -> nil
    end
  end

  defp binary_to_ulid(string) when is_binary(string), do: string
  defp binary_to_ulid(_), do: nil
end
