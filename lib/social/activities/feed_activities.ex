defmodule Bonfire.Social.FeedActivities do
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo
  import Where
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Data.Social.{Activity, FeedPublish, Feed, PostContent}
  alias Bonfire.Data.Identity.{Character, User}
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Activities
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Threads

  def queries_module, do: FeedPublish
  def context_module, do: FeedPublish

  def cast_data(changeset, activity, creator, preset_or_custom_boundary) do
    Feeds.target_feeds(changeset, creator, preset_or_custom_boundary)
    # |> debug("feeds")
    |> Enum.map(&(%{feed_id: &1, activity_id: activity.id}))
    # |> debug("result")
  end

  def feeds_for_activity(%{id: id}), do: feeds_for_activity(id)

  def feeds_for_activity(id) when is_binary(id) do
    repo().all(from(f in FeedPublish, where: f.activity_id == ^id, select: f.feed_id))
  end

  def feeds_for_activity(activity) do
    error("feeds_for_activity: dunno how to get feeds for #{inspect activity}")
    []
  end

  def my_feed(socket_and_or_opts) do

    # feeds the user is following
    feed_ids = Feeds.my_home_feed_ids(socket_and_or_opts)
    # |> debug()
    |> feed(socket_and_or_opts)
  end

  def feed(feed, current_user_or_socket_or_opts \\ [])

  def feed(%{id: feed_id}, current_user_or_socket_or_opts), do: feed(feed_id, current_user_or_socket_or_opts)

  def feed([feed_id], current_user_or_socket_or_opts), do: feed(feed_id, current_user_or_socket_or_opts)

  def feed(feed_id_or_ids, current_user_or_socket_or_opts) when is_binary(feed_id_or_ids) or ( is_list(feed_id_or_ids) and length(feed_id_or_ids)>0) do
    feed_id_or_ids = ulid(feed_id_or_ids)

    pubsub_subscribe(feed_id_or_ids, current_user_or_socket_or_opts) # subscribe to realtime feed updates

    query([feed_id: feed_id_or_ids], current_user_or_socket_or_opts)
    |> feed_paginated(current_user_or_socket_or_opts)
  end

  def feed(:flags, current_user_or_socket_or_opts) do
    Bonfire.Social.Flags.list_paginated([], current_user_or_socket_or_opts)
  end

  def feed(feed_name, current_user_or_socket_or_opts) when is_atom(feed_name) and not is_nil(feed_name) do
    # current_user = current_user(current_user_or_socket)
    # debug(current_user_or_socket_or_opts)
    case Feeds.named_feed_id(feed_name) || Bonfire.Social.Feeds.my_feed_id(feed_name, current_user_or_socket_or_opts) do
      feed when is_binary(feed) or is_list(feed) ->
        debug(ulid(current_user(current_user_or_socket_or_opts)), "current_user")
        debug(feed_name, "feed_name")
        debug(feed, "feed_id")
        pubsub_subscribe(feed, current_user_or_socket_or_opts) # subscribe to realtime feed updates

        [feed_id: ulid(feed)]
        |> feed_paginated(current_user_or_socket_or_opts)

        e ->
          error("FeedActivities.feed: no known feed #{inspect feed_name} - #{inspect e}")
          debug(current_user_or_socket_or_opts)
          nil
    end
  end

  def feed(other, _) do
    error("FeedActivities.feed: not a recognised feed query format - got #{inspect other}")
    []
  end


  @doc """
  Return a page of Feed Activities (reverse chronological) + pagination metadata
  """
  def feed_paginated(filters \\ [], current_user_or_socket_or_opts \\ [], query \\ FeedPublish)

  def feed_paginated(filters, current_user_or_socket_or_opts, query) do
    paginate = e(current_user_or_socket_or_opts, :paginate, nil) || e(current_user_or_socket_or_opts, :after, nil)
    debug("feed_paginated filters: #{inspect filters} paginate: #{inspect paginate}")
    query_paginated(filters, current_user_or_socket_or_opts, query)
    |> dump
    |> Bonfire.Repo.many_paginated(paginate)
    # |> debug()
  end


  def query_paginated(filters \\ [], current_user_or_socket_or_opts \\ [], query \\ FeedPublish)

  def query_paginated(filters, current_user_or_socket_or_opts, query) when is_list(filters) do

    paginate = e(current_user_or_socket_or_opts, :paginate, current_user_or_socket_or_opts)

    # TODO: actually return a query with pagination filters
    query(filters, current_user_or_socket_or_opts, query)
  end

  def query_paginated(query, current_user_or_socket_or_opts, _query) do

    paginate = e(current_user_or_socket_or_opts, :paginate, current_user_or_socket_or_opts)

    # TODO: actually return a query with pagination filters
    query
  end

  def query(filters \\ [], current_user_or_socket_or_opts \\ [], query \\ FeedPublish)

  # def query(filters, opts, query, true = _distinct)  do

  #   query(filters, opts, query, false)
  #     |> distinct([activity: activity], [desc: activity.id])
  # end

  def query([feed_id: feed_id_or_ids], current_user_or_socket_or_opts, query) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do
    # debug(feed_id_or_ids: feed_id_or_ids)
    feed_id_or_ids = ulid(feed_id_or_ids)

    # query FeedPublish, without messages
    [
      feed_id: feed_id_or_ids,
      # exclude: {:messages, &filter/3},
      # exclude_messages: dynamic([object_message: message], is_nil(message.id))
      # exclude private messages to avoid shoulder snoopers - access is controlled separately.
      exclude_messages: dynamic([object: object], object.table_id != ^("6R1VATEMESAGEC0MMVN1CAT10N"))
    ]
    |> query(current_user_or_socket_or_opts, query)
  end

  def query(filters, current_user_or_socket_or_opts, query) when is_list(filters) do

    debug("FeedActivities - query with filters: #{inspect filters}")

    query
      |> query_extras(current_user_or_socket_or_opts)
      |> query_filter(filters, nil, nil)
      # |> debug(label: "FeedActivities - query")
  end

  def query(filters, current_user_or_socket_or_opts, query) do
    query
      # |> query_extras(current_user)
      # |> query_filter(filters, nil, nil)
      |> debug(label: "FeedActivities invalid feed query with filters #{inspect filters}")
  end

  defp query_extras(query, current_user_or_socket_or_opts) do

    query
      # |> debug(label: "feed_paginated pre-preloads")
      # add assocs needed in timelines/feeds
      |> Activities.activity_preloads(current_user_or_socket_or_opts, e(current_user_or_socket_or_opts, :preloads, :all))
      # |> debug(label: "feed_paginated post-preloads")
      |> Activities.as_permitted_for(current_user_or_socket_or_opts)
      # |> debug(label: "feed_paginated post-boundaries")
      |> order_by([activity: activity], [desc: activity.id])
  end


  # def feed(%{feed_publishes: _} = feed_for, _) do
  #   repo().maybe_preload(feed_for, [feed_publishes: [activity: [:verb, :object, subject_user: [:profile, :character]]]]) |> Map.get(:feed_publishes)
  # end

  @doc """
  Creates a new local activity and publishes to appropriate feeds
  """

  def publish(subject, verb_or_activity, object, preset_or_custom_boundary \\ nil) when is_atom(verb_or_activity) or is_struct(verb_or_activity) do
    # debug("FeedActivities: just making visible for and putting in these circles/feeds: #{inspect circles}")
    # Bonfire.Boundaries.maybe_make_visible_for(subject, object, circles) # |> debug(label: "grant")
    Feeds.target_feeds(the_object(object), subject, preset_or_custom_boundary)
    |>
    maybe_feed_publish(subject, verb_or_activity, object, ...)
  end

  def publish(subject, verb, object, circles) do
    debug("FeedActivities: defaulting to a :create activity, because this verb is not defined: #{inspect verb} ")
    publish(subject, :create, object, circles)
  end


  @doc """
  Records a remote activity and puts in appropriate feeds
  """
  def save_fediverse_incoming_activity(subject, verb, object) when is_atom(verb) do
    # TODO: us the appropriate preset, eg "public" for public activities
    publish(subject, verb, object, boundary: "local", to_feeds: [Feeds.named_feed_id(:activity_pub)])
  end

  @doc """
  Takes or creates an activity and publishes to object creator's inbox
  """
  def maybe_notify_creator(subject, %{activity: %{id: _} = activity}, object), do: maybe_notify_creator(subject, activity, object)
  def maybe_notify_creator(subject, verb_or_activity, object) do
    the_object = Objects.preload_creator(the_object(object))
    object_creator = Objects.object_creator(the_object)
    if ulid(object_creator) && ulid(subject) != ulid(object_creator) do
      notify_characters(subject, verb_or_activity, object, [object_creator])
    else
      debug("maybe_notify_creator: no creator found, so just create an activity")
      publish(subject, verb_or_activity, object)
    end
    # TODO: notify remote users via AP
  end


  @doc """
  Creates a new local activity or takes an existing one and publishes to object's inbox (if object is an actor)
  """
  def notify_characters(subject, verb_or_activity, object, characters) do
    # TODO: notify remote users via AP?
    # debug(characters)
    Feeds.feed_ids(:notifications, characters)
    |> Utils.filter_empty([])
    |> notify_feeds(subject, verb_or_activity, object, ...)
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to object's inbox (assuming object is a character)
  """
  def notify_object(subject, verb_or_activity, object) do
    notify_characters(subject, verb_or_activity, object, [the_object(object)])
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to creator's inbox
  """
  def notify_admins(subject, verb_or_activity, object) do
    inboxes = Feeds.admins_notifications()
    # |> debug()
    notify_feeds(subject, verb_or_activity, object, inboxes)
  end

  # if the user has provided a non-nil value for `notify_admins`, query them.
  # defp maybe_fetch_admins([]), do: []
  # defp maybe_fetch_admins(nil), do: []
  # defp maybe_fetch_admins(_), do: Users.admins()
  #
  # def notificate(subject, verb_or_activity, object, opts) do
  #   # the user may directly provide feed ids if they wish. we may add to them.
  #   feeds = Keyword.get(opts, :to_feeds, [])
  #   # if the user provided :admins, it should be a feed name or names for them
  #   admins = Feeds.feed_ids(opts[:admins], maybe_fetch_admins(opts[:admins]))
  #   # for each of the supported feed names, get the relevant box ids
  #   inboxes = Feeds.feed_ids(:inbox, Keyword.get(opts, :inboxes, []))
  #   outboxes = Feeds.feed_ids(:outbox, Keyword.get(opts, :outboxes, []))
  #   notifications = Feeds.feed_ids(:notifications, Keyword.get(opts, :inboxes, []))
  #   # first, we must publish to all of these feeds
  #   all = List.flatten([feeds, admins, inboxes, outboxes, notifications])
  #   ret = publish(subject, verb_or_activity, object, all)
  #   # Now post some notifications to the pubsub for live data updates.
  #   Bonfire.Social.LivePush.notify(subject, Activities.verb(verb_or_activity), object, inboxes)
  # end


  def notify_feeds(subject, verb_or_activity, object, feed_ids) do
    # debug(feed_ids)

    ret = publish(subject, verb_or_activity, object, to_feeds: feed_ids) #|> debug(label: "notify_feeds")
    Bonfire.Social.LivePush.notify(subject, Activities.verb(verb_or_activity), object, feed_ids)
    ret
  end


  @doc """
  Creates a new local activity or takes an existing one and publishes to specified feeds
  """
  defp maybe_feed_publish(subject, verb_or_activity, object \\ nil, feeds)
  defp maybe_feed_publish(subject, verb, object, feeds) when is_atom(verb), do: create_and_put_in_feeds(subject, verb, object, feeds)
  defp maybe_feed_publish(subject, %Bonfire.Data.Social.Activity{} = activity, object, feeds) do
    put_in_feeds_and_maybe_federate(feeds, subject, activity.verb.verb, object, activity)
    {:ok, activity}
    # TODO: notify remote users via AP
  end
  defp maybe_feed_publish(subject, %{activity: %{id: _} = activity}, _, feeds), do: maybe_feed_publish(subject, activity, feeds)
  defp maybe_feed_publish(subject, %{activity: _activity_not_loaded} = parent, _, feeds), do: maybe_feed_publish(subject, parent |> repo().maybe_preload(:activity) |> e(:activity, nil), feeds)
  defp maybe_feed_publish(_, activity, _, _) do
    error("maybe_feed_publish: did not put in feeds or federate, expected an Activity or a Verb+Object, got #{inspect activity}")
    {:ok, activity}
  end


  defp create_and_put_in_feeds(subject, verb, object, feed_id) when is_map(object) and is_binary(feed_id) or is_list(feed_id) do
    with {:ok, activity} <- Activities.create(subject, verb, object) do
      with {:ok, published} <- put_in_feeds_and_maybe_federate(feed_id, subject, verb, object, activity) do # publish in specified feed
        # debug(published, "create_and_put_in_feeds")
        {:ok, activity}
      else # meh
        publishes when is_list(publishes) and length(publishes)>0 -> {:ok, activity}
        _ ->
          warn("did not create_and_put_in_feeds: #{inspect feed_id}")
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
        maybe_federate_activity(verb, object, activity)

        ret
      rescue
        _ -> ret
      end
  end

  defp put_in_feeds_and_maybe_federate(feeds, _subject, verb, object, activity) do
    # This makes sure it gets put in feed even if the
    # federation hook fails
    feeds = feeds |> Utils.filter_empty([])
    ret = put_in_feeds(feeds, activity)
    # TODO: add ActivityPub feed for remote activities
    try do
    # FIXME only run if ActivityPub is a target circle/feed?
    # TODO: only run for non-local activity
        maybe_federate_activity(verb, object, activity)
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

      Bonfire.Social.LivePush.push_activity(feed_id, activity) # push to feeds of online users

      {:ok, published}
    else e ->
      error("FeedActivities.put_in_feeds: error when trying with feed_or_subject: #{inspect e}")
      {:ok, nil}
    end
  end
  defp put_in_feeds(_, _) do
    error("FeedActivities: did not put_in_feeds")
    {:ok, nil}
  end

  defp do_put_in_feeds(feed, activity) when is_binary(activity) and is_binary(feed) do
    attrs = %{feed_id: (feed), activity_id: (activity)}
    repo().put(FeedPublish.changeset(attrs))
  end

  def the_object({%{} = object, _mixin_object}), do: object
  def the_object(object), do: object

  @doc "Delete an activity (usage by things like unlike)"
  def delete_for_object(%{id: id}), do: delete_for_object(id)
  def delete_for_object(id) when is_binary(id) and id !="", do: FeedPublish |> query_filter(activity_id: id) |> repo().delete_many() |> elem(1)
  def delete_for_object(ids) when is_list(ids), do: Enum.each(ids, fn x -> delete_for_object(x) end)
  def delete_for_object(_), do: nil


  defp maybe_federate_activity(verb, object, activity) do
    Bonfire.Social.Integration.activity_ap_publish(activity.subject_id, verb, object, activity)
  end
end
