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
  @default_time_limit 7
  @media_metric_sorts [
    :popularity_score,
    :object_count,
    :boost_count,
    :like_count,
    :reply_count,
    :last_used
  ]

  # # 1 hour cache TTL in milliseconds (Cachex uses ms)
  # @default_cache_ttl :timer.hours(1)

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
  - `:time_limit` - Time window in days to consider activities (default: 7)
  - `:limit` - Maximum number of links to return (default: 5)
  - `:exclude_activity_types` - Activity types to exclude (default: [:reply, :boost])

  ## Examples

      trending_links(limit: 10)
      #=> [%{media: %Bonfire.Files.Media{}, path: "https://...", boost_count: 42, unique_sharers: 5}]
  """
  def trending_links(opts \\ []) do
    # read from the list the feed loader caches for the viewer's circle (the `trending_links` preset has `cache: true`), then what this viewer may not see is left out
    list_trending_paginated(opts)
    |> e(:edges, [])
    |> only_visible_to(current_user(opts))
  rescue
    e ->
      err(e, "Error fetching trending links")
      []
  end

  # the cached list is loaded for a circle, not a person: a signed in viewer's own limits (eg. an author they silenced, a post for some people only) apply when it is read
  defp only_visible_to(links, nil), do: links

  defp only_visible_to(links, viewer) do
    links
    |> preload_newest_activity()
    |> Enum.filter(fn link ->
      case e(link, :activity, :object_id, nil) do
        nil -> true
        object_id -> Bonfire.Boundaries.can?(viewer, [:see, :read], object_id)
      end
    end)
  end

  # # the args the cache key is derived from — strips cache-control opts so the key stays stable
  # # whether or not `:cache`/`:cache_ttl` are passed (so reset/refresh hit the same key as the load)
  # defp trending_links_args(opts), do: Keyword.drop(opts, [:cache_ttl, :cache])

  @doc """
  Warms the trending links cache by pre-computing results.

  Call this from an Oban cron job to ensure fresh cached data is available.
  Returns {:ok, count} with number of links cached, or {:error, reason}.
  """
  def warm_cache(opts \\ []) do
    # bust any stale cache + recompute in one go (standard `:cache` verb)
    links = trending_links(Keyword.put(opts, :cache, :refresh))
    {:ok, length(links)}
  rescue
    e ->
      err(e, "Error warming trending links cache")
      {:error, e}
  end

  # replaced by `trending_links/1`, which reads the list the feed loader caches for the viewer's circle (the old cache was only filled by `TrendingLinksCacheWorker`, which was not scheduled, so the widget showed nothing)
  # @doc """
  # Checks if trending links data is available in cache.
  # Returns the cached data if available, nil otherwise.
  # """
  # def cached_trending_links(opts \\ []) do
  #   # Use key_for_call to generate the same key format that maybe_apply_cached uses
  #   key =
  #     Cache.key_for_call(
  #       {Bonfire.Social.Media, :list_trending_paginated},
  #       [trending_links_args(opts)]
  #     )
  #
  #   Cache.get!(key)
  #   |> e(:edges, nil)
  # end

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
    {filters, opts} = Keyword.pop(opts, :filters, %{})

    opts =
      opts
      |> Keyword.put_new(
        :per_media_multiply_limit,
        System.get_env("TRENDING_LINKS_FETCH_LIMIT", "50") |> String.to_integer()
      )
      |> Keyword.put_new(:limit, @default_limit)

    Bonfire.Social.FeedLoader.feed(
      :trending_links,
      Map.merge(
        %{
          time_limit:
            opts[:time_limit] || Config.get([Bonfire.Social.TrendingLinks, :default_time_limit]) ||
              @default_time_limit
        },
        Map.new(filters)
      ),
      opts
    )
    |> debug("queried trending links")
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
      |> debug("initial subquery")
      |> projoin(:activity)
      |> select([activity: activity], %{
        id: max(activity.id),
        object_id: activity.object_id
      })
      |> group_by([activity: activity], activity.object_id)
      |> maybe_preload_and_select_boosts_metric(sort_by in [:boost_count, :popularity_score])
      |> maybe_preload_and_select_likes_metric(sort_by in [:like_count, :popularity_score])
      |> maybe_preload_and_select_replies_metric(sort_by in [:reply_count, :popularity_score])
      |> debug("qualifying_activities_query")

    # Start from Media table and join the qualifying activities, each with the media it reaches
    from(media in Bonfire.Files.Media,
      as: :main_object,
      inner_join: per_media_subquery in subquery(with_media_ids(qualifying_activities_query)),
      as: :per_media_subquery,
      on: per_media_subquery.media_id == media.id,
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
    # the activities are those of the candidate media, but one of them can carry other media too, which are not among the page's
    |> restrict_to_candidates(filters, opts)
    |> debug("media query before calculating metrics")
    # Conditionally add expensive metrics
    # |> reusable_join(
    #       :left,
    #       [per_media_subquery: per_media_subquery],
    #       activity in assoc(per_media_subquery, :activity),
    #       as: :activity
    #     )
    |> maybe_add_boosts_metric(sort_by in [:boost_count, :popularity_score])
    |> maybe_add_likes_metric(sort_by in [:like_count, :popularity_score])
    |> maybe_add_replies_metric(sort_by in [:reply_count, :popularity_score])
    |> maybe_add_trending_score(sort_by == :popularity_score, opts)
    |> order_media(sort_by, sort_order)
    # |> apply_media_filters(filters, opts)
    # boundarise
    |> debug("media aggregated query")
    |> repo().print_sql("media aggregated query SQL")
  end

  # Paginator's cursor is the Media's own id (binding 0), so a chronological media feed orders by it too: ordered by newest activity instead, Load more skipped or repeated items whenever media ids and newest-activity ids ordered differently
  defp order_media(query, sort_by, :asc) when sort_by in [nil, :date_created],
    do: order_by(query, [main_object: media], asc: media.id)

  defp order_media(query, sort_by, _sort_order) when sort_by in [nil, :date_created],
    do: order_by(query, [main_object: media], desc: media.id)

  # a metric sort orders by a value the aggregate computes, which Paginator can only bound on page 2 once it is a column: so the aggregated query becomes a subquery, ordered by that column then the Media id, matching `pagination_opts/2`
  defp order_media(query, sort_by, sort_order) when sort_by in @media_metric_sorts do
    {metric_order, id_order} =
      if sort_order == :asc, do: {:asc_nulls_first, :asc}, else: {:desc_nulls_last, :desc}

    metric = metric_field(sort_by)

    from(ranked in subquery(query), as: :ranked_media, select: ranked)
    |> order_by(
      ^[
        {metric_order, dynamic([ranked_media: ranked], field(ranked, ^metric))},
        {id_order, dynamic([ranked_media: ranked], ranked.id)}
      ]
    )
  end

  defp order_media(query, sort_by, sort_order),
    do: Bonfire.Social.Activities.query_order(query, sort_by, sort_order, :newest_activity_id)

  @doc "Paginator opts for a media feed, matching its order: the metric then the Media id for a metric sort, else the Media id. They replace the caller's cursor fields, which callers derive from `sort_by` for activity feeds."
  def pagination_opts(sort_by, sort_order) do
    order = sort_order || :desc

    if sort_by in @media_metric_sorts do
      [
        cursor_fields: [{metric_field(sort_by), order}, {:id, order}],
        # a sum over activities with no boosts, likes or replies is null
        cursor_fields_nullable:
          if(sort_by in [:boost_count, :like_count, :reply_count], do: [sort_by], else: []),
        fetch_cursor_value_fun: &media_cursor_value/2
      ]
    else
      [
        cursor_fields: [{:id, order}],
        cursor_fields_nullable: [],
        fetch_cursor_value_fun: &media_cursor_value/2
      ]
    end
  end

  defp media_cursor_value(media, field), do: Map.get(media, field)

  @default_per_media_multiply_limit 10

  @doc """
  How many candidate media a date-sorted media feed reads per row of the page: the activities of that many of the newest media (by id) are looked at, instead of every activity in the time window.

  A page that comes back short from them is retried with twice as many (see `Bonfire.Social.FeedLoader`), so this only trades how often that happens against how much one read costs. Ten pages' worth keeps a page of twenty media to the activities of two hundred, and is rarely short for a type most media have. Set with the `per_media_multiply_limit` option or the `[Bonfire.Social.Media, :per_media_multiply_limit]` config.
  """
  def per_media_multiply_limit(opts) do
    case opts[:per_media_multiply_limit] ||
           Config.get([__MODULE__, :per_media_multiply_limit], @default_per_media_multiply_limit) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_per_media_multiply_limit
    end
  end

  @doc """
  The newest media (by id, in the feed's order and after its cursor) that match the feed's media filters, limited to as many as one read looks at, as a query of their ids. `nil` for a metric sort, which orders by what the activities add up to, and when there are no media filters or `Bonfire.Files.FeedFilters` is not there to build them.

  The `limit:` and `offset:` query options replace how many it takes and skip the first ones, to see whether any more come after those one read looks at.
  """
  def candidate_media_ids_query(filters, opts, query_opts \\ []) do
    sort_by = filters[:sort_by] || opts[:sort_by]

    with true <- sort_by in [nil, :date_created],
         [_ | _] = conditions <- media_filter_conditions(filters) do
      pagination = repo().pagination_opts(opts)
      order = if (filters[:sort_order] || opts[:sort_order]) == :asc, do: :asc, else: :desc
      limit = Keyword.get(query_opts, :limit, candidate_limit(opts))

      # `before` reads the page the other way round, so the media nearest the cursor come first
      {scan_order, cursor_id} =
        cond do
          pagination[:after] -> {order, cursor_media_id(pagination[:after])}
          pagination[:before] -> {flip_order(order), cursor_media_id(pagination[:before])}
          true -> {order, nil}
        end

      condition = Enum.reduce(conditions, fn condition, acc -> dynamic(^acc and ^condition) end)

      from(media in Bonfire.Files.Media,
        as: :media,
        where: ^condition,
        select: media.id,
        limit: ^limit
      )
      |> then(fn query ->
        case Keyword.get(query_opts, :offset, 0) do
          0 -> query
          offset -> offset(query, ^offset)
        end
      end)
      |> order_by([media: media], [{^scan_order, media.id}])
      |> candidates_beyond_cursor(scan_order, cursor_id)
    else
      _ -> nil
    end
  end

  defp candidates_beyond_cursor(query, _scan_order, nil), do: query

  defp candidates_beyond_cursor(query, :desc, id),
    do: where(query, [media: media], media.id < ^id)

  defp candidates_beyond_cursor(query, :asc, id), do: where(query, [media: media], media.id > ^id)

  defp flip_order(:asc), do: :desc
  defp flip_order(:desc), do: :asc

  # a cursor over the Media id alone is that id, or else an encoded map holding it
  defp cursor_media_id(cursor) do
    case Paginator.Cursor.maybe_decode(cursor) do
      %{id: id} -> id
      _ -> nil
    end
  end

  # the media filters are `bonfire_files`' (`Bonfire.Files.FeedFilters`), an optional dependency here
  defp media_filter_conditions(filters) do
    Enum.flat_map([:media_types, :exclude_media_types], fn key ->
      with types when not is_nil(types) <- filters[key],
           condition when not is_nil(condition) <-
             maybe_apply(Bonfire.Files.FeedFilters, :media_condition, [{key, types}],
               fallback_return: nil
             ) do
        [condition]
      else
        _ -> []
      end
    end)
  end

  @doc "Whether more candidate media come after those one read looks at, so a short page may still have media beyond them."
  def more_candidate_media?(filters, opts) do
    case candidate_media_ids_query(filters, opts, limit: 1, offset: candidate_limit(opts)) do
      nil -> false
      query -> repo().one(query) != nil
    end
  end

  defp candidate_limit(opts),
    do: repo().pagination_opts(opts)[:limit] * per_media_multiply_limit(opts)

  defp restrict_to_candidates(query, filters, opts) do
    case candidate_media_ids_query(filters, opts) do
      nil -> query
      candidates -> where(query, [main_object: media], media.id in subquery(candidates))
    end
  end

  @doc "Limits a query with a `media` binding to the activities of the candidate media. Leaves it as it is when there are none (see `candidate_media_ids_query/3`)."
  def restrict_to_candidate_media(%Ecto.Query{} = query, filters, opts) do
    with true <- has_named_binding?(query, :media),
         %Ecto.Query{} = candidates <- candidate_media_ids_query(filters, opts) do
      where(query, [media: media], media.id in subquery(candidates))
    else
      _ -> query
    end
  end

  # the column a metric sort orders by: `:last_used` is the latest activity reaching the media (a ULID, so its time), which the aggregate already selects as `newest_activity_id`
  defp metric_field(:last_used), do: :newest_activity_id
  defp metric_field(sort_by), do: sort_by

  # An activity reaches media in two ways: its object has them attached (a `Bonfire.Files` row keyed by the object, pointing to the media), or its object is the media. One arm per way, each an equality join that an index serves, instead of one join with an OR across both tables, which no index can serve (Postgres then merge-joined every media row once per activity). The second arm keeps only media attached somewhere, as the OR join did, which required a `Bonfire.Files` row for every media.
  defp with_media_ids(qualifying_activities_query) do
    qualifying = subquery(qualifying_activities_query)

    via_attachment =
      from(per_activity in qualifying,
        inner_join: files in Bonfire.Files,
        on: files.id == per_activity.id,
        select: merge(per_activity, %{media_id: files.media_id})
      )

    from(per_activity in qualifying,
      inner_join: media in Bonfire.Files.Media,
      as: :media_itself,
      on: media.id == per_activity.id,
      where:
        exists(
          from(files in Bonfire.Files,
            where: files.media_id == parent_as(:media_itself).id,
            select: 1
          )
        ),
      select: merge(per_activity, %{media_id: media.id})
    )
    |> union_all(^via_attachment)
  end

  #   defp raise_debug_query(query) do
  #     query
  #     |> debug("query for debug")
  #     |> repo().all()
  #     |> debug("fetched data for debug")

  #     raise "Debugging query ^"
  # end

  # the media filters are `bonfire_files`' (`Bonfire.Files.FeedFilters`), an optional dependency here, so without it trending is simply unfiltered by media type
  defp apply_media_filters(query, filters, opts) do
    Enum.reduce([:media_types, :exclude_media_types], query, fn key, query ->
      case filters[key] do
        nil ->
          query

        types ->
          maybe_apply(Bonfire.Files.FeedFilters, :maybe_filter, [query, {key, types}, opts],
            fallback_return: query
          )
      end
    end)
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
    weights = Bonfire.Social.Activities.popularity_weights()
    weight_shares = weights[:shares]
    weight_likes = weights[:likes]
    weight_boosts = weights[:boosts]
    weight_replies = weights[:replies]

    # need yet another subquery to be able to select other calculated fields
    from(repo().make_subquery(query))
    |> select_merge([main], %{
      popularity_score:
        selected_as(
          main.object_count * ^weight_shares +
            coalesce(main.boost_count, 0) * ^weight_boosts +
            coalesce(main.like_count, 0) * ^weight_likes +
            coalesce(main.reply_count, 0) * ^weight_replies,
          :popularity_score
        ),
      object_count: selected_as(main.object_count, :object_count),
      newest_activity_id: selected_as(main.newest_activity_id, :newest_activity_id)
    })
  end

  # the media feed filters (`media_types`, `exclude_media_types`), the join that reaches an activity's media, and their helpers moved to `Bonfire.Files.FeedFilters`: media are `bonfire_files`', which `bonfire_social` holds only as an optional dependency, and the filters reach feeds through `Bonfire.Common.FeedFilterModule`

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
    end)
  end
end
