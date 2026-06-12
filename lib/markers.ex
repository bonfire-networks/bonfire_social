defmodule Bonfire.Social.Markers do
  @moduledoc """
  Reading positions (markers) per account and feed, shared between the web UI
  and the Mastodon-compatible markers API (`/api/v1/markers`).

  Markers are last-write-wins (a position, not a high-water mark) and
  `version`/`updated_at` are real row values, as Mastodon clients expect.
  Accounts that have never saved a marker fall back to deriving one from their
  Seen edges (e.g. populated by `mark_all_seen` in the web UI).
  """

  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  import Ecto.Query

  alias Bonfire.Common.DatesTimes
  alias Bonfire.Data.Social.Activity
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.Marker
  alias Bonfire.Social.{Seen, Feeds, FeedActivities}

  @valid_timelines ["home", "notifications"]
  # Mastodon timeline names → Bonfire feed names (unlisted ones map to themselves)
  @timeline_to_feed_name %{"home" => "my"}
  # Re-confirming the same position must still count as activity for the
  # staleness window (and for clients comparing `updated_at`), but without a
  # write per save: only touch the timestamp when it's over an hour old.
  @touch_unchanged_after_seconds 3600

  def valid_timelines, do: @valid_timelines

  @doc "Canonical Mastodon timeline → Bonfire feed name mapping (e.g. `home` ↔ `my`)."
  def timeline_feed_name(timeline),
    do: Map.get(@timeline_to_feed_name, timeline, normalise_feed_name(timeline))

  @doc """
  Get the server-side reading position cursor for a Bonfire feed.

  Pass `max_age_days: n` to ignore positions that haven't moved in `n` days
  (used by feed resume so a long-stale marker doesn't hijack the feed; the
  marker itself is kept, e.g. for Mastodon clients).
  """
  def get_reading_position(user, feed_name, opts \\ [])

  def get_reading_position(user, feed_name, opts) when not is_nil(user) do
    case get_marker(marker_subject_id(user), normalise_feed_name(feed_name)) do
      %Marker{last_read_id: cursor} = marker ->
        if fresh_enough?(marker, opts[:max_age_days]), do: to_string(cursor)

      _ ->
        nil
    end
  end

  def get_reading_position(_user, _feed_name, _opts), do: nil

  # A non-number max age (nil/false) means no limit; 0 disables resuming.
  defp fresh_enough?(%Marker{updated_at: %DateTime{} = updated_at}, max_age_days)
       when is_number(max_age_days) do
    DateTime.after?(updated_at, DatesTimes.past(max_age_days, :day))
  end

  defp fresh_enough?(_marker, _max_age_days), do: true

  @doc "Save the server-side reading position cursor for a Bonfire feed."
  def save_reading_position(user, feed_name, cursor)
      when not is_nil(user) and is_binary(cursor) and cursor != "" do
    with {:ok, marker, _changed?} <-
           validated_save(user, normalise_feed_name(feed_name), cursor) do
      {:ok, marker}
    end
  end

  def save_reading_position(_user, _feed_name, _cursor), do: {:error, :invalid_marker}

  @doc """
  Clear the server-side reading position cursor for a Bonfire feed.

  Note that with the marker row gone, the Mastodon API falls back to a
  Seen-derived position (same as for accounts that never saved one).
  """
  def clear_reading_position(user, feed_name) when not is_nil(user) do
    account_id = marker_subject_id(user)

    if is_binary(account_id) do
      feed_name = normalise_feed_name(feed_name)

      repo().delete_all(
        from(m in Marker, where: m.account_id == ^account_id and m.feed_name == ^feed_name)
      )
    end

    :ok
  end

  def clear_reading_position(_user, _feed_name), do: :ok

  @doc "Get markers for the given Mastodon timelines."
  def get(user, timelines \\ @valid_timelines) do
    account_id = marker_subject_id(user)
    rows = get_markers(account_id, Enum.map(timelines, &timeline_feed_name/1))

    Enum.reduce(timelines, %{}, fn timeline, acc ->
      case marker_for_timeline(user, account_id, timeline, rows[timeline_feed_name(timeline)]) do
        nil -> acc
        marker -> Map.put(acc, timeline, marker)
      end
    end)
  end

  @doc "Save a Mastodon timeline reading position."
  def save(user, timeline, last_read_id) do
    # Resolve the client-provided status/notification id to the activity id —
    # the canonical stored cursor space (shared with web saves) — so resume
    # pagination and cross-surface sync line up.
    activity_id = resolve_activity_id(user, timeline, last_read_id)

    with {:ok, marker, changed?} <-
           validated_save(user, timeline_feed_name(timeline), activity_id || last_read_id) do
      # Best-effort side effect so unseen counts/badges stay consistent (the
      # marker row above is canonical); skipped when the position didn't move.
      # Being in the user's own feed is the authorization that matters here, and
      # some feed items (e.g. like activities in notifications) wouldn't pass an
      # object-level `:see` boundary check, so pass a map to skip it (same path
      # as `mark_all_seen`).
      if changed? && activity_id, do: Seen.mark_seen(user, %{id: activity_id})

      # Echo the id space the client sent (the stored cursor may differ)
      {:ok, Map.put(format_marker_row(marker), "last_read_id", to_string(last_read_id))}
    end
  end

  defp marker_for_timeline(_user, _account_id, timeline, %Marker{} = marker) do
    Map.put(
      format_marker_row(marker),
      "last_read_id",
      to_string(masto_marker_id(timeline, marker.last_read_id))
    )
  end

  defp marker_for_timeline(user, account_id, timeline, nil) do
    seen_derived_marker(user, account_id, timeline)
  end

  # Stored cursors are feed (activity) ids; translate to the id space Mastodon
  # clients see. Notification ids are already activity ids; home statuses need
  # the object id except boosts (see `marker_last_read_id/2`).
  defp masto_marker_id("notifications", stored_id), do: stored_id

  defp masto_marker_id(timeline, stored_id) do
    case activity_info(stored_id) do
      # deleted activity or a cursor that wasn't an activity id: best effort
      nil -> stored_id
      info -> marker_last_read_id(timeline, info)
    end
  end

  defp activity_info(activity_id) do
    from(act in Activity,
      where: act.id == ^activity_id,
      select: %{activity_id: act.id, object_id: act.object_id, verb_id: act.verb_id}
    )
    |> repo().one()
  end

  defp validated_save(user, feed_name, cursor) do
    account_id = marker_subject_id(user)

    # `is_ulid?` (not `is_uid?`): feed cursors and the schema's column type are
    # ULIDs, and a UUID-format string would raise at the Ecto dump otherwise.
    if is_binary(account_id) and Bonfire.Common.Types.is_ulid?(cursor) do
      upsert_marker(account_id, feed_name, cursor)
    else
      {:error, :invalid_marker}
    end
  end

  defp upsert_marker(account_id, feed_name, cursor) do
    case get_marker(account_id, feed_name) do
      # skip the write (and version/WAL churn) when the position didn't move
      %Marker{last_read_id: ^cursor} = unchanged ->
        {:ok, maybe_touch(unchanged), false}

      _ ->
        now = DateTime.utc_now()

        case repo().insert(
               %Marker{account_id: account_id, feed_name: feed_name, last_read_id: cursor},
               on_conflict: [set: [last_read_id: cursor, updated_at: now], inc: [version: 1]],
               conflict_target: [:account_id, :feed_name],
               returning: true
             ) do
          {:ok, marker} -> {:ok, marker, true}
          error -> error
        end
    end
  end

  defp maybe_touch(%Marker{} = marker) do
    now = DateTime.utc_now()

    if DateTime.diff(now, marker.updated_at) > @touch_unchanged_after_seconds do
      from(m in Marker,
        where: m.account_id == ^marker.account_id and m.feed_name == ^marker.feed_name
      )
      |> repo().update_all(set: [updated_at: now])

      %{marker | updated_at: now}
    else
      marker
    end
  end

  defp get_marker(account_id, feed_name)
       when is_binary(account_id) and is_binary(feed_name) do
    repo().get_by(Marker, account_id: account_id, feed_name: feed_name)
  end

  defp get_marker(_account_id, _feed_name), do: nil

  defp get_markers(account_id, feed_names) when is_binary(account_id) do
    from(m in Marker, where: m.account_id == ^account_id and m.feed_name in ^feed_names)
    |> repo().all()
    |> Map.new(&{&1.feed_name, &1})
  end

  defp get_markers(_account_id, _feed_names), do: %{}

  defp format_marker_row(%Marker{} = marker) do
    %{
      "last_read_id" => to_string(marker.last_read_id),
      "version" => marker.version,
      "updated_at" => DatesTimes.to_iso8601(marker.updated_at)
    }
  end

  # Resolve a Mastodon `last_read_id` to its feed activity, scoped to the
  # user's timeline so we never match an activity from an unrelated feed
  # (e.g. someone's like of the same object). Matches both id spaces: the id may
  # be an activity id (notifications, boosts) or an object id (regular statuses).
  defp resolve_activity_id(user, timeline, last_read_id) do
    feed_ids = feed_ids_for_timeline(user, timeline)
    fp_mod = FeedActivities.feed_activities_schema()

    if feed_ids != [] do
      from(fp in fp_mod,
        inner_join: act in Activity,
        on: fp.id == act.id,
        where: fp.feed_id in ^feed_ids,
        where: act.id == ^last_read_id or act.object_id == ^last_read_id,
        order_by: [desc: act.id],
        select: act.id,
        limit: 1
      )
      |> repo().one()
    end
  end

  defp seen_derived_marker(user, account_id, timeline) do
    case last_seen_in_feed(user, account_id, timeline) do
      nil -> nil
      seen -> format_seen_marker(timeline, seen)
    end
  end

  defp last_seen_in_feed(user, account_id, timeline) do
    feed_ids = feed_ids_for_timeline(user, timeline)
    table_id = Bonfire.Common.Types.table_id(Bonfire.Data.Social.Seen)
    fp_mod = FeedActivities.feed_activities_schema()

    if account_id && feed_ids != [] && table_id do
      # Join matches unseen_query pattern: fp.id == seen.object_id
      from(fp in fp_mod,
        inner_join: seen in Edge,
        on:
          fp.id == seen.object_id and
            seen.table_id == ^table_id and
            seen.subject_id == ^account_id,
        inner_join: act in Activity,
        on: fp.id == act.id,
        where: fp.feed_id in ^feed_ids,
        order_by: [desc: fp.id],
        limit: 1,
        select: %{
          activity_id: act.id,
          object_id: act.object_id,
          verb_id: act.verb_id,
          seen_id: seen.id
        }
      )
      |> repo().one()
    end
  end

  defp feed_ids_for_timeline(user, "home"), do: Feeds.my_home_feed_ids(user)

  defp feed_ids_for_timeline(user, "notifications") do
    case Feeds.my_feed_id(:notifications, user) do
      nil -> []
      id -> [id]
    end
  end

  defp format_seen_marker(timeline, %{seen_id: seen_id} = seen) do
    %{
      "last_read_id" => to_string(marker_last_read_id(timeline, seen)),
      # Derived markers have no stored version counter.
      "version" => 0,
      # The Seen edge's ULID encodes when the item was marked read.
      "updated_at" =>
        DatesTimes.to_iso8601(DatesTimes.date_from_pointer(seen_id) || DateTime.utc_now())
    }
  end

  # Mastodon id spaces: notification ids are activity ids; home statuses use the
  # object id, except boosts whose status id is the boost activity id (matching
  # `Bonfire.API.MastoCompatible` status/notification mappers).
  defp marker_last_read_id("notifications", %{activity_id: activity_id}), do: activity_id

  defp marker_last_read_id(_home, %{
         activity_id: activity_id,
         object_id: object_id,
         verb_id: verb_id
       }) do
    if is_nil(object_id) or verb_id == Bonfire.Boundaries.Verbs.get_id(:boost),
      do: activity_id,
      else: object_id
  end

  defp normalise_feed_name(feed_name) when is_binary(feed_name), do: feed_name
  defp normalise_feed_name(feed_name), do: to_string(feed_name)

  # Markers are account-based like Seen (shared across profiles of an account),
  # using the same subject normalization so the Seen-derived fallback joins on
  # the same id.
  defp marker_subject_id(user), do: Enums.id(Seen.normalize_subject(user))
end
