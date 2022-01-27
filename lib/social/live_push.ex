defmodule Bonfire.Social.LivePush do
  use Bonfire.Common.Utils

  def push_activity(feed_ids, activity) do
    pubsub_broadcast(feed_ids, {{Bonfire.Social.Feeds, :new_activity}, activity})
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

end
