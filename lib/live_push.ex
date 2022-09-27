defmodule Bonfire.Social.LivePush do
  # FIXME: dependency on ui_common should be optional
  use Bonfire.UI.Common
  import Untangle
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities

  alias Bonfire.Data.Social.Activity

  @doc """
  Receives an activity with a nested object, or vice versa, uses PubSub to pushes to feeds and optionally notifications
  """
  def push_activity(feed_ids, activity, opts \\ [])

  def push_activity(feed_ids, %Activity{} = activity, opts) do
    debug(feed_ids, "push a :new_activity")
    activity = prepare_activity(activity, opts)

    pubsub_broadcast(feed_ids, {
      {Bonfire.Social.Feeds, :new_activity},
      [
        feed_ids: feed_ids,
        activity: activity
      ]
    })

    if Keyword.get(opts, :push_to_thread, true), do: maybe_push_thread(activity)

    case Keyword.get(opts, :notify) do
      notify_feed_ids when is_list(notify_feed_ids) ->
        notify(activity, notify_feed_ids)

      true ->
        notify(activity, feed_ids)

      _ ->
        nil
    end

    activity
  end

  def push_activity(
        feed_ids,
        %{id: _, activity: %{id: _} = _activity} = object,
        opts
      ) do
    debug(feed_ids, "push an object as :new_activity")

    activity_from_object(object)
    |> push_activity(feed_ids, ..., opts)
    # returns the object + the preloaded activity
    |> Map.put(object, :activity, ...)
  end

  @doc """
  Receives an activity *and* object, uses PubSub to pushes to feeds and optionally notifications, and returns an Activity.
  """
  def push_activity_object(
        feed_ids,
        %{id: _, activity: %{id: _}} = parent_object,
        object,
        opts
      ) do
    debug(feed_ids, "push an activity with custom object as :new_activity")

    # add object assocs to the activity
    maybe_merge_to_struct(
      parent_object.activity,
      Map.drop(parent_object, [:activity])
    )
    # push as activity with :object
    |> Map.put(:object, Map.drop(object, [:activity]))
    |> Map.drop([:activity])
    |> push_activity(feed_ids, ..., opts)
  end

  @doc """
  Sends a notification about an activity to a list of users, excluding the author/subject
  """
  def notify_users(subject, verb, object, users) do
    users
    |> Enum.reject(&(ulid(&1) == ulid(subject)))
    |> FeedActivities.get_feed_ids(notifications: ...)
    |> normalise_feed_ids()
    |> send_notifications(subject, verb, object, ...)
  end

  def notify_of_message(subject, verb, object, users) do
    activity_from_object(object)
    |> prepare_activity()
    |> maybe_push_thread()

    users =
      users
      |> Enum.reject(&(ulid(&1) == ulid(subject)))
      |> debug()

    # FIXME: avoid querying this again
    FeedActivities.get_feed_ids(inbox: users)
    |> increment_counters(:inbox)

    notify_users(subject, verb, object, users)
  end

  def prepare_activity(%Activity{} = activity, opts \\ []) do
    Activities.activity_preloads(activity, :feed_metadata, opts)

    # |> debug("make sure that all needed assocs are preloaded without n+1")
  end

  def notify(activity, feed_ids),
    do: notify(activity.subject, activity.verb, activity.object, feed_ids)

  def notify(subject, verb, object, feed_ids) do
    feed_ids = normalise_feed_ids(feed_ids)

    # increment currently visible unread counters
    increment_counters(feed_ids, :notifications)

    send_notifications(subject, verb, object, feed_ids)
  end

  defp send_notifications(subject, verb, object, feed_ids) do
    verb_display =
      Bonfire.Social.Activities.verb_name(verb)
      |> Bonfire.Social.Activities.verb_display()

    avatar = avatar_url(subject)

    icon =
      cond do
        is_binary(avatar) and avatar != avatar_fallback() -> avatar
        true -> Config.get([:ui, :theme, :instance_icon], "/images/bonfire-icon.png")
      end

    feed_ids
    |> debug("feed_ids")
    |> Bonfire.UI.Common.Notifications.notify_feeds(
      e(subject, :profile, :name, e(subject, :character, :username, "")) <>
        " " <>
        verb_display,
      e(
        object,
        :post_content,
        :name,
        e(
          object,
          :post_content,
          :summary,
          e(
            object,
            :post_content,
            :html_body,
            e(object, :profile, :name, e(object, :character, :username, ""))
          )
        )
      ),
      path(object),
      icon
    )
  end

  defp increment_counters(feed_ids, box) do
    feed_ids
    |> Enum.map(&"unseen_count:#{box}:#{&1}")
    |> pubsub_broadcast({{Bonfire.Social.Feeds, :count_increment}, box})
  end

  defp normalise_feed_ids(feed_ids) do
    feed_ids
    |> debug("feed_ids")
    |> ulid()
    |> List.wrap()
    |> filter_empty([])
  end

  defp activity_from_object(%{id: _, activity: %{id: _} = activity} = object) do
    object = Map.drop(object, [:activity])

    # add object assocs to the activity
    maybe_merge_to_struct(activity, object)
    # push as activity with :object
    |> Map.put(:object, object)
    |> Map.drop([:activity])
  end

  defp maybe_push_thread(%{replied: %{id: _} = replied} = activity) do
    maybe_push_thread(replied, activity)
  end

  defp maybe_push_thread(%{object: %{replied: %{id: _} = replied} = _object} = activity) do
    maybe_push_thread(replied, activity)
  end

  defp maybe_push_thread(activity) do
    debug(activity, "maybe_push_thread: no replied info found}")
    nil
  end

  defp maybe_push_thread(
         %{thread_id: thread_id, reply_to_id: _reply_to_id},
         activity
       )
       when is_binary(thread_id) do
    debug(
      "maybe_push_thread: put in thread feed for anyone following the thread: #{inspect(thread_id)}"
    )

    # debug(activity: activity)
    debug("maybe_push_thread: broadcasting to anyone currently viewing the thread")

    pubsub_broadcast(
      thread_id,
      {{Bonfire.Social.Threads.LiveHandler, :new_reply}, {thread_id, activity}}
    )

    # pubsub_broadcast(reply_to_id, {{Bonfire.Social.Threads.LiveHandler, :new_reply}, {reply_to_id, activity}})
  end

  defp maybe_push_thread(replied, activity) do
    debug(replied, "maybe_push_thread: no reply_to info found}")
    nil
  end
end
