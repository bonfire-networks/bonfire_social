defmodule Bonfire.Social.FeedActivities do

  require Logger

  alias Bonfire.Data.Social.{FeedPublish, Feed, PostContent}
  alias Bonfire.Data.Identity.User

  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Boundaries.Circles

  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Activities
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Threads

  import Bonfire.Common.Utils

  use Bonfire.Repo.Query,
      schema: FeedPublish,
      searchable_fields: [:id, :feed_id, :activity_id],
      sortable_fields: [:id]

  def queries_module, do: FeedPublish
  def context_module, do: FeedPublish

  def my_feed(socket, cursor_after \\ nil, include_notifications? \\ true) do

    # feeds the user is following
    feed_ids = Feeds.my_feed_ids(socket, include_notifications?)
    # IO.inspect(my_feed_ids: feed_ids)

    feed(feed_ids, socket, cursor_after)
  end

  def feed(feed, current_user_or_socket \\ nil, cursor_after \\ nil, preloads \\ :all)

  def feed(%{id: feed_id}, current_user_or_socket, cursor_after, preloads), do: feed(feed_id, current_user_or_socket, cursor_after, preloads)

  def feed(feed_id_or_ids, current_user_or_socket, cursor_after, preloads) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do
    # IO.inspect(feed_id_or_ids: feed_id_or_ids)
    feed_id_or_ids = maybe_flatten(feed_id_or_ids)

    pubsub_subscribe(feed_id_or_ids, current_user_or_socket) # subscribe to realtime feed updates

    # query FeedPublish, without messages
    [
      feed_id: feed_id_or_ids,
      # exclude: {:messages, &filter/3},
      # exclude_messages: dynamic([object_message: message], is_nil(message.id))
      exclude_messages: dynamic([object: object], object.table_id != ^("6R1VATEMESAGEC0MMVN1CAT10N"))
    ]
    |> feed_paginated(current_user(current_user_or_socket), cursor_after, preloads)
  end

  def feed(:notifications, current_user_or_socket, cursor_after, preloads) do
    # current_user = current_user(current_user_or_socket)

    case Bonfire.Social.Feeds.my_inbox_feed_id(current_user_or_socket) do
      feeds when is_binary(feeds) or is_list(feeds) ->

        feeds = maybe_flatten(feeds)
        # IO.inspect(query_notifications_feed_ids: feeds)

        pubsub_subscribe(feeds, current_user_or_socket) # subscribe to realtime feed updates

        [feed_id: feeds] # FIXME: for some reason preloading creator or reply_to when we have a boost in inbox breaks ecto
        |> feed_paginated(current_user_or_socket, cursor_after, preloads)

        e ->
          Logger.error("no feed for :notifications - #{e}")
          nil
    end

  end

  def feed(_, _, _, _, _), do: []


  def feed_paginated(filters \\ [], current_user \\ nil, cursor_after \\ nil, preloads \\ :all, query \\ FeedPublish, distinct \\ true)

  def feed_paginated(filters, current_user, cursor_after, preloads, query, distinct) when is_list(filters) do

    query(filters, current_user, preloads, query, distinct)
      |> Bonfire.Repo.many_paginated(after: cursor_after) # return a page of items (reverse chronological) + pagination metadata
  end

  def query(filters \\ [], current_user \\ nil, preloads \\ :all, query \\ FeedPublish, distinct \\ true)

  def query(filters, current_user, preloads, query, true = _distinct) when is_list(filters) do

    query(filters, current_user, preloads, query, false)
      |> distinct([activity: activity], [desc: activity.id])
  end

  def query(filters, current_user, preloads, query, _) when is_list(filters) do

    query
      |> query_extras(current_user, preloads)
      |> EctoShorts.filter(filters, nil, nil)
      # |> IO.inspect(label: "feed query")
  end


  defp query_extras(query, current_user, preloads) do
    query
      # add assocs needed in timelines/feeds
      |> join_preload([:activity])
      # |> IO.inspect(label: "feed_paginated pre-preloads")
      |> Activities.activity_preloads(current_user, preloads)
      # |> IO.inspect(label: "feed_paginated post-preloads")
      |> Activities.as_permitted_for(current_user)
      # |> IO.inspect(label: "feed_paginated post-boundaries")
      |> order_by([activity: activity], [desc: activity.id])
  end


  # def feed(%{feed_publishes: _} = feed_for, _) do
  #   repo().maybe_preload(feed_for, [feed_publishes: [activity: [:verb, :object, subject_user: [:profile, :character]]]]) |> Map.get(:feed_publishes)
  # end

  @doc """
  Creates a new local activity and publishes to appropriate feeds
  """

  def publish(subject, verb, object, circles \\ [], mentions_tags_are_private? \\ true, replies_are_private? \\ false)

  def publish(subject, verb, %{replied: %{reply_to_id: reply_to_id}} = object, circles, _, false = replies_are_private?) when is_atom(verb) and is_list(circles) and is_binary(reply_to_id) do
    # publishing a reply to something
    # TODO share some logic with maybe_notify_creator?
    # TODO enable by default only if OP is included in audience?
    # FIXME should be possible to notify tag + reply_to at same time
    # FIXME should notify reply_to user if included in target circles even when replies_are_private?==true
    object = Objects.preload_reply_creator(object)
    # IO.inspect(preload_reply_creator: object)
    reply_to_object = e(object, :replied, :reply_to, nil)
    # IO.inspect(reply_to_object: reply_to_object)
    reply_to_creator = Objects.object_creator(reply_to_object)
    # IO.inspect(publishing_reply: reply_to_creator)
    # reply_to_inbox = Feeds.inbox_of_obj_creator(reply_to_object)
    creator_id = e(reply_to_creator, :id, nil)

    with {:ok, activity} <- do_publish(subject, verb, object, circles ++ [creator_id]) do

      Threads.maybe_push_thread(subject, activity, object)

      # IO.inspect(notify_reply: reply_to_creator)
      Logger.info("putting in feed + notifications of the user being replied to: #{inspect creator_id}")
      notify_characters(subject, activity, object, reply_to_creator)
    end
  end

  def publish(subject, verb, %{tags: tags} = object, circles, false = tags_are_private?, _) when is_atom(verb) and is_list(tags) and length(tags) > 0 do
    # IO.inspect(publish_to_tagged: tags)

    # publishing to those @ mentionned or other tags
    mentioned = Feeds.tags_inbox_feeds(tags) #|> IO.inspect(label: "publish tag / mention")

    with {:ok, activity} <- do_publish(subject, verb, object, circles ++ mentioned) do
      Logger.info("putting in feed + notifications of @ mentioned / tagged characters: #{inspect mentioned}")
      notify_characters(subject, activity, object, mentioned)
    end
  end

  def publish(subject, verb, object, circles, tags_are_private?, replies_are_private?) when not is_list(circles) do
    publish(subject, verb, object, [circles], tags_are_private?, replies_are_private?)
  end

  def publish(subject, verb, object, circles, _, _) when is_atom(verb) do
    do_publish(subject, verb, object, circles)
  end

  def publish(subject, verb, object, circles, tags_are_private?, replies_are_private?) do
    Logger.info("Defaulting to a :create activity, because no such verb is defined: #{inspect verb} ")
    publish(subject, :create, object, circles, tags_are_private?, replies_are_private?)
  end


  defp do_publish(subject, verb, object, feeds \\ nil)
  defp do_publish(subject, verb, object, feeds) when is_list(feeds), do: maybe_feed_publish(subject, verb, object, feeds ++ [subject]) # also put in subject's outbox
  defp do_publish(subject, verb, object, feed_id) when not is_nil(feed_id), do: maybe_feed_publish(subject, verb, object, [feed_id, subject])
  defp do_publish(subject, verb, object, _), do: maybe_feed_publish(subject, verb, object, subject) # just publish to subject's outbox


  @doc """
  Records a remote activity and puts in appropriate feeds
  """
  def save_fediverse_incoming_activity(subject, verb, object) when is_atom(verb) do
    publish(subject, verb, object, Feeds.fediverse_feed_id())
  end

  @doc """
  Takes or creates an activity and publishes to object creator's inbox
  """
  def maybe_notify_creator(subject, %{activity: activity}, object), do: maybe_notify_creator(subject, activity, object)
  def maybe_notify_creator(%{id: subject_id} = subject, verb_or_activity, %{} = object) do
    object = Objects.preload_creator(object)
    object_creator = Objects.object_creator(object)
    object_creator_id = ulid(object_creator)
    if object_creator_id && subject_id != object_creator_id do
      Logger.info("maybe_notify_creator: #{inspect object_creator_id}")
      notify_characters(subject, verb_or_activity, object, object_creator)
    else
      Logger.info("maybe_notify_creator: just create an activity")
      maybe_feed_publish(subject, verb_or_activity, object, nil)
    end
    # TODO: notify remote users via AP
  end


  @doc """
  Creates a new local activity or takes an existing one and publishes to object's inbox (if object is an actor)
  """
  def notify_characters(subject, verb_or_activity, object, characters) do
    Logger.info("notify_characters: #{inspect characters}")
    maybe_feed_publish(subject, verb_or_activity, object, Feeds.inbox_feed_ids(characters)) #|> IO.inspect(label: "notify_feeds")
    # TODO: notify remote users via AP
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to object's inbox (assuming object is treated as a character)
  """
  def notify_object(subject, verb_or_activity, object) do

    notify_characters(subject, verb_or_activity, object, object)
    # TODO: notify remote users via AP
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to creator's inbox
  """
  def notify_admins(subject, verb_or_activity, object) do
    inboxes = Feeds.admins_inbox()
    Logger.debug("notify_admins: #{inspect inboxes}")
    maybe_feed_publish(subject, verb_or_activity, object, inboxes)
    # TODO: notify remote users via AP
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to specified feeds
  """
  def maybe_feed_publish(subject, verb_or_activity, object \\ nil, feeds)
  def maybe_feed_publish(subject, verb, object, feeds) when is_atom(verb), do: create_and_put_in_feeds(subject, verb, object, feeds)
  def maybe_feed_publish(subject, %{activity: activity}, _, feeds), do: maybe_feed_publish(subject, activity, feeds)
  def maybe_feed_publish(_subject, %Bonfire.Data.Social.Activity{} = activity, _, feeds) do
    federate_and_put_in_feeds(feeds, activity)
    {:ok, activity}
    # TODO: notify remote users via AP
  end
  def maybe_feed_publish(_, _, _, _) do
    Logger.warn("did not notify")
    {:ok, nil}
  end



  defp create_and_put_in_feeds(subject, verb, object, feed_id) when is_map(object) and is_binary(feed_id) or is_list(feed_id) do
    with {:ok, activity} <- Activities.create(subject, verb, object) do
      with {:ok, published} <- federate_and_put_in_feeds(feed_id, activity) do # publish in specified feed
        # IO.inspect(published, label: "create_and_put_in_feeds")
        {:ok, activity}
      else # meh
        publishes when is_list(publishes) and length(publishes)>0 -> {:ok, activity}
        _ ->
          Logger.warn("did not create_and_put_in_feeds: #{inspect feed_id}")
          {:ok, activity}
      end
    end
  end
  defp create_and_put_in_feeds(subject, verb, object, %{feed_id: feed_id}), do: create_and_put_in_feeds(subject, verb, object, feed_id)
  defp create_and_put_in_feeds(subject, verb, object, _) when is_map(object) do
    # for activities with no target feed, still create the activity
    Activities.create(subject, verb, object)
  end

  defp maybe_index_activity(subject, verb, object) do
    with {:ok, activity} <- Activities.create(subject, verb, object) do

        # maybe_index(activity) # TODO, indexing here?

        {:ok, activity}
    end
  end

  defp federate_and_put_in_feeds(feeds, activity) do
    # This makes sure it gets put in feed even if the
    # federation hook fails
    ret = put_in_feeds(feeds, activity)
    # TODO: add ActivityPub feed for remote activities

    try do
    # FIXME only run if ActivityPub is a target feed
    # TODO: only run for non-local activity
      maybe_federate_activity(activity)
    rescue
      _ -> ret
    end
  end

  defp put_in_feeds(feeds, activity) when is_list(feeds), do: feeds |> Circles.circle_ids() |> Enum.map(fn x -> put_in_feeds(x, activity) end) # TODO: optimise?

  defp put_in_feeds(feed_or_subject, activity) when is_map(feed_or_subject) or (is_binary(feed_or_subject) and feed_or_subject !="") do
    with %Feed{id: feed_id} = feed <- Feeds.feed_for(feed_or_subject),
    {:ok, published} <- do_put_in_feeds(feed_id, ulid(activity)) do

      published = %{published | activity: activity}

      pubsub_broadcast(feed_id, {{Bonfire.Social.Feeds, :new_activity}, activity}) # push to online users

      {:ok, published}
    else e ->
      Logger.warn("put_in_feeds: error when trying with feed_or_subject")
      IO.inspect(put_in_feeds_e: e)
      {:ok, nil}
    end
  end
  defp put_in_feeds(_, _) do
    Logger.warn("did not put_in_feeds")
    {:ok, nil}
  end

  defp do_put_in_feeds(feed, activity) when is_binary(activity) and is_binary(feed) do
    attrs = %{feed_id: (feed), activity_id: (activity)}
    repo().put(FeedPublish.changeset(attrs))
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_for_object(%{id: id}), do: delete_for_object(id)
  def delete_for_object(id) when is_binary(id) and id !="", do: FeedPublish |> EctoShorts.filter(activity_id: id) |> repo().delete_many() |> elem(1)
  def delete_for_object(ids) when is_list(ids), do: Enum.each(ids, fn x -> delete_for_object(x) end)
  def delete_for_object(_), do: nil

  def maybe_federate_activity(activity) do
    verb = Bonfire.Data.AccessControl.Verbs.verb!(activity.verb_id).verb

    do_federate_activity(activity.subject_id, verb, activity)
  end

  defp do_federate_activity(subject_id, :create, activity) do
    Bonfire.Social.Integration.ap_publish("create", activity.object_id, subject_id)
  end

  defp do_federate_activity(subject_id, :follow, activity) do
    follow = Bonfire.Social.Follows.get!(subject_id, activity.object_id)
    Bonfire.Social.Integration.ap_publish("create", follow, subject_id)
  end

  defp do_federate_activity(subject_id, :like, activity) do
    like = Bonfire.Social.Likes.get!(activity.subject, activity.object_id)
    Bonfire.Social.Integration.ap_publish("create", like.id, subject_id)
  end

  defp do_federate_activity(subject_id, :boost, activity) do
    boost = Bonfire.Social.Boosts.get!(activity.subject, activity.object)
    Bonfire.Social.Integration.ap_publish("create", boost, subject_id)
  end

  defp do_federate_activity(_, verb, _) do
    Logger.warn("unhandled outgoing federation verb: #{Atom.to_string(verb)}")
  end

  @doc "Defines additional query filters"

end
