# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MediaFeedLoader do
  @moduledoc """
  Queries feeds with Media as the primary object, joining activities.

  This module solves filter issues that occur when media joins break
  time_limit/activity_type filters in the standard FeedPublish-based queries.

  By using Media as the primary object, we can:
  - Group by URL (media.path) efficiently in PostgreSQL
  - Apply activity filters (time_limit, exclude_activity_types) correctly
  - Compute aggregations in the database for better performance
  """

  import Ecto.Query
  use Bonfire.Common.Utils

  alias Bonfire.Data.Social.Activity
  alias Bonfire.Files.Media

  @link_media_types [
    "link",
    "article",
    "profile",
    "website",
    "research",
    "rich",
    "object",
    "remote"
  ]

  # Base query starting from Media, joining to Activity.
  # Media can be linked to Activity via Files mixin or directly.
  defp base_query do
    from(media in Media,
      as: :media,
      # Join Files table (a mixin where id = object.id, media_id = media.id)
      # Files.id is the object (Post) ID, not the Activity ID
      # Using INNER JOIN (not LEFT) ensures we only get Media with Files attachments
      join: files in Bonfire.Files,
      as: :files,
      on: files.media_id == media.id,
      # Join Activity:
      # - via Files (activity.object_id = files.id) for media attached to posts
      # - or directly (activity.id = media.id) when Media IS the activity's object
      join: activity in Activity,
      as: :activity,
      on: activity.object_id == files.id or activity.id == media.id,
      where: like(media.path, "http%")
    )
  end

  @doc """
  Query for trending links grouped by URL with aggregated metrics.

  Returns rows with:
  - path: The URL
  - share_count: Number of times the link was shared
  - first_media_id: ID of the first Media record for this URL
  - newest_activity_id: Most recent activity ID (for chronological cursor)
  - activity_ids: Array of activity IDs that shared this link
  - sharer_ids: Array of unique user IDs who shared this link

  The query is wrapped in a subquery to enable keyset pagination on aggregated fields.

  ## Options
  - `:time_limit` - Days to look back (default: 7)
  - `:exclude_activity_types` - Activity types to exclude (default: [:reply, :boost])
  - `:sort_by` - Sort order (:date_created for chronological, default is popularity)
  """
  def trending_links_query(opts \\ []) do
    # Inner query with GROUP BY - computes aggregations
    inner_query =
      base_query()
      |> filter_link_media_types()
      |> maybe_apply_time_limit(opts)
      |> maybe_exclude_activity_types(opts)
      |> group_by_url()
      |> select_aggregated_fields()

    # Wrap in subquery so aggregated fields become regular columns
    # This enables Paginator to add WHERE clauses for keyset pagination
    from(t in subquery(inner_query),
      as: :trending,
      order_by: ^build_order_by(opts)
    )
  end

  defp filter_link_media_types(query) do
    where(query, [media: m], m.media_type in ^@link_media_types)
  end

  defp maybe_apply_time_limit(query, opts) do
    time_limit = Keyword.get(opts, :time_limit, 7)

    if is_integer(time_limit) and time_limit > 0 do
      # Add 12h of leeway (same as Objects.query_maybe_time_limit)
      with limit_pointer when is_binary(limit_pointer) <-
             Bonfire.Common.DatesTimes.past(time_limit * 24 + 12, :hour)
             |> Bonfire.Common.DatesTimes.generate_ulid() do
        where(query, [activity: a], a.id > ^limit_pointer)
      else
        _ -> query
      end
    else
      query
    end
  end

  defp maybe_exclude_activity_types(query, opts) do
    excluded = Keyword.get(opts, :exclude_activity_types, [:reply, :boost])

    if is_list(excluded) and excluded != [] do
      verb_ids =
        excluded
        |> Enum.map(&Bonfire.Social.Activities.verb_id/1)
        |> Enum.reject(&is_nil/1)

      if verb_ids != [] do
        where(query, [activity: a], a.verb_id not in ^verb_ids)
      else
        query
      end
    else
      query
    end
  end

  defp group_by_url(query) do
    group_by(query, [media: m], m.path)
  end

  defp select_aggregated_fields(query) do
    select(query, [media: m, activity: a], %{
      path: m.path,
      share_count: count(a.id),
      first_media_id: min(m.id),
      newest_activity_id: max(a.id),
      activity_ids: fragment("array_agg(DISTINCT ?)", a.id),
      sharer_ids: fragment("array_agg(DISTINCT ?)", a.subject_id)
    })
  end

  defp build_order_by(opts) do
    case Keyword.get(opts, :sort_by) do
      :date_created ->
        # Chronological: order by most recent activity, then path for tiebreaker
        [desc: dynamic([trending: t], t.newest_activity_id), desc: dynamic([trending: t], t.path)]

      _ ->
        # Default: order by popularity (share count), then path for tiebreaker
        [desc: dynamic([trending: t], t.share_count), desc: dynamic([trending: t], t.path)]
    end
  end
end
