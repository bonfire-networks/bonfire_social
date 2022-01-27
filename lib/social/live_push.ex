defmodule Bonfire.Social.LivePush do
  use Bonfire.Common.Utils

  def push_activity(feed_ids, activity) do
    pubsub_broadcast(feed_ids, {{Bonfire.Social.Feeds, :new_activity}, activity})
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

  defp maybe_push_thread(%{replied: %{thread_id: thread_id, reply_to_id: reply_to_id}} = activity) when is_binary(thread_id) and is_binary(reply_to_id) do
    Logger.debug("Threads: put in thread feed for anyone following the thread: #{inspect thread_id}")
    # IO.inspect(activity: activity)
    Logger.debug("Threads: broadcasting to anyone currently viewing the thread")
    pubsub_broadcast(thread_id, {{Bonfire.Social.Posts, :new_reply}, {thread_id, activity}})
    # pubsub_broadcast(reply_to_id, {{Bonfire.Social.Posts, :new_reply}, {reply_to_id, activity}})
  end
  defp maybe_push_thread(_), do: nil
end
