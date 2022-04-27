defmodule Bonfire.Social.LivePush do
  use Bonfire.Common.Utils
  import Where
  alias Bonfire.Social.Activities

  def push_activity(feed_ids, %{id: _, activity: %{id: _}} = object) do
    debug(feed_ids, "push an object as :new_activity")
    object = Activities.activity_preloads(object, :feed, [])

    object.activity
    |> Map.put(:object, Map.drop(object, [:activity])) # push as activity with :object
    |> push_activity(feed_ids, ...)

    object
  end

  def push_activity(feed_ids, activity) do
    debug(feed_ids, "push a :new_activity")
    activity = Activities.activity_preloads(activity, :feed, [])

    pubsub_broadcast(feed_ids, {
      {Bonfire.Social.Feeds, :new_activity},
      [
        feed_ids: feed_ids,
        activity: activity
      ]
      })

    maybe_push_thread(activity)

    activity
  end

  def notify(activity, feed_ids), do: notify(activity.subject, activity.verb, activity.object, feed_ids)

  def notify(subject, verb, object, feed_ids) do
    # debug(feed_ids)
    feed_ids =
      ulid(feed_ids)
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
    Bonfire.Notifications.notify_users(
      feed_ids,
      e(subject, :profile, :name,
        e(subject, :character, :username, "")
      )
      <> " "
      <> Bonfire.Social.Activities.verb_display(verb),
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
