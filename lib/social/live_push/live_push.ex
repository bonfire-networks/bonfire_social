defmodule Bonfire.Social.LivePush do
  use Bonfire.Common.Utils

  def push_activity(feed_ids, %{id: _, activity: %{id: _}=activity} = object),
    do: push_activity(feed_ids, activity |> Map.put(:object, object))

  def push_activity(feed_ids, activity) do
    pubsub_broadcast(feed_ids, {{Bonfire.Social.Feeds, :new_activity}, activity})
    debug(activity)
    maybe_push_thread(activity)
    activity
  end

  def notify(activity, feed_ids) do
    notify(activity.subject, activity.verb, activity.object, feed_ids)
  end

  def notify(subject, verb, object, feed_ids) do
    # debug(feed_ids)
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
    debug(activity, "maybe_push_thread: no replied info found}")
    nil
  end

  defp maybe_push_thread(%{thread_id: thread_id, reply_to_id: _reply_to_id}, activity) when is_binary(thread_id) do
    Logger.debug("maybe_push_thread: put in thread feed for anyone following the thread: #{inspect thread_id}")
    # IO.inspect(activity: activity)
    Logger.debug("maybe_push_thread: broadcasting to anyone currently viewing the thread")
    pubsub_broadcast(thread_id, {{Bonfire.Social.Posts, :new_reply}, {thread_id, activity}})
    # pubsub_broadcast(reply_to_id, {{Bonfire.Social.Posts, :new_reply}, {reply_to_id, activity}})
  end
  defp maybe_push_thread(replied, activity) do
    debug(replied, "maybe_push_thread: no reply_to info found}")
    nil
  end
end
