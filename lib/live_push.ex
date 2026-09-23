defmodule Bonfire.Social.LivePush do
  @moduledoc """
  Telling whoever has this open, right now.

  One function does it: `emit_live/3` broadcasts an activity to the feeds it reached, publishes it to GraphQL subscribers, shows it in the thread anyone is reading, bumps their unseen counters, and flashes it to people who are online. `hide_live/2` is the same for a retraction.

  Durable delivery is not here and never runs from here: that is `Bonfire.Notify.FanOut`, reached after the transaction commits, and sending from both places would deliver everything twice. The two are meant to be different: a missed broadcast is harmless because the feed row is the record, while a missed notification is a real loss.

  Called after a commit, from whoever committed: the Epic's Act for posts, and the funnel's own exits for edges, messages and the post-hoc publish route.
  """

  use Bonfire.Common.Utils
  import Untangle
  import Bonfire.Social
  alias Bonfire.Common.PubSub
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Data.Social.Activity

  @doc """
  Broadcasts an activity to everyone who has somewhere it appears open, and returns it.

  Takes an activity or an object carrying one, plus the feed ids it was published to.

  Options:
    * `:object` — a different object to show the activity as being about, for an edge whose own object
      is the thing being liked or boosted rather than the edge.
    * `:notify` / `:notify_feeds` — which of the feeds are notifications, since those are the ones
      whose unseen counters move and whose owners get a flash. Accepts the map the write path already
      built, a list of feed ids, or `true` to mean all of them.
    * `:box` — which counter the notifications belong to, `:notifications` (default) or `:inbox`.
    * `:push_to_thread` — whether anyone reading the thread should see it appear, default true.
  """
  def emit_live(activity_or_object, feed_ids, opts \\ [])

  def emit_live(%Activity{} = activity, feed_ids, opts) do
    activity = activity |> with_object(opts[:object]) |> prepare_activity(opts)

    # passed through as given rather than normalised: a subscriber matches on what it subscribed to, which is not always an id (a thread topic, a test topic), and the payload carries the same value back
    has_feed_ids? = is_binary(feed_ids) or (is_list(feed_ids) and feed_ids != [])

    if has_feed_ids? do
      debug(feed_ids, "broadcast a :new_activity to feeds")

      PubSub.broadcast(feed_ids, {
        {Bonfire.Social.Feeds, :new_activity},
        [feed_ids: feed_ids, activity: activity]
      })

      maybe_publish_graphql_subscription(feed_ids, activity)
    end

    if Keyword.get(opts, :push_to_thread, true), do: maybe_push_thread(activity)

    case notified_feed_ids(opts) do
      [] ->
        nil

      notified ->
        increment_counters(notified, Keyword.get(opts, :box, :notifications))
        flash_to_subscribers(activity, notified)
    end

    activity
  end

  def emit_live(%{id: _, activity: _activity} = object, feed_ids, opts) do
    activity_from_object(object)
    |> emit_live(feed_ids, opts)
    # hand back the object with its prepared activity, since that is what a caller of this shape has
    |> Map.put(object, :activity, ...)
  end

  def emit_live(other, _feed_ids, _opts) do
    warn(other, "nothing to broadcast: not an activity, and carrying none")
    other
  end

  @doc """
  Tells everyone who has it open that an activity is gone.

  The payload carries `feed_ids` like `:new_activity` does, so a subscriber that tracks several feeds (the Mastodon streaming socket) can match the retraction to the right stream. Already-delivered notifications are not recalled, which is what the delivery job's existence check covers for the ones that haven't gone out yet.
  """
  def hide_live(feed_ids, activity_id) do
    PubSub.broadcast(feed_ids, {
      {Bonfire.Social.Feeds, :hide_activity},
      [feed_ids: List.wrap(feed_ids), activity_id: activity_id]
    })

    # and to anyone reading the thread it was in
    PubSub.broadcast(activity_id, {
      {Bonfire.Social.Feeds, :hide_activity},
      [feed_ids: List.wrap(activity_id), activity_id: activity_id]
    })
  end

  @doc """
  The live half of sending a direct message: everything `emit_live/3` does, plus what only messages need.

  A DM has one more audience than a notification does, the messages list itself, so everyone in the conversation is told a thread has a new message even if they are looking at the list rather than the thread. Counters go to the inbox box rather than notifications, since that is the badge a DM moves.
  """
  def emit_live_message(subject, object, users) do
    activity = activity_from_object(object) |> prepare_activity()
    subject_id = uid(subject)
    others = Enum.reject(users, &(uid(&1) == subject_id))

    inbox_feed_ids = FeedActivities.get_publish_feed_ids(inbox: users ++ [subject]) |> uids()

    PubSub.broadcast(inbox_feed_ids, {
      :new_message,
      %{
        feed_ids: inbox_feed_ids,
        thread_id: e(object, :replied, :thread_id, nil) || e(activity, :replied, :thread_id, nil),
        # the message activity, so consumers (the Mastodon streaming socket) can render the conversation's last status and who is in it
        activity: activity
      }
    })

    emit_live(activity, inbox_feed_ids,
      notify_feeds: FeedActivities.get_publish_feed_ids(inbox: others) |> uids(),
      box: :inbox
    )
  end

  @doc """
  Preloads an activity to the point where it can be displayed.

  The same set the feed itself uses, so what a live-rendered activity shows matches what a reload would.
  """
  def prepare_activity(%Activity{} = activity, opts \\ []) do
    Activities.activity_preloads(activity, live_push_preloads(activity), opts)
    # resolve subject/creator the same way the feed/read paths do, so a locality-marked
    # `current_user`/`subject_user` (carrying `:peered`) is used — letting the live-rendered
    # activity classify `is_local?` without an on-demand raising preload
    |> Activities.prepare_subject_and_creator(opts)
  end

  # an edge's activity is about the edge, so a like or boost has to be shown as being about what was liked or boosted
  defp with_object(activity, nil), do: activity

  defp with_object(activity, object) do
    activity
    |> maybe_merge_to_struct(Map.drop(object, [:activity]))
    |> Map.put(:object, Map.drop(object, [:activity]))
    |> Map.drop([:activity])
  end

  # which of the published feeds are notifications, in whichever shape the caller has: the map the write path built, a bare list, or `true` for all of them
  defp notified_feed_ids(opts) do
    notify = e(opts, :notify, nil)

    cond do
      notify == true -> e(opts, :feed_ids, [])
      feeds = e(notify, :notify_feeds, nil) || e(opts, :notify_feeds, nil) -> feeds
      is_list(notify) -> notify
      true -> []
    end
    |> uids()
  end

  # An in-app notification for whoever has one of these feeds open, from the same description a push notification's content comes from, so both say the same thing about the same activity.
  # Sent as fields rather than as a sentence: this process resolved what happened, and each recipient's own process puts it into their language. The activity id travels with it, which is what a client collapses on, so an activity several open tabs all hear about becomes one popup rather than one each.
  # Only without `bonfire_notify`: with it, this is `Bonfire.Notify.Live`, a delivery channel the fan-out sends on after asking who can still see it, who hasn't seen it, and whether they switched that kind off under Push. Sending it from here as well reached people who had switched it off. Without the extension there is no fan-out, so connected clients still hear about it, unfiltered
  defp flash_to_subscribers(activity, notified_feed_ids) do
    if not Bonfire.Common.Extend.module_enabled?(Bonfire.Notify.Live) do
      maybe_apply(Bonfire.UI.Common.Notifications, :notify_broadcast, [
        notified_feed_ids,
        Activities.describe_parts(activity) |> Map.put(:activity_id, uid(activity))
      ])
    end
  end

  defp increment_counters(feed_ids, box) do
    Enum.each(feed_ids, fn feed_id ->
      PubSub.broadcast(
        "unseen_count:#{feed_id}",
        {{Bonfire.Social.Feeds, :count_increment}, %{box: box, feed_id: feed_id}}
      )
    end)
  end

  defp live_push_preloads(%Activity{object: object}) do
    [:feed_metadata, :feed_postload]
    |> Bonfire.Social.FeedLoader.map_activity_preloads()
    |> maybe_skip_object_creator(object)
  end

  defp maybe_skip_object_creator(preloads, object) when is_map(object) do
    if Map.has_key?(object, :created),
      do: preloads,
      else: Enum.reject(preloads, &(&1 == :with_creator))
  end

  defp maybe_skip_object_creator(preloads, _object), do: preloads

  defp activity_from_object(%{id: _, activity: _activity} = object) do
    # TODO: optimise and put elsewhere
    object = repo().maybe_preload(object, :activity)
    activity = Map.get(object, :activity)
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

    # GraphQL subscribers viewing this discussion (topic = thread_id / reply_to_id)
    maybe_publish_graphql_subscription([thread_id, reply_to_id], activity)
  end

  defp maybe_push_thread(replied, _activity) do
    debug(replied, "maybe_push_thread: no reply_to info found}")
    nil
  end

  # Publish to GraphQL subscriptions (graphql-ws) keyed by feed/thread id, so a client subscribed to `feedActivity` (topic = a feed id or thread id) receives the activity live, without an extra query. No-op if Absinthe subscriptions aren't available.
  defp maybe_publish_graphql_subscription(topics, activity) do
    if Code.ensure_loaded?(Absinthe.Subscription) do
      endpoint = Bonfire.Common.Config.endpoint_module()

      topics
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.each(fn topic ->
        Absinthe.Subscription.publish(endpoint, activity, feed_activity: topic)
      end)
    end
  rescue
    e -> warn(e, "could not publish graphql subscription")
  end
end
