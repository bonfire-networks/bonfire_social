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

  # Cache for 1 hour 
  @default_cache_ttl 1_000 * 60 * 60
  @default_limit 5
  # days
  @default_time_limit 7

  @doc """
  Returns trending links grouped by URL with aggregated boost counts.

  Results are cached for 1 hour to avoid expensive DB queries.

  Returns a list of maps with:
  - `media` - The first Media object for this URL (contains metadata for preview)
  - `path` - The URL
  - `total_boosts` - Sum of boost counts across all activities sharing this link
  - `unique_sharers` - Count of unique users who shared this link

  ## Options
  - `:time_limit` - Time window in days to consider activities (default: 7)
  - `:limit` - Maximum number of links to return (default: 5)
  - `:unique_sharers_weight` - Weight multiplier for unique sharers in sorting (default: 0.25)
  - `:cache_ttl` - Cache expiration time (default: 1 hour)
  - Any other options passed to FeedLoader.feed/2

  ## Examples

      list_trending(limit: 10)
      #=> [%{media: %Bonfire.Files.Media{}, path: "https://...", total_boosts: 42, unique_sharers: 5}]
  """
  def list_trending(opts \\ []) do
    Cache.maybe_apply_cached(
      &list_trending_without_cache/1,
      [opts],
      expire: Keyword.get(opts, :cache_ms, @default_cache_ttl)
    )
  end

  @doc """
  Resets the trending links cache for a given limit.
  """
  def list_trending_reset(opts \\ []) do
    Cache.reset(&list_trending_without_cache/1, [opts])
  end

  defp list_trending_without_cache(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    opts =
      Keyword.merge(opts,
        # how many days
        time_limit: Keyword.get(opts, :time_limit, @default_time_limit),
        # Fetch more than we need to account for grouping (same URL shared by multiple posts), FIXME: do in DB?
        limit: 500,
        skip_boundary_check: true
      )

    case FeedLoader.feed(:trending_links, opts) do
      %{edges: edges} when is_list(edges) and edges != [] ->
        edges
        # TODO: this grouping could be done in the DB for better performance, or in FeedLoader so it also applies to the :trending_links preset feed
        |> extract_and_group_by_url()
        |> sort_trending(Keyword.get(opts, :unique_sharers_weight, 0.25))
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
    activity = e(edge, :activity, nil)

    media_list =
      e(activity, :media, [])
      |> List.wrap()
      |> Enum.filter(&is_link_media?/1)

    Enum.map(media_list, fn media ->
      {media, activity, edge}
    end)
  end

  defp is_link_media?(%{media_type: media_type, path: "http" <> _path})
       when media_type in ["link", "article", "profile", "website", "research"] do
    # NOTE: the feed preset already filters by: ["link", "article", "profile", "website"] but this ensures we exclude non-link attachments to a post with a link
    true
  end

  defp is_link_media?(_), do: false

  defp aggregate_group({url, items}) when is_binary(url) and items != [] do
    {first_media, _first_activity, _first_edge} = List.first(items)

    total_boosts =
      items
      |> Enum.map(fn {_media, _activity, edge} ->
        e(edge, :activity, :boost_count, :object_count, 0)
      end)
      |> Enum.sum()

    unique_sharers =
      items
      |> Enum.map(fn {_media, activity, _edge} ->
        e(activity, :subject_id, nil)
      end)
      |> Enum.reject(&is_nil/1)
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

  defp sort_trending(links, unique_sharers_weight) do
    # multiplier gives more weight to diversity of sharers
    Enum.sort_by(links, &(&1.total_boosts + &1.unique_sharers * unique_sharers_weight), :desc)
  end
end
