# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.TrendingLinks do
  @moduledoc """
  Provides aggregated trending links grouped by URL with engagement metrics.

  This module fetches activities containing links and groups them by URL,
  computing total boost counts and unique sharer counts for each link.
  Results are cached to avoid expensive DB queries on every render.
  """

  use Bonfire.Common.Utils
  alias Bonfire.Common.Cache
  alias Bonfire.Social.FeedLoader

  # Cache for 1 hour (matching Tags pattern)
  @default_cache_ttl 1_000 * 60 * 60
  @default_limit 5

  @doc """
  Returns trending links grouped by URL with aggregated boost counts.

  Results are cached for 1 hour to avoid expensive DB queries.

  Returns a list of maps with:
  - `media` - The first Media object for this URL (contains metadata for preview)
  - `path` - The URL
  - `total_boosts` - Sum of boost counts across all activities sharing this link
  - `unique_sharers` - Count of unique users who shared this link

  ## Options
  - `:limit` - Maximum number of links to return (default: 5)
  - Any other options passed to FeedLoader.feed/2

  ## Examples

      TrendingLinks.list_trending(limit: 10)
      #=> [%{media: %Bonfire.Files.Media{}, path: "https://...", total_boosts: 42, unique_sharers: 5}]
  """
  def list_trending(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Cache.maybe_apply_cached(
      &list_trending_without_cache/1,
      [limit],
      expire: @default_cache_ttl
    )
  end

  @doc """
  Resets the trending links cache for a given limit.
  """
  def list_trending_reset(limit \\ @default_limit) do
    Cache.reset(&list_trending_without_cache/1, [limit])
  end

  defp list_trending_without_cache(limit) do
    # Fetch more than we need to account for grouping (same URL shared by multiple posts)
    feed_opts = [
      limit: limit * 5,
      skip_boundary_check: true
    ]

    case FeedLoader.feed(:trending_links, feed_opts) do
      %{edges: edges} when is_list(edges) and edges != [] ->
        edges
        |> extract_and_group_by_url()
        |> sort_by_boosts()
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp extract_and_group_by_url(edges) do
    edges
    |> Enum.flat_map(&extract_link_media_with_activity/1)
    |> Enum.group_by(fn {media, _activity, _edge} -> media.path end)
    |> Enum.map(&aggregate_group/1)
    |> Enum.filter(& &1)
  end

  defp extract_link_media_with_activity(edge) do
    # Get media from edge.activity.media (preloaded by :with_media)
    media_list =
      e(edge, :activity, :media, [])
      |> List.wrap()
      |> Enum.filter(&is_link_media?/1)

    Enum.map(media_list, fn media ->
      {media, e(edge, :activity, nil), edge}
    end)
  end

  defp is_link_media?(%{media_type: media_type, path: path}) when is_binary(path) do
    String.starts_with?(path, "http") and
      media_type in ["link", "article", "profile", "website", "research"]
  end

  defp is_link_media?(_), do: false

  defp aggregate_group({url, items}) when is_binary(url) and items != [] do
    {first_media, _first_activity, _first_edge} = List.first(items)

    total_boosts =
      items
      |> Enum.map(fn {_media, _activity, edge} ->
        e(edge, :activity, :boost_count, :object_count, 0) || 0
      end)
      |> Enum.sum()

    unique_sharers =
      items
      |> Enum.map(fn {_media, activity, _edge} ->
        e(activity, :subject_id, nil)
      end)
      |> Enum.filter(& &1)
      |> Enum.uniq()
      |> length()

    %{
      media: first_media,
      path: url,
      total_boosts: total_boosts,
      unique_sharers: unique_sharers,
      share_count: length(items)
    }
  end

  defp aggregate_group(_), do: nil

  defp sort_by_boosts(links) do
    Enum.sort_by(links, & &1.total_boosts, :desc)
  end
end
