defmodule Bonfire.Social.LivePush do
  use Bonfire.UI.Common # FIXME: dependency on ui_common should be optional
  import Where
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Data.Social.Activity

  def push_activity(feed_ids, activity, opts \\ [])

  def push_activity(feed_ids, %Activity{} = activity, opts) do
    debug(feed_ids, "push a :new_activity")
    activity = Activities.activity_preloads(activity, :feed, [])  # makes sure that all needed assocs are preloaded without n+1
    # |> dump()

    pubsub_broadcast(feed_ids, {
      {Bonfire.Social.Feeds, :new_activity},
      [
        feed_ids: feed_ids,
        activity: activity
      ]
      })

    if Keyword.get(opts, :push_to_thread, true), do: maybe_push_thread(activity)

    if Keyword.get(opts, :notify, false), do: notify(activity, feed_ids)

    activity
  end

  def push_activity(feed_ids, %{id: _, activity: %{id: _}} = object, opts) do
    debug(feed_ids, "push an object as :new_activity")

    maybe_merge_to_struct(object.activity, object) # add object assocs to the activity
    |> Map.put(:object, object |> Map.drop([:activity])) # push as activity with :object
    |> Map.drop([:activity])
    |> push_activity(feed_ids, ..., opts)

    object
  end

  def notify_users(subject, verb, object, users) do
    FeedActivities.get_feed_ids(notifications: users)
    |> normalise_feed_ids()
    |> send_notifications(subject, verb, object, ...)
  end

  def notify_of_message(subject, verb, object, users) do

    FeedActivities.get_feed_ids(inbox: users) # FIXME: avoid querying this again
    |> increment_counters(:inbox)

    FeedActivities.get_feed_ids(notifications: users)
    |> normalise_feed_ids()
    |> send_notifications(subject, verb, object, ...)
  end

  def notify(activity, feed_ids), do: notify(activity.subject, activity.verb, activity.object, feed_ids)

  def notify(subject, verb, object, feed_ids) do

    feed_ids = normalise_feed_ids(feed_ids)

    # increment currently visible unread counters
    increment_counters(feed_ids, :notifications)

    send_notifications(subject, verb, object, feed_ids)
  end

  defp send_notifications(subject, verb, object, feed_ids) do

    verb_display = Bonfire.Social.Activities.verb_name(verb)
    |> Bonfire.Social.Activities.verb_display()

    feed_ids
    |> debug("feed_ids")
    |> Bonfire.UI.Common.Notifications.notify_feeds(
      e(subject, :profile, :name,
        e(subject, :character, :username, "")
      )
      <> " "
      <> verb_display,
      e(object, :post_content, :name,
        e(object, :post_content, :summary,
          e(object, :post_content, :html_body,
            e(object, :profile, :name,
              e(object, :character, :username, "")
            )
          )
        )
      )
    )
  end

  defp increment_counters(feed_ids, box) do
    feed_ids
    |> Enum.map(& "unseen_count:#{box}:#{&1}")
    |> pubsub_broadcast({{Bonfire.Social.Feeds, :count_increment}, box})
  end

  defp normalise_feed_ids(feed_ids) do
    feed_ids
      |> debug("feed_ids")
      |> ulid()
      |> List.wrap()
      |> filter_empty([])
  end

  defp maybe_push_thread(%{replied: %{id: _} = replied} = activity) do
    maybe_push_thread(replied, activity)
  end
  defp maybe_push_thread(%{object: %{replied: %{id: _} = replied} = _object} = activity) do
    maybe_push_thread(replied, activity)
  end
  defp maybe_push_thread(activity) do
    # debug(activity, "maybe_push_thread: no replied info found}")
    nil
  end

  defp maybe_push_thread(%{thread_id: thread_id, reply_to_id: _reply_to_id}, activity) when is_binary(thread_id) do
    debug("maybe_push_thread: put in thread feed for anyone following the thread: #{inspect thread_id}")
    # debug(activity: activity)
    debug("maybe_push_thread: broadcasting to anyone currently viewing the thread")
    pubsub_broadcast(thread_id, {{Bonfire.Social.Posts, :new_reply}, {thread_id, activity}})
    # pubsub_broadcast(reply_to_id, {{Bonfire.Social.Posts, :new_reply}, {reply_to_id, activity}})
  end
  defp maybe_push_thread(replied, activity) do
    # debug(replied, "maybe_push_thread: no reply_to info found}")
    nil
  end
end
