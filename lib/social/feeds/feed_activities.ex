defmodule Bonfire.Social.FeedActivities do

  require Logger

  alias Bonfire.Data.Social.{Activity, FeedPublish, Feed, PostContent}
  alias Bonfire.Data.Identity.{Character, User}

  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Boundaries.Circles

  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Activities
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Threads

  use Bonfire.Common.Utils

  use Bonfire.Repo,
      schema: FeedPublish,
      searchable_fields: [:id, :feed_id, :activity_id],
      sortable_fields: [:id]

  def queries_module, do: FeedPublish
  def context_module, do: FeedPublish

  def cast_data(_changeset, activity, creator, preset_or_custom_boundary) do
    Feeds.target_feeds(_changeset, creator, preset_or_custom_boundary)
    # |> debug("feeds")
    |> Enum.map(&(%{feed_id: &1, activity_id: activity.id}))
    # |> debug("result")
  end

  def feeds_for_activity(%{id: id}), do: feeds_for_activity(id)

  def feeds_for_activity(id) when is_binary(id) do
    repo().all(from(f in FeedPublish, where: f.activity_id == ^id, select: f.feed_id))
  end

  def feeds_for_activity(activity) do
    Logger.error("feeds_for_activity: dunno how to get feeds for #{inspect activity}")
    []
  end

  def my_feed(socket, cursor_after \\ nil, include_notifications? \\ true) do

    # feeds the user is following
    feed_ids = Feeds.my_home_feed_ids(socket, include_notifications?)
    # IO.inspect(my_home_feed_ids: feed_ids)

    feed(feed_ids, socket, cursor_after)
  end

  def feed(feed, current_user_or_socket_or_opts \\ [], preloads \\ :all)

  def feed(%{id: feed_id}, current_user_or_socket_or_opts, preloads), do: feed(feed_id, current_user_or_socket_or_opts, preloads)

  def feed(feed_id_or_ids, current_user_or_socket_or_opts, preloads) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do
    # IO.inspect(feed_id_or_ids: feed_id_or_ids)
    feed_id_or_ids = ulid(feed_id_or_ids)

    pubsub_subscribe(feed_id_or_ids, current_user_or_socket_or_opts) # subscribe to realtime feed updates

    query([feed_id: feed_id_or_ids], current_user_or_socket_or_opts)
    |> feed_paginated(current_user(current_user_or_socket_or_opts), current_user_or_socket_or_opts, preloads)
  end

  def feed(:notifications, current_user_or_socket_or_opts, preloads) do
    # current_user = current_user(current_user_or_socket)

    case Bonfire.Social.Feeds.my_feed_id(:inbox, current_user_or_socket_or_opts) do
      inbox when is_binary(inbox) or is_list(inbox) ->

        # inbox = ulid(inbox)
        # IO.inspect(query_notifications_feed_ids: feeds)

        pubsub_subscribe(inbox, current_user_or_socket_or_opts) # subscribe to realtime feed updates

        [feed_id: inbox] # FIXME: for some reason preloading creator or reply_to when we have a boost in inbox breaks ecto
        |> feed_paginated(current_user_or_socket_or_opts, preloads)

        e ->
          Logger.error("no feed for :notifications - #{e}")
          nil
    end

  end

  def feed(:flags, current_user_or_socket_or_opts, _preloads) do
    Bonfire.Social.Flags.list_paginated([], current_user_or_socket_or_opts)
  end

  def feed(feed_name, current_user_or_socket_or_opts, preloads) when is_atom(feed_name) do

    feed(Feeds.named_feed_id(feed_name), current_user_or_socket_or_opts, preloads)
  end

  def feed(%{feed_name: feed_name}, current_user_or_socket_or_opts, preloads) do

    feed(Feeds.named_feed_id(feed_name), current_user_or_socket_or_opts, preloads)
  end


  def feed(_, _, _, _), do: []


  @doc """
  Return a page of Feed Activities (reverse chronological) + pagination metadata
  """
  def feed_paginated(filters \\ [], current_user_or_socket_or_opts \\ [], preloads \\ :all, query \\ FeedPublish)

  def feed_paginated(filters, current_user_or_socket_or_opts, preloads, query) do
    paginate = e(current_user_or_socket_or_opts, :paginate, current_user_or_socket_or_opts)
    Logger.debug("feed_paginated with: #{inspect paginate}")
    query_paginated(filters, current_user_or_socket_or_opts, preloads, query)
      |> Bonfire.Repo.many_paginated(paginate)
  end


  def query_paginated(filters \\ [], current_user_or_socket_or_opts \\ [], preloads \\ :all, query \\ FeedPublish)

  def query_paginated(filters, current_user_or_socket_or_opts, preloads, query) when is_list(filters) do

    paginate = e(current_user_or_socket_or_opts, :paginate, current_user_or_socket_or_opts)

    # TODO: actually return a query with pagination filters
    query(filters, current_user_or_socket_or_opts, preloads, query)
  end

  def query_paginated(query, current_user_or_socket_or_opts, preloads, _query) do

    paginate = e(current_user_or_socket_or_opts, :paginate, current_user_or_socket_or_opts)

    # TODO: actually return a query with pagination filters
    query
  end

  def query(filters \\ [], current_user_or_socket_or_opts \\ [], preloads \\ :all, query \\ FeedPublish)

  # def query(filters, opts, preloads, query, true = _distinct)  do

  #   query(filters, opts, preloads, query, false)
  #     |> distinct([activity: activity], [desc: activity.id])
  # end

  def query([feed_id: feed_id_or_ids], current_user_or_socket_or_opts, preloads, query) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do
    # IO.inspect(feed_id_or_ids: feed_id_or_ids)
    feed_id_or_ids = ulid(feed_id_or_ids)

    # query FeedPublish, without messages
    [
      feed_id: feed_id_or_ids,
      # exclude: {:messages, &filter/3},
      # exclude_messages: dynamic([object_message: message], is_nil(message.id))
      # exclude private messages to avoid shoulder snoopers - access is controlled separately.
      exclude_messages: dynamic([object: object], object.table_id != ^("6R1VATEMESAGEC0MMVN1CAT10N"))
    ]
    |> query(current_user_or_socket_or_opts, preloads, query)
  end

  def query(filters, current_user_or_socket_or_opts, preloads, query) when is_list(filters) do

    Logger.debug("FeedActivities - query with filters: #{inspect filters}")

    query
      |> query_extras(current_user_or_socket_or_opts, preloads)
      |> query_filter(filters, nil, nil)
      # |> IO.inspect(label: "FeedActivities - query")
  end

  def query(filters, current_user_or_socket_or_opts, preloads, query) do
    query
      # |> query_extras(current_user, preloads)
      # |> query_filter(filters, nil, nil)
      |> IO.inspect(label: "FeedActivities invalid feed query with filters #{inspect filters}")
  end

  defp query_extras(query, current_user_or_socket_or_opts, preloads) do

    query
      # |> IO.inspect(label: "feed_paginated pre-preloads")
      # add assocs needed in timelines/feeds
      |> Activities.activity_preloads(current_user_or_socket_or_opts, preloads)
      # |> IO.inspect(label: "feed_paginated post-preloads")
      |> Activities.as_permitted_for(current_user_or_socket_or_opts)
      # |> IO.inspect(label: "feed_paginated post-boundaries")
      |> order_by([activity: activity], [desc: activity.id])
  end


  # def feed(%{feed_publishes: _} = feed_for, _) do
  #   repo().maybe_preload(feed_for, [feed_publishes: [activity: [:verb, :object, subject_user: [:profile, :character]]]]) |> Map.get(:feed_publishes)
  # end

  # def publish(subject, verb, object, preset) do
  #   if preset == "public" do
  #   else
  #   end
  # end

  @doc """
  Creates a new local activity and publishes to appropriate feeds
  """
  def publish(subject, verb, object, preset), do: publish(subject, verb, object, [], preset)

  def publish(subject, verb, object, circles, preset_boundary, mentions_and_tags_are_private? \\ true)

  def publish(subject, verb, object, circles, "mentions" = preset_boundary, mentions_and_tags_are_private?),
    do: publish(subject, verb, object, circles, mentions_and_tags_are_private?, true)

  def publish(subject, verb, object, circles, "local" = preset_boundary, _),
    # FIXME: we should still notify local members who are mentioned or replied to
    do: publish(subject, verb, object, circles, true, true)

  def publish(subject, verb, object, circles, "public" = preset_boundary, _),
    do: publish(subject, verb, object, circles, false, false)

  def publish(
    subject,
    verb,
    %{replied: %{reply_to_id: reply_to_id}} = object,
    circles,
    _,
    false = replies_are_private?
  ) when is_atom(verb) and is_list(circles) and is_binary(reply_to_id) do
    # publishing a reply to something, and notifying the character we're replying to
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

    circles = circles ++ [creator_id]

    # Bonfire.Me.Boundaries.maybe_make_visible_for(subject, object, circles) # |> IO.inspect(label: "grant")

    with {:ok, activity} <- do_publish(subject, verb, object, circles) do
      Logger.debug("FeedActivities published to: #{inspect circles}")
      Threads.maybe_push_thread(subject, activity, object)
      # IO.inspect(notify_reply: reply_to_creator)
      Logger.debug("FeedActivities with replies_are_private?==false -> notifying the user being replied to: #{inspect creator_id}")
      if creator_id != subject.id, do: notify_characters(subject, activity, object, reply_to_creator), else: {:ok, activity}
    end
  end

  def publish(subject, verb, %{tags: tags} = object, circles, false = mentions_and_tags_are_private?, _) when is_atom(verb) and is_list(tags) and length(tags) > 0 do
    # publishing and notifying anyone @ mentionned (and/or other tagged characters)
    # IO.inspect(publish_to_tagged: tags)
    mentioned_notifications_inboxes = Feeds.feed_ids(:inbox, tags) #|> IO.inspect(label: "publish tag / mention")
    tag_ids = circles ++ Bonfire.Tag.Tags.tag_ids(tags) # TODO? don't re-fetch tags
    Logger.debug("FeedActivities with mentions_and_tags_are_private?==false -> making visible for: #{inspect tag_ids}")
    # Bonfire.Me.Boundaries.maybe_make_visible_for(subject, object, tag_ids) # |> IO.inspect(label: "grant")
    feeds = circles ++ mentioned_notifications_inboxes
    with {:ok, activity} <- do_publish(subject, verb, object, feeds) do
      Logger.debug("FeedActivities with mentions_and_tags_are_private?==false -> putting in feed + notifications of @ mentioned / tagged characters: #{inspect feeds}")
      notify_inboxes(subject, activity, object, mentioned_notifications_inboxes)
    end
  end

  def publish(subject, verb, object, circles, tags_are_private?, replies_are_private?) when not is_list(circles) do
    publish(subject, verb, object, [circles], tags_are_private?, replies_are_private?)
  end

  def publish(subject, verb, object, circles, _, _) when is_atom(verb) do
    # Logger.debug("FeedActivities: just making visible for and putting in these circles/feeds: #{inspect circles}")
    # Bonfire.Me.Boundaries.maybe_make_visible_for(subject, object, circles) # |> IO.inspect(label: "grant")
    do_publish(subject, verb, object, circles)
  end

  def publish(subject, verb, object, circles, tags_are_private?, replies_are_private?) do
    Logger.debug("FeedActivities: defaulting to a :create activity, because this verb is not defined: #{inspect verb} ")
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
    publish(subject, verb, object, Feeds.named_feed_id(:activity_pub))
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
      Logger.debug("maybe_notify_creator: #{inspect object_creator_id}")
      notify_characters(subject, verb_or_activity, object, object_creator)
    else
      Logger.debug("maybe_notify_creator: just create an activity")
      maybe_feed_publish(subject, verb_or_activity, object, nil)
    end
    # TODO: notify remote users via AP
  end


  @doc """
  Creates a new local activity or takes an existing one and publishes to object's inbox (if object is an actor)
  """
  def notify_characters(subject, verb_or_activity, object, characters) do
    debug(characters)
    notify_inboxes(subject, verb_or_activity, object, Feeds.feed_ids(:inbox, characters) |> Utils.filter_empty())
  end

  def notify_inboxes(subject, verb_or_activity, object, inbox_ids) do
    debug(inbox_ids)
    Bonfire.Notifications.notify_users(inbox_ids, e(subject, :profile, :name, e(subject, :character, :username, nil)), e(object, :post_content, :name, e(object, :post_content, :html_body, nil)))

    maybe_feed_publish(subject, verb_or_activity, object, inbox_ids) #|> IO.inspect(label: "notify_feeds")
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
    inboxes = Feeds.admins_inboxes()
    Logger.debug("notify_admins: #{inspect inboxes}")
    maybe_feed_publish(subject, verb_or_activity, object, inboxes)
    # TODO: notify remote users via AP
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to specified feeds
  """
  def maybe_feed_publish(subject, verb_or_activity, object \\ nil, feeds)
  def maybe_feed_publish(subject, verb, object, feeds) when is_atom(verb), do: create_and_put_in_feeds(subject, verb, object, feeds)
  def maybe_feed_publish(_subject, %Bonfire.Data.Social.Activity{} = activity, _, feeds) do
    put_in_feeds_and_maybe_federate(feeds, activity)
    {:ok, activity}
    # TODO: notify remote users via AP
  end
  def maybe_feed_publish(subject, %{activity: %{id: _} = activity}, _, feeds), do: maybe_feed_publish(subject, activity, feeds)
  def maybe_feed_publish(subject, %{activity: _activity_not_loaded} = parent, _, feeds), do: maybe_feed_publish(subject, parent |> repo().maybe_preload(:activity) |> e(:activity, nil), feeds)
  def maybe_feed_publish(_, activity, _, _) do
    Logger.error("FeedActivities.maybe_feed_publish: did not put in feeds or federate, expected an Activity or a Verb+Object, got #{inspect activity}")
    {:ok, activity}
  end



  defp create_and_put_in_feeds(subject, verb, object, feed_id) when is_map(object) and is_binary(feed_id) or is_list(feed_id) do
    with {:ok, activity} <- Activities.create(subject, verb, object) do
      with {:ok, published} <- put_in_feeds_and_maybe_federate(feed_id, activity) do # publish in specified feed
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
    # for activities with no target feed, still create the activity and push it to AP
    ret = Activities.create(subject, verb, object)
    try do
      # FIXME only run if ActivityPub is a target circle/feed?
      # TODO: only run for non-local activity
        {:ok, activity} = ret
        maybe_federate_activity(activity)

        ret
      rescue
        _ -> ret
      end
  end

  defp maybe_index_activity(subject, verb, object) do
    Activities.create(subject, verb, object)
    # ~> maybe_index(activity) # TODO, indexing here?
  end

  defp put_in_feeds_and_maybe_federate(feeds, activity) do
    # This makes sure it gets put in feed even if the
    # federation hook fails
    feeds = feeds |> Utils.filter_empty()
    ret = put_in_feeds(feeds, activity)
    # TODO: add ActivityPub feed for remote activities
    try do
    # FIXME only run if ActivityPub is a target circle/feed?
    # TODO: only run for non-local activity
      maybe_federate_activity(activity)
      ret
    rescue
      _ -> ret
    end
  end

  defp put_in_feeds(feeds, activity) when is_list(feeds), do: feeds |> Circles.circle_ids() |> Enum.map(fn x -> put_in_feeds(x, activity) end) # TODO: optimise?

  defp put_in_feeds(feed_or_subject, activity) when is_map(feed_or_subject) or (is_binary(feed_or_subject) and feed_or_subject !="") do
    with feed_id <- ulid(feed_or_subject),
    {:ok, published} <- do_put_in_feeds(feed_id, ulid(activity)) do

      published = %{published | activity: activity}

      pubsub_broadcast(feed_id, {{Bonfire.Social.Feeds, :new_activity}, activity}) # push to online users

      {:ok, published}
    else e ->
      Logger.error("FeedActivities.put_in_feeds: error when trying with feed_or_subject: #{inspect e}")
      {:ok, nil}
    end
  end
  defp put_in_feeds(_, _) do
    Logger.error("FeedActivities: did not put_in_feeds")
    {:ok, nil}
  end

  defp do_put_in_feeds(feed, activity) when is_binary(activity) and is_binary(feed) do
    attrs = %{feed_id: (feed), activity_id: (activity)}
    repo().put(FeedPublish.changeset(attrs))
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_for_object(%{id: id}), do: delete_for_object(id)
  def delete_for_object(id) when is_binary(id) and id !="", do: FeedPublish |> query_filter(activity_id: id) |> repo().delete_many() |> elem(1)
  def delete_for_object(ids) when is_list(ids), do: Enum.each(ids, fn x -> delete_for_object(x) end)
  def delete_for_object(_), do: nil


  def maybe_federate_activity(activity) do
    verb = Verbs.get!(activity.verb_id).verb
    Bonfire.Social.Integration.activity_ap_publish(activity.subject_id, verb, activity)
  end


end
