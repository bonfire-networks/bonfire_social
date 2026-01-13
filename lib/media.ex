# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.Media do
  @moduledoc """
  Provides aggregated trending links grouped by URL with engagement metrics.

  Uses MediaFeedLoader to query with Media as the primary object, which solves
  filter issues that occur when media joins break time_limit/activity_type filters.
  """

  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Social.MediaFeedLoader
  alias Bonfire.Files.Media

  @default_limit 5
  # days - reduced from 7 to 2 for better query performance
  @default_time_limit 2
  # 1 hour cache TTL in milliseconds (Cachex uses ms)
  @default_cache_ttl :timer.hours(1)

  @doc """
  Returns trending links grouped by URL with aggregated metrics.

  Returns a list of maps with:
  - `media` - The first Media object for this URL (contains metadata for preview)
  - `path` - The URL
  - `boost_count` - Sum of boost counts across all activities sharing this link
  - `object_count` - Total number of times the link was shared
  # - `sharers` - List of user structs who shared this link (for avatars)
  # - `share_activity_ids` - List of activity IDs that shared this link
  # - `unique_sharers` - Count of unique users who shared this link

  ## Options
  - `:time_limit` - Time window in days to consider activities (default: 2)
  - `:limit` - Maximum number of links to return (default: 5)
  - `:exclude_activity_types` - Activity types to exclude (default: [:reply, :boost])

  ## Examples

      trending_links(limit: 10)
      #=> [%{media: %Bonfire.Files.Media{}, path: "https://...", boost_count: 42, unique_sharers: 5}]
  """
  def trending_links(opts \\ []) do
    Cache.maybe_apply_cached(
      &list_trending_paginated/1,
      [Keyword.drop(opts, [:cache_ttl])],
      expire:
        Keyword.get(opts, :cache_ttl) ||
          Config.get([Bonfire.Social.Media, :default_cache_ttl]) || @default_cache_ttl
    )
    # list_trending_paginated(opts)
    |> e(:edges, [])
  rescue
    e ->
      err(e, "Error fetching trending links")
      []
  end

  def trending_links_reset(opts \\ []) do
    Cache.reset(&list_trending_paginated/1, [opts])
  end

  @doc """
  Warms the trending links cache by pre-computing results.

  Call this from an Oban cron job to ensure fresh cached data is available.
  Returns {:ok, count} with number of links cached, or {:error, reason}.
  """
  def warm_cache(opts \\ []) do
    # Reset any stale cache first
    trending_links_reset(opts)

    # Now fetch and cache fresh data
    links = trending_links(opts)
    {:ok, length(links)}
  rescue
    e ->
      err(e, "Error warming trending links cache")
      {:error, e}
  end

  @doc """
  Checks if trending links data is available in cache.
  Returns the cached data if available, nil otherwise.
  """
  def cached_trending_links(opts \\ []) do
    # Use key_for_call to generate the same key format that maybe_apply_cached uses
    key =
      Cache.key_for_call(
        {Bonfire.Social.Media, :list_trending_paginated},
        [Keyword.drop(opts, [:cache_ttl])]
      )

    Cache.get!(key)
    |> e(:edges, nil)
  end

  @doc """
  Returns trending links in paginated format compatible with FeedLive.

  Delegates to FeedLoader which uses the deferred join infrastructure with media aggregation.

  Returns `%{edges: [...], page_info: %{}}` structure.
  Each edge wraps a trending link with `:trending_link` type marker for rendering.

  ## Options
  - `:limit` - Number of items per page (default: 20)
  - `:time_limit` - Days to look back (default: 7)
  - `:sort_by` - Sort order (:date_created for chronological, default is popularity)
  - `:paginate` - Standard Bonfire pagination options (after, before, limit)
  """
  def list_trending_paginated(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(
        :per_media_multiply_limit,
        System.get_env("TRENDING_LINKS_FETCH_LIMIT", "50") |> String.to_integer()
      )
      |> Keyword.put_new(:limit, @default_limit)

    Bonfire.Social.FeedLoader.feed(
      :trending_links,
      %{
        time_limit:
          opts[:time_limit] || Config.get([Bonfire.Social.TrendingLinks, :default_time_limit]) ||
            @default_time_limit
      },
      opts
    )
    |> flood("queried trending links")
  rescue
    e ->
      err(e, "Error fetching trending links")
      %{edges: [], page_info: %{}}
  end

  @doc """
  Wraps a qualifying activities query with media aggregation.

  Takes the prepared/filtered/paginated activities subquery and aggregates by media URL.
  Returns proper Media structs with virtual fields populated.
  Only calculates expensive engagement metrics when needed for sorting.
  """
  def build_media_aggregated_query(qualifying_activities_query, filters, opts) do
    alias Bonfire.Files.Media

    sort_by = filters[:sort_by] || opts[:sort_by]
    sort_order = filters[:sort_order] || opts[:sort_order]

    # qualifying_activities_query
    # |> proload(activity: [:object])
    # |> raise_debug_query()

    qualifying_activities_query =
      qualifying_activities_query
      |> repo().make_subquery()
      |> flood("initial subquery")
      |> projoin(:activity)
      |> select([activity: activity], %{
        id: max(activity.id),
        object_id: activity.object_id
      })
      |> group_by([activity: activity], activity.object_id)
      |> maybe_preload_and_select_boosts_metric(sort_by in [:boost_count, :trending_score])
      |> maybe_preload_and_select_likes_metric(sort_by in [:like_count, :trending_score])
      |> maybe_preload_and_select_replies_metric(sort_by in [:reply_count, :trending_score])
      |> flood("qualifying_activities_query")

    # Start from Media table and join the qualifying activities
    from(media in Bonfire.Files.Media,
      as: :main_object,
      # Join qualifying activities via Files (attachment mixin)
      inner_join: files in Bonfire.Files,
      as: :files,
      on: files.media_id == media.id,
      # Join to the filtered/paginated activities subquery
      inner_join: per_media_subquery in subquery(qualifying_activities_query),
      as: :per_media_subquery,
      on: per_media_subquery.id == files.id or per_media_subquery.id == media.id,
      # Group by media path (URL) and id
      group_by: [media.path, media.id],
      # Select into Media struct with virtual fields
      select: %{
        media
        | # Virtual fields - always include these for display/postload
          object_count:
            selected_as(count(per_media_subquery.object_id, :distinct), :object_count),
          newest_activity_id: selected_as(max(per_media_subquery.id), :newest_activity_id)

          #  Do we need these? should at least have a limit on the array size:
          # activity_ids: fragment("array_agg(DISTINCT ?)", activity.id), 
          # sharer_ids: fragment("array_agg(DISTINCT ?)", a.subject_id)
      }
    )
    # |> Activities.activity_preloads(
    #     opts[:preload],
    #     opts
    #   )
    |> flood("media query before calculating metrics")
    # Conditionally add expensive metrics
    # |> reusable_join(
    #       :left,
    #       [per_media_subquery: per_media_subquery],
    #       activity in assoc(per_media_subquery, :activity),
    #       as: :activity
    #     )
    |> maybe_add_boosts_metric(sort_by in [:boost_count, :trending_score])
    |> maybe_add_likes_metric(sort_by in [:like_count, :trending_score])
    |> maybe_add_replies_metric(sort_by in [:reply_count, :trending_score])
    |> maybe_add_trending_score(sort_by == :trending_score, opts)
    # sort
    |> Bonfire.Social.Activities.query_order(sort_by, sort_order, :newest_activity_id)
    # |> apply_media_filters(filters, opts)
    # boundarise
    |> flood("media aggregated query")
    |> repo().print_sql("media aggregated query SQL")
  end

  #   defp raise_debug_query(query) do
  #     query
  #     |> flood("query for debug")
  #     |> repo().all()
  #     |> flood("fetched data for debug")

  #     raise "Debugging query ^"
  # end

  defp apply_media_filters(query, filters, opts) do
    query =
      case filters[:media_types] do
        nil -> query
        types -> maybe_filter(query, {:media_types, types}, opts)
      end

    case filters[:exclude_media_types] do
      nil -> query
      types -> maybe_filter(query, {:exclude_media_types, types}, opts)
    end
  end

  defp maybe_preload_and_select_boosts_metric(query, false), do: query

  defp maybe_preload_and_select_boosts_metric(query, true) do
    query
    |> projoin(activity: [:boost_count])
    |> select_merge([boost_count: bc], %{
      boost_count: max(bc.object_count)
    })
  end

  defp maybe_preload_and_select_likes_metric(query, false), do: query

  defp maybe_preload_and_select_likes_metric(query, true) do
    query
    |> projoin(activity: [:like_count])
    |> select_merge([like_count: lc], %{
      like_count: max(lc.object_count)
    })
  end

  defp maybe_preload_and_select_replies_metric(query, false), do: query

  defp maybe_preload_and_select_replies_metric(query, true) do
    query
    |> projoin(activity: [:replied])
    |> select_merge([replied: replied], %{
      reply_count: max(replied.total_replies_count)
    })
  end

  defp maybe_add_boosts_metric(query, false), do: query

  defp maybe_add_boosts_metric(query, true) do
    query
    |> select_merge([per_media_subquery: per_media_subquery], %{
      boost_count:
        selected_as(
          sum(per_media_subquery.boost_count),
          # fragment("SUM(DISTINCT ?)", per_media_subquery.boost_count),
          # sum(per_media_subquery.boost_count) / selected_as(:object_count), 
          # sum(per_media_subquery.boost_count) / count(per_media_subquery.object_id, :distinct), 
          :boost_count
        )
    })
  end

  defp maybe_add_likes_metric(query, false), do: query

  defp maybe_add_likes_metric(query, true) do
    query
    |> select_merge([per_media_subquery: per_media_subquery], %{
      like_count: selected_as(sum(per_media_subquery.like_count), :like_count)
    })
  end

  defp maybe_add_replies_metric(query, false), do: query

  defp maybe_add_replies_metric(query, true) do
    query
    |> select_merge([per_media_subquery: per_media_subquery], %{
      reply_count: selected_as(sum(per_media_subquery.reply_count), :reply_count)
    })
  end

  defp maybe_add_trending_score(query, false, _opts), do: query

  defp maybe_add_trending_score(query, true, opts) do
    # Get configurable weights for trending score
    # TODO: use Settings if we want user-configurable algorithms?
    weight_shares = Config.get([:feeds, :trending_weight_shares], 4)
    weight_replies = Config.get([:feeds, :trending_weight_replies], 3)
    weight_boosts = Config.get([:feeds, :trending_weight_boosts], 2)
    weight_likes = Config.get([:feeds, :trending_weight_likes], 1)

    # need yet another subquery to be able to select other calculated fields
    from(repo().make_subquery(query))
    |> select_merge([main], %{
      trending_score:
        selected_as(
          main.object_count * ^weight_shares +
            coalesce(main.boost_count, 0) * ^weight_boosts +
            coalesce(main.like_count, 0) * ^weight_likes +
            coalesce(main.reply_count, 0) * ^weight_replies,
          :trending_score
        ),
      object_count: selected_as(main.object_count, :object_count),
      newest_activity_id: selected_as(main.newest_activity_id, :newest_activity_id)
    })
  end

  defp filter_has_media(query) do
    query
    |> maybe_proload_media(:has_one)
    |> where([media: media], not is_nil(media.media_type))
  end

  def maybe_filter(query, {:media_types, types}, opts) when is_list(types) and types != [] do
    per_media? = :per_media in List.wrap(opts[:preload])

    case prepare_filter_media_type(types) do
      :all ->
        filter_has_media(query)

      [first | rest] ->
        # Build the OR conditions as a dynamic query
        media_type_filter =
          rest
          |> Enum.reduce(
            dynamic([media: media], ilike(media.media_type, ^"#{first}%")),
            fn type, dynamic_query ->
              dynamic([media: media], ^dynamic_query or ilike(media.media_type, ^"#{type}%"))
            end
          )

        # Apply as a single WHERE clause
        query
        |> maybe_proload_media(per_media? || :left)
        |> where(^media_type_filter)

      other ->
        warn(other, "Unrecognised media type")
        query
    end
  end

  def maybe_filter(query, {:exclude_media_types, types}, opts)
      when is_list(types) and types != [] do
    per_media? = :per_media in List.wrap(opts[:preload])

    case prepare_filter_media_type(types) do
      :all ->
        query
        |> maybe_proload_media(per_media? || :has_one)
        |> where([media: media], is_nil(media.media_type))

      [first | rest] ->
        # Build combined exclusion filter
        media_type_filter =
          rest
          |> Enum.reduce(
            dynamic(
              [media: media],
              is_nil(media.id) or not ilike(media.media_type, ^"#{first}%")
            ),
            fn type, dynamic_query ->
              dynamic([media: media], ^dynamic_query and not ilike(media.media_type, ^"#{type}%"))
            end
          )

        query
        |> maybe_proload_media(per_media? || :left)
        |> where(^media_type_filter)

      other ->
        warn(other, "Unrecognised media type")
        query
    end
  end

  def maybe_filter(query, filters, _opts) do
    warn(filters, "no supported Media-related filters defined")
    query
  end

  def maybe_proload_media(query, per_media_or_join) do
    if per_media_or_join == true do
      query
      |> projoin(:inner, activity: [:media])
    else
      if per_media_or_join == :has_one do
        query
        |> projoin(:inner, activity: [:media])
      else
        #  :left 
        if per_media_or_join == :inner do
          query
          |> Bonfire.Social.Activities.join_media(:inner)
          |> proload(:inner, activity: [:media])
        else
          query
          |> Bonfire.Social.Activities.join_media(:left)
          |> proload(:left, activity: [:media])
        end
      end
    end || query
  end

  defp prepare_filter_media_type(types) do
    cond do
      "*" in types or :* in types ->
        :all

      :link in types or "link" in types ->
        ["link", "article", "profile", "website"] ++ types

      true ->
        types
    end
  end

  def preload_newest_activity(%{edges: edges} = result) do
    %{result | edges: preload_newest_activity(edges)}
  end

  def preload_newest_activity(edges) when is_list(edges) do
    repo().maybe_preload(edges, [:newest_activity])
    |> Enum.map(fn 
      %{newest_activity: newest_activity} = edge ->
        %{edge | activity: newest_activity, newest_activity: nil}
      edge ->
        warn("No :newest_activity assoc to preload")
        edge
      end
    )
  end
end
