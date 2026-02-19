defmodule Bonfire.Social.LivePush do
  @moduledoc "Handles pushing activities (via PubSub and/or email) to active feeds and notifications"

  use Bonfire.Common.Utils
  import Untangle
  import Bonfire.Social
  alias Bonfire.Common.PubSub
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Data.Social.Activity

  @doc """
  Receives an activity with a nested object, or vice versa, uses PubSub to pushes to feeds and optionally notifications
  """
  def push_activity(to_feeds, activity, opts \\ [])

  def push_activity(to_feeds, %Activity{} = activity, opts) do
    debug(to_feeds, "push a :new_activity to feed_ids")
    activity = prepare_activity(activity, opts)

    has_feed_ids? = is_binary(to_feeds) or (is_list(to_feeds) and to_feeds != [])

    if has_feed_ids?,
      do:
        PubSub.broadcast(to_feeds, {
          {Bonfire.Social.Feeds, :new_activity},
          [
            feed_ids: to_feeds,
            activity: activity
          ]
        })

    if Keyword.get(opts, :push_to_thread, true), do: maybe_push_thread(activity)

    notify(activity, Keyword.put_new(opts, :feed_ids, to_feeds))

    activity
  end

  def push_activity(
        to_notify,
        %{id: _, activity: _activity} = object,
        opts
      ) do
    # debug(to_notify, "push an object as :new_activity")

    activity_from_object(object)
    |> push_activity(to_notify, ..., opts)
    # returns the object + the preloaded activity
    |> Map.put(object, :activity, ...)
  end

  def push_activity(_to_notify, activity, _opts) do
    warn(activity, "skip invalid activity")
    activity
  end

  @doc """
  Receives an activity *and* object, uses PubSub to pushes to feeds and optionally notifications, and returns an Activity.
  """
  def push_activity_object(
        to_notify,
        %{id: _, activity: %{id: _}} = parent_object,
        object,
        opts
      ) do
    debug(to_notify, "push an activity with custom object as :new_activity")

    # add object assocs to the activity
    maybe_merge_to_struct(
      parent_object.activity,
      Map.drop(parent_object, [:activity])
    )
    # push as activity with :object
    |> Map.put(:object, Map.drop(object, [:activity]))
    |> Map.drop([:activity])
    |> push_activity(to_notify, ..., opts)
  end

  def hide_activity(feed_id, activity_id) do
    PubSub.broadcast(feed_id, {
      {Bonfire.Social.Feeds, :hide_activity},
      activity_id
    })

    # also send to the thread
    # TODO: only do this for thread roots, and otherwise notify the actual thread
    PubSub.broadcast(activity_id, {
      {Bonfire.Social.Feeds, :hide_activity},
      activity_id
    })

    # TODO!
    # if Keyword.get(opts, :push_to_thread, true), do: maybe_push_thread(activity)
  end

  def notify_of_message(subject, verb, object, users) do
    activity =
      activity_from_object(object)
      |> prepare_activity()

    # show the message in the thread if user has it open
    maybe_push_thread(activity)

    subject_id = uid(subject)

    users_excluding_me =
      users
      |> Enum.reject(&(uid(&1) == subject_id))
      |> debug()

    # FIXME: avoid querying this several times
    FeedActivities.get_publish_feed_ids(inbox: users_excluding_me)
    |> uids()
    # increment the badge in nav
    |> increment_counters(:inbox)

    # FIXME: avoid querying this several times
    inbox_feed_ids =
      FeedActivities.get_publish_feed_ids(inbox: users ++ [subject])
      |> uids()

    # show the thread in messages list view if the user has it open
    PubSub.broadcast(inbox_feed_ids, {
      :new_message,
      %{
        feed_ids: inbox_feed_ids,
        thread_id: e(object, :replied, :thread_id, nil) || e(activity, :replied, :thread_id, nil)
        # TODO: include the message?
        # activity: activity
      }
    })

    # finally send a regular notification too
    notify_users(subject, verb, object, users_excluding_me)
  end

  @doc """
  Sends a notification about an activity to a list of users, excluding the author/subject
  """
  def notify_users(subject, verb, object, users) do
    subject_id = uid(subject)

    # TODO: send email notif

    users
    |> Enum.reject(&(uid(&1) == subject_id))
    |> FeedActivities.get_publish_feed_ids(notifications: ...)
    |> uids()
    |> notify(subject, verb, object, ...)
  end

  def prepare_activity(%Activity{} = activity, opts \\ []) do
    Activities.activity_preloads(activity, [:feed_metadata, :feed_postload], opts)

    # |> debug("make sure that all needed assocs are preloaded without n+1")
  end

  def notify(activity, opts),
    do: send_notifications(activity, opts)

  def notify(subject, verb, object, opts) do
    send_notifications(%{subject: subject, verb: verb, object: object}, opts)
  end

  defp send_notifications(%{subject: subject, verb: verb, object: object} = activity, opts \\ []) do
    verb_display =
      Bonfire.Social.Activities.verb_name(verb)
      |> Bonfire.Social.Activities.verb_display()

    avatar = Media.avatar_url(subject)

    icon =
      cond do
        is_binary(avatar) and avatar != Media.avatar_fallback() -> avatar
        true -> Config.get([:ui, :theme, :instance_icon], "/images/bonfire-icon.png")
      end

    opt_notify =
      e(opts, :notify, nil)
      |> debug("notify opt")

    all_feed_ids = e(opts, :feed_ids, [])

    notify_feed_ids =
      cond do
        opt_notify == true ->
          all_feed_ids

        notify_feeds = e(opt_notify, :notify_feeds, nil) || e(opts, :notify_feeds, nil) ->
          notify_feeds

        is_list(opt_notify) ->
          opt_notify

        true ->
          []
      end
      |> debug("send_notify_feed_ids")
      |> uids()

    notify_emails =
      cond do
        notify_emails = e(opt_notify, :notify_emails, nil) || e(opts, :notify_emails, nil) ->
          notify_emails

        true ->
          []
      end
      |> uids()

    # {notify_feed_ids, notify_emails} =
    #   case (Keyword.keyword?(opts) && Keyword.get(opts, :notify)) || opts do
    #     %{notify_feeds: notify_feeds, notify_emails: notify_emails} ->
    #       {notify_feeds, notify_emails}

    #     %{notify_emails: notify_emails} ->
    #       {[], notify_emails}

    #     %{notify_feeds: notify_feeds} ->
    #       {notify_feeds, []}

    #     notify_feeds when is_list(notify_feeds) and notify_feeds != [] ->
    #       {notify_feeds, []}

    #     true ->
    #       {Keyword.get(opts, :feed_ids, []), []}

    #     _ ->
    #       {[], []}
    #   end

    # notify_feed_ids = uids(notify_feed_ids)

    # increment currently visible unread counters
    if notify_feed_ids != [] do
      increment_counters(notify_feed_ids, :notifications)
    end

    if notify_feed_ids != [] or notify_emails != [] do
      content =
        e(
          object,
          :post_content,
          :name,
          nil
        ) ||
          e(
            object,
            :named,
            :name,
            nil
          ) ||
          e(
            object,
            :name,
            nil
          ) ||
          e(
            object,
            :post_content,
            :summary,
            nil
          ) ||
          Text.maybe_markdown_to_html(
            e(
              object,
              :post_content,
              :html_body,
              nil
            )
          ) || e(object, :profile, :name, nil) ||
          e(object, :character, :username, nil)

      preview_assigns = %{
        title:
          (e(subject, :profile, :name, nil) || e(subject, :character, :username, "")) <>
            " #{verb_display}",
        message: Text.text_only(content || ""),
        url: path(object),
        icon: icon || Config.get([:ui, :theme, :instance_icon], nil)
      }

      # WIP: send email notif?
      if is_list(notify_emails) and notify_emails != [] do
        debug(notify_emails, "WIP - send email notifications")
        # debug(Bonfire.UI.Social.ActivityLive.activity_components(
        #      %{subject: subject, verb: verb},
        #      object,
        #      :email
        #    ))

        url = URIs.based_url(preview_assigns[:url])

        assigns =
          Bonfire.UI.Social.ActivityLive.prepare_assigns(%{
            activity: activity,
            object: object,
            permalink: url
          })

        email =
          Bonfire.Mailer.new(
            subject: "[Bonfire] " <> preview_assigns[:title]
            # html_body: preview_assigns[:title] <> "<p> #{content}<p><a href='#{url}'>See details</a>",
            # text_body: preview_assigns[:title] <> "\n\n" <> preview_assigns[:message] <> "\n\n" <> url
          )
          |> Bonfire.Mailer.Render.templated(Bonfire.UI.Social.ActivityLive, assigns,
            layout: Bonfire.UI.Common.Email.Basic
          )
          |> debug()

        Enum.map(notify_emails, &(Bonfire.Mailer.send_now(email, &1) |> debug()))
      end

      # Send in-app flash notifications to online users
      maybe_apply(Bonfire.UI.Common.Notifications, :notify_broadcast, [
        notify_feed_ids,
        preview_assigns
      ])

      # Send web push notifications
      send_push_notifications(notify_feed_ids, preview_assigns)
    end
  end

  defp send_push_notifications([], _preview_assigns), do: :ok

  defp send_push_notifications(user_ids, preview_assigns) do
    debug(preview_assigns, "📤 send_push_notifications called with preview_assigns")
    debug(user_ids, "📤 Sending to user_ids")

    if module_enabled?(Bonfire.Notify) do
      results = Bonfire.Notify.notify(preview_assigns, user_ids)

      debug(results, "📤 Push notification results")

      # Log results for debugging
      case results do
        {:error, reason} ->
          warn(reason, "Push notification error")

        results when is_list(results) ->
          successful = Enum.count(results, fn {status, _, _} -> status == :ok end)
          failed = Enum.count(results, fn {status, _, _} -> status == :error end)
          debug("Web push sent: #{successful} successful, #{failed} failed")

        other ->
          warn(other, "Unexpected result from notify")
      end
    else
      debug("Bonfire.Notify not enabled, skipping push notifications")
    end
  end

  defp increment_counters(feed_ids, box) do
    feed_ids
    |> Enum.map(&"unseen_count:#{box}:#{&1}")
    |> PubSub.broadcast({{Bonfire.Social.Feeds, :count_increment}, box})
  end

  defp activity_from_object(%{id: _, activity: _activity} = object) do
    # TODO: optimise and put elsewhere
    object =
      object
      |> repo().maybe_preload(:activity)

    activity =
      object
      |> Map.get(:activity)

    object =
      object
      |> Map.drop([:activity])

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
    debug(activity, "no replied info found}")
    nil
  end

  defp maybe_push_thread(
         %{thread_id: thread_id, reply_to_id: reply_to_id},
         activity
       )
       when is_binary(thread_id) do
    debug(
      thread_id,
      "broadcasting to anyone currently viewing the thread"
    )

    PubSub.broadcast(
      thread_id,
      {{Bonfire.Social.Threads.LiveHandler, :new_reply}, {thread_id, activity}}
    )

    # Also broadcast to the specific reply_to_id if it's different from thread_id
    if is_binary(reply_to_id) and reply_to_id != thread_id do
      debug(
        reply_to_id,
        "also broadcasting to the specific reply within the thread"
      )

      PubSub.broadcast(
        reply_to_id,
        {{Bonfire.Social.Threads.LiveHandler, :new_reply}, {reply_to_id, activity}}
      )
    end
  end

  defp maybe_push_thread(replied, _activity) do
    debug(replied, "maybe_push_thread: no reply_to info found}")
    nil
  end
end
