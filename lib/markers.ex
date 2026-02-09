defmodule Bonfire.Social.Markers do
  @moduledoc "Derive reading positions from Seen edges for Mastodon markers API."

  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  import Ecto.Query

  alias Bonfire.Data.Social.Activity
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.{Seen, Feeds, FeedActivities}

  @valid_timelines ["home", "notifications"]

  def valid_timelines, do: @valid_timelines

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
           "version" => 0,
           "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      error ->
        error
    end
  end

  defp resolve_activity_id(user, timeline, post_id) do
    feed_ids = feed_ids_for_timeline(user, timeline)
    fp_mod = FeedActivities.feed_activities_schema()

    if feed_ids != [] do
      from(fp in fp_mod,
        inner_join: act in Activity,
        on: fp.id == act.id,
        where: fp.feed_id in ^feed_ids and act.object_id == ^post_id,
        select: fp.id,
        limit: 1
      )
      |> repo().one()
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
        order_by: [desc: seen.id],
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
      "version" => 0,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
