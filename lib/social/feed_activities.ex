defmodule Bonfire.Social.FeedActivities do

  require Logger
  alias Bonfire.Data.Social.FeedPublish
  alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Activities
  alias Bonfire.Common.Utils

  use Bonfire.Repo.Query,
      schema: FeedPublish,
      searchable_fields: [:id, :feed_id, :activity_id],
      sortable_fields: [:id]


  def my_feed(socket_or_user, cursor_before \\ nil) do

    # feeds the user is following
    feed_ids = Feeds.my_feed_ids(Utils.current_user(socket_or_user))
    # IO.inspect(my_feed_ids: feed_ids)

    feed(feed_ids, socket_or_user, cursor_before)
  end

  def feed(feed, current_user_or_socket \\ nil, cursor_before \\ nil, preloads \\ :all)

  def feed(%{id: feed_id}, current_user_or_socket, cursor_before, preloads), do: feed(feed_id, current_user_or_socket, cursor_before, preloads)

  def feed(feed_id_or_ids, current_user_or_socket, cursor_before, preloads) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do
    # IO.inspect(feed_id_or_ids: feed_id_or_ids)

    Utils.pubsub_subscribe(feed_id_or_ids, current_user_or_socket) # subscribe to realtime feed updates

    # query FeedPublish, without messages
    [
      feed_id: feed_id_or_ids,
      # exclude: {:messages, &filter/3},
      exclude_messages: dynamic([object_message: message], is_nil(message.id))
    ]
    |> feed_query_paginated(Utils.current_user(current_user_or_socket), cursor_before, preloads)
  end

  def feed(:notifications, current_user_or_socket, cursor_before, preloads) do
    current_user = Utils.current_user(current_user_or_socket)

    feed_id = Bonfire.Social.Feeds.my_inbox_feed_id(current_user)
    IO.inspect(notifications_feed_id: feed_id)

    Utils.pubsub_subscribe(feed_id, current_user_or_socket) # subscribe to realtime feed updates

    [feed_id: feed_id] # FIXME: for some reason preloading creator or reply_to when we have a boost in inbox breaks ecto
    |> feed_query_paginated(current_user, cursor_before, preloads)
  end

  def feed(_, _, _, _, _), do: []


  def feed_query_paginated(filters, current_user \\ nil, cursor_before \\ nil, preloads \\ :all, query \\ FeedPublish) do

    query
      # add assocs needed in timelines/feeds
      # |> join_preload([:activity])
      # |> IO.inspect(label: "pre-preloads")
      |> Activities.activity_preloads(current_user, preloads)
      |> EctoShorts.filter(filters)
      |> IO.inspect(label: "feed_query_paginated_post-preloads")
      |> Activities.as_permitted_for(current_user)
      # |> distinct([fp], [desc: fp.id, desc: fp.activity_id]) # not sure if/why needed... but possible fix for found duplicate ID for component Bonfire.UI.Social.ActivityLive in UI
      # |> order_by([fp], desc: fp.id)
      # |> IO.inspect(label: "post-permissions")
      # |> Bonfire.Repo.all() # return all items
      |> Bonfire.Repo.many_paginated(before: cursor_before) # return a page of items (reverse chronological) + pagination metadata
      # |> IO.inspect
  end

  # def feed(%{feed_publishes: _} = feed_for, _) do
  #   repo().maybe_preload(feed_for, [feed_publishes: [activity: [:verb, :object, subject_user: [:profile, :character]]]]) |> Map.get(:feed_publishes)
  # end

  @doc """
  Creates a new local activity and publishes to appropriate feeds
  """

  def publish(subject, verb, %{replied: %{reply_to_id: reply_to_id}} = object) when is_atom(verb) and is_binary(reply_to_id) do
    # publishing a reply to something
    #IO.inspect(publish_reply: object)
    do_publish(subject, verb, object, [Feeds.instance_feed_id(), Feeds.inbox_of_obj_creator(object)]) # FIXME, enable tagging in replies too
  end

  def publish(subject, verb, %{tags: tags} = object) when is_atom(verb) and is_list(tags) do
    # publishing something with @ mentions or other tags
    # IO.inspect(publish_to_tagged: tags)
    tagged_inboxes = Feeds.tags_feed(tags)
    # IO.inspect(tagged_inboxes: tagged_inboxes)
    do_publish(subject, verb, object, [Feeds.instance_feed_id(), tagged_inboxes])
  end

  def publish(subject, verb, object) when is_atom(verb) do
    do_publish(subject, verb, object, Feeds.instance_feed_id())
  end

  def publish(subject, verb, object) when is_binary(verb) do
    Logger.info("Defaulting to a :create activity, because no such verb is defined: "<>verb)
    do_publish(subject, :create, object, Feeds.instance_feed_id())
  end

  defp do_publish(subject, verb, object, feeds \\ nil)
  defp do_publish(subject, verb, object, feeds) when is_list(feeds), do: maybe_notify(subject, verb, object, feeds ++ [subject])
  defp do_publish(subject, verb, object, feed_id) when not is_nil(feed_id), do: maybe_notify(subject, verb, object, [feed_id, subject])
  defp do_publish(subject, verb, object, _), do: maybe_notify(subject, verb, object, subject) # just publish to subject's outbox


  @doc """
  Records a remote activity and puts in appropriate feeds
  """
  def save_fediverse_incoming_activity(subject, verb, object) when is_atom(verb) do
    do_publish(subject, verb, object, Feeds.fediverse_feed_id())
  end

  @doc """
  Takes or creates an activity and publishes to object creator's inbox
  """
  def maybe_notify_creator(subject, %{activity: activity}, object), do: maybe_notify_creator(subject, activity, object)
  def maybe_notify_creator(%{id: subject_id} = subject, verb_or_activity, %{} = object) do
    #IO.inspect(activity)
    object = object_with_creator(object)
    #IO.inspect(object)
    if subject_id != object_creator(object), do: maybe_notify(subject, verb_or_activity, Feeds.inbox_of_obj_creator(object))
    # TODO: notify remote users via AP
  end

  def object_with_creator(object) do
    object
    |> Bonfire.Repo.maybe_preload([created: [creator_character: [:inbox]]]) #|> IO.inspect
    |> Bonfire.Repo.maybe_preload([creator: [character: [:inbox]]]) #|> IO.inspect
  end
  def object_creator(object) do
    Utils.e(object, :created, :creator_id, Utils.e(object, :creator, :id, nil))
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to object's inbox (if object is an actor)
  """
  def maybe_notify_object(subject, verb_or_activity, object) do

    maybe_notify(subject, verb_or_activity, object, Feeds.inbox_feed_id(object))
    # TODO: notify remote users via AP
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to creator's inbox
  """
  def maybe_notify_admins(subject, verb_or_activity, object) do

    maybe_notify(subject, verb_or_activity, object, Feeds.admins_inbox())
    # TODO: notify remote users via AP
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to specified feeds
  """
  def maybe_notify(subject, verb_or_activity, object \\ nil, feeds)
  def maybe_notify(subject, verb, object, feeds) when is_atom(verb), do: create_and_put_in_feeds(subject, verb, object, feeds)
  def maybe_notify(subject, %{activity: activity}, _, feeds), do: maybe_notify(subject, activity, feeds)
  def maybe_notify(_subject, %Bonfire.Data.Social.Activity{} = activity, _, feeds) do
    put_in_feeds(feeds, activity)
    # TODO: notify remote users via AP
  end
  def maybe_notify(_, _, _, _) do
    Logger.warn("did not notify")
    {:ok, nil}
  end


  defp create_and_put_in_feeds(subject, verb, object, feed_id) when is_binary(feed_id) or is_list(feed_id) do
    with {:ok, activity} <- Activities.create(subject, verb, object) do
      with {:ok, published} <- put_in_feeds(feed_id, activity) do # publish in specified feed
        {:ok, published}
      else
        publishes when is_list(publishes) and length(publishes)>0 -> List.first(publishes) # meh
        _ ->
          Logger.warn("did not put_in_feeds: #{inspect feed_id}")
          {:ok, activity}
      end
    end
  end
  defp create_and_put_in_feeds(subject, verb, object, %{feed_id: feed_id}), do: create_and_put_in_feeds(subject, verb, object, feed_id)


  defp put_in_feeds(feeds, activity) when is_list(feeds), do: Enum.map(feeds, fn x -> put_in_feeds(x, activity) end) # TODO: optimise?

  defp put_in_feeds(feed_or_subject, activity) when is_map(feed_or_subject) or (is_binary(feed_or_subject) and feed_or_subject !="") do
    with {:ok, %{id: feed_id} = feed} <- Feeds.feed_for_id(feed_or_subject),
    {:ok, published} <- do_put_in_feeds(feed, activity) do

      published = %{published | activity: activity}

      Utils.pubsub_broadcast(feed_id, {:feed_new_activity, activity}) # push to online users

      {:ok, published}
    else e ->
      Logger.warn("error when trying to feed_or_subject")
      IO.inspect(put_in_feeds_e: e)
      {:ok, nil}
    end
  end
  defp put_in_feeds(_, _) do
    Logger.warn("did not put_in_feeds")
    {:ok, nil}
  end

  defp do_put_in_feeds(feed_id, activity_id) do
    attrs = %{feed_id: Utils.ulid(feed_id), activity_id: Utils.ulid(activity_id)}
    repo().put(FeedPublish.changeset(attrs))
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_for_object(%{id: id}), do: delete_for_object(id)
  def delete_for_object(id) when is_binary(id) and id !="", do: FeedPublish |> EctoShorts.filter(activity_id: id) |> repo().delete_all() |> elem(1)
  def delete_for_object(ids) when is_list(ids), do: Enum.each(ids, fn x -> delete_for_object(x) end)
  def delete_for_object(_), do: nil

  @doc "Defines additional query filters"





  #doc "List likes created by the user and which are in their outbox, which are not replies"
  # FIXME: we are not putting likes in outbox
  def filter(:boosts_by, user_id, query) when is_binary(user_id) do
    verb_id = Verbs.verbs()[:boost]

    {
      query
      |> join_preload([:activity, :subject_character]),
      dynamic(
        [activity: activity, subject_character: booster],
        activity.verb_id==^verb_id and booster.id == ^user_id
      )
    }
  end

  #doc "List likes created by the user and which are in their outbox, which are not replies"
  # FIXME: we are not putting likes in outbox
  def filter(:likes_by, user_id, query) when is_binary(user_id) do
    verb_id = Verbs.verbs()[:like]

    {
      query
      |> join_preload([:activity, :subject_character]),
      dynamic(
        [activity: activity, subject_character: liker],
        activity.verb_id==^verb_id and liker.id == ^user_id
      )
    }
  end


end
