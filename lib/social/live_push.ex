defmodule Bonfire.Social.LivePush do
  use Bonfire.Common.Utils

  def push_activity(feed_ids, activity) do
    pubsub_broadcast(feed_ids, {{Bonfire.Social.Feeds, :new_activity}, activity})
    activity
  end

  def notify(activity, inbox_ids) do
    notify(activity.subject, activity.verb, activity.object, inbox_ids)
  end

  def notify(subject, verb, object, inbox_ids) do
    # debug(inbox_ids)
    Bonfire.Notifications.notify_users(
      inbox_ids,
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
