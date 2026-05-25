defmodule Bonfire.Social.Markers do
  @moduledoc """
  Derive reading positions from Seen edges for Mastodon markers API.

  Bonfire markers are last-write-wins and derived from Seen edges rather than a
  stored marker row, so Mastodon's optimistic-concurrency `version` semantics
  are intentionally unsupported. Marker responses expose `version: 0` as a stub.
  """

  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  import Ecto.Query

  alias Bonfire.Common.Settings
  alias Bonfire.Data.Identity.{Account, User}
  alias Bonfire.Data.Social.Activity
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.{Seen, Feeds, FeedActivities}

  @valid_timelines ["home", "notifications"]

  def valid_timelines, do: @valid_timelines

  @doc """
  Get the server-side reading position cursor for a Bonfire feed.
  """
  def get_reading_position(user, feed_name) when not is_nil(user) do
    case Settings.get(reading_position_key(feed_name), nil,
           scope: marker_scope(user),
           preload: true
         ) do
      %{"last_read_id" => cursor} when is_binary(cursor) -> cursor
      %{last_read_id: cursor} when is_binary(cursor) -> cursor
      cursor when is_binary(cursor) -> cursor
      _ -> nil
    end
  end

  def get_reading_position(_user, _feed_name), do: nil

  @doc "Save the server-side reading position cursor for a Bonfire feed."
  def save_reading_position(user, feed_name, cursor)
      when not is_nil(user) and is_binary(cursor) and cursor != "" do
    marker = %{
      "last_read_id" => cursor,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Settings.put_raw(reading_position_key(feed_name), marker, scope: marker_scope(user)) do
      {:ok, _} -> {:ok, marker}
      error -> error
    end
  end

  def save_reading_position(_user, _feed_name, _cursor), do: {:error, :invalid_marker}

  @doc "Clear the server-side reading position cursor for a Bonfire feed."
  def clear_reading_position(user, feed_name) when not is_nil(user) do
    case Settings.put_raw(reading_position_key(feed_name), nil, scope: marker_scope(user)) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def clear_reading_position(_user, _feed_name), do: :ok

  @doc "Get markers for the given timelines by querying last Seen item in each feed."
  def get(user, timelines \\ @valid_timelines) do
    account_id = Enums.id(current_account(user) || user)

    Enum.reduce(timelines, %{}, fn timeline, acc ->
      case last_seen_in_feed(user, account_id, timeline) do
        nil -> acc
        post_id -> Map.put(acc, timeline, format_marker(post_id))
      end
    end)
  end

  @doc "Save a reading position by marking the given item as Seen."
  def save(user, timeline, last_read_id) do
    # Resolve post ID to activity/FeedPublish ID so the Seen edge is consistent
    # with mark_all_seen which stores object_id = activity_id
    activity_id = resolve_activity_id(user, timeline, last_read_id)

    case Seen.mark_seen(user, activity_id || last_read_id) do
      {:ok, _} ->
        {:ok,
         %{
           "last_read_id" => last_read_id,
           # Stub: Bonfire derives markers from Seen edges, so there is no stored
           # marker row/lock counter to implement Mastodon's version semantics.
           "version" => 0,
           "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      error ->
        error
    end
  end

  defp resolve_activity_id(_user, _timeline, post_id) do
    from(act in Activity,
      where: act.object_id == ^post_id,
      order_by: [desc: act.id],
      select: act.id,
      limit: 1
    )
    |> repo().one()
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
        select: act.object_id
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

  defp format_marker(post_id) do
    %{
      "last_read_id" => to_string(post_id),
      # Stub: see moduledoc; optimistic-concurrency versions are unsupported.
      "version" => 0,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp reading_position_key(feed_name) do
    [__MODULE__, :reading_positions, normalise_feed_name(feed_name)]
  end

  defp normalise_feed_name(feed_name) when is_atom(feed_name), do: Atom.to_string(feed_name)
  defp normalise_feed_name(feed_name) when is_binary(feed_name), do: feed_name
  defp normalise_feed_name(feed_name), do: to_string(feed_name)

  defp marker_scope(user) do
    case current_account(user) do
      %Account{id: id} when is_binary(id) -> %Account{id: id}
      account_id when is_binary(account_id) -> %Account{id: account_id}
      _ -> user_scope(user)
    end
  end

  defp user_scope(%User{id: id}) when is_binary(id), do: %User{id: id}
  defp user_scope(%{id: id}) when is_binary(id), do: %User{id: id}
  defp user_scope(user), do: user
end
