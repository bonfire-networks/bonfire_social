defmodule Bonfire.Social.FeedActivities do
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo
  import Ecto.Query
  import Where
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Data.Social.{Activity, FeedPublish, Feed, Message, PostContent}
  alias Bonfire.Data.Identity.{Character, User}
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Activities
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Threads
  alias Pointers
  alias Pointers.{Pointer, Changesets}

  def queries_module, do: FeedPublish
  def context_module, do: FeedPublish

  def cast(changeset, creator, opts) do
    Feeds.target_feeds(changeset, creator, opts)
    |> cast(changeset, ...)
  end

  def cast(changeset, feed_ids) do
    Enum.map(feed_ids, &(%{feed_id: &1}))
    |> Changesets.put_assoc(changeset, :feed_publishes, ...)
  end

  @doc """
  Gets a list of feed ids this activity was published to from the database.

  Currently only used by the ActivityPub integration.
  """
  def feeds_for_activity(%{id: id}), do: feeds_for_activity(id)
  def feeds_for_activity(id) when is_binary(id) do
    repo().all(from(f in FeedPublish, where: f.id == ^id, select: f.feed_id))
  end
  def feeds_for_activity(activity) do
    error("feeds_for_activity: dunno how to get feeds for #{inspect activity}")
    []
  end

  @doc """
  Gets a user's home feed, a combination of all feeds the user is subscribed to.
  """
  def my_feed(opts), do: feed(Feeds.my_home_feed_ids(opts), opts)

  @doc """
  Gets a feed by id or ids or a thing/things containing an id/ids.
  """
  def feed(feed, opts \\ [])
  def feed(%{id: feed_id}, opts), do: feed(feed_id, opts)
  def feed([feed_id], opts), do: feed(feed_id, opts)
  def feed(id_or_ids, opts)
  when is_binary(id_or_ids) or (is_list(id_or_ids) and id_or_ids != []) do
    feed_id_or_ids = ulid(id_or_ids)
    paginate = e(opts, :paginate, nil) || e(opts, :after, nil)
    pubsub_subscribe(feed_id_or_ids, opts) # subscribe to realtime feed updates
    base_feed_query(feed_id_or_ids)
    |> query_extras(opts)
    |> repo.many_paginated(paginate)
  end
  def feed(:flags, opts), do: Bonfire.Social.Flags.list_paginated([], opts)
  def feed(:notifications = feed_name, opts), do: do_feed(feed_name, opts ++ [skip_boundary_check: :admins])
  def feed(feed_name, opts) when is_atom(feed_name) and not is_nil(feed_name) do
    do_feed(feed_name, opts)
  end

  def feed(other, _) do
    error(other, "FeedActivities.feed: not a recognised feed query param")
    nil
  end

  defp do_feed(feed_name, opts) when is_atom(feed_name) and not is_nil(feed_name) do
    paginate = e(opts, :paginate, nil) || e(opts, :after, nil)
    # current_user = current_user(current_user_or_socket)
    # debug(opts)
    case Feeds.named_feed_id(feed_name) || Bonfire.Social.Feeds.my_feed_id(feed_name, opts) do
      feed when is_binary(feed) or is_list(feed) ->
        # debug(ulid(current_user(opts)), "current_user")
        # debug(feed_name, "feed_name")
        # debug(feed, "feed_id")
        pubsub_subscribe(feed, opts) # subscribe to realtime feed updates
        base_feed_query(feed)
        |> query_extras(opts)
        |> repo.many_paginated(paginate)
    e ->
        error("FeedActivities.feed: no known feed #{inspect feed_name} - #{inspect e}")
        debug(opts)
        nil
    end
  end

  def user_feed(user, feed_name, opts \\ []) do
    paginate = e(opts, :paginate, nil) || e(opts, :after, nil)
    opts = Keyword.put_new(opts, :current_user, user)
    id = Feeds.named_feed_id(feed_name) ||
      Bonfire.Social.Feeds.my_feed_id(feed_name, user)
    base_feed_query(id)
    |> query_extras(opts)
    |> repo().many_paginated(paginate)
  end

  @doc """
  Return a page of Feed Activities (reverse chronological) + pagination metadata
  """
  def feed_paginated(filters \\ [], opts \\ []) do
    feed_paginated(filters, opts, default_query())
  end

  def feed_paginated(filters, opts, query) do
    paginate = e(opts, :paginate, nil) || e(opts, :after, nil)
    debug("feed_paginated filters: #{inspect filters} paginate: #{inspect paginate}")
    query_paginated(filters, opts, query)
    # |> dump
    |> repo().many_paginated(paginate)
    # |> debug()
  end

  defp default_query(), do: select(Pointers.undeleted(), [p], p)

  defp base_feed_query(feed_ids) do
    feed_ids = List.wrap(ulid(feed_ids))
    message = Message.__pointers__(:table_id)
    feeds = from fp in FeedPublish,
      where: fp.feed_id in ^feed_ids,
      group_by: fp.id,
      select: %{id: fp.id, dummy: count(fp.feed_id)}
    from p in Pointer,
      join: fp in subquery(feeds),
      on: p.id == fp.id,
      order_by: [desc: p.id],
      where: is_nil(p.deleted_at),   # Don't show anything deleted
      where: p.table_id != ^message  # private messages should never appear in feeds
  end


  def query_paginated(query_or_filters \\ [], opts \\ [])
  def query_paginated(filters, opts) when is_list(filters) do
  #   feed_i
  #   query_paginated(base_
    query(filters, opts)
  end
  def query_paginated(filters, opts, query) when is_list(filters) do
    # paginate = e(opts, :paginate, opts)
    # TODO: actually return a query with pagination filters
    query(filters, opts, query)
  end

  def query_paginated(query, opts, _query) do
    # paginate = e(opts, :paginate, opts)
    # TODO: actually return a query with pagination filters
    query
  end

  def query(filters \\ [], opts \\ []), do: query(filters, opts, default_query())
  # def query(filters, opts, query, true = _distinct)  do
  #   query(filters, opts, query, false)
  #     |> distinct([activity: activity], [desc: activity.id])
  # end

  def query([feed_id: feed_id_or_ids], opts) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do
    # debug(feed_id_or_ids: feed_id_or_ids)
    base_feed_query(feed_id_or_ids)
    query([], opts, query)
  end

  def query(filters, opts, query) when is_list(filters) do
    query
      |> query_extras(opts)
      |> query_filter(filters, nil, nil)
      # |> debug("FeedActivities - query")
  end

  def query(filters, opts, query) do
    query
    # |> query_extras(current_user)
    # |> query_filter(filters, nil, nil)
    |> warn("invalid feed query with filters #{inspect filters}")
  end

  @doc false # add assocs needed in timelines/feeds
  def query_extras(query, opts) do
    query
    # |> debug("feed_paginated pre-preloads")
    # add assocs needed in timelines/feeds
    |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
    # |> debug("feed_paginated post-preloads")
    |> Activities.as_permitted_for(opts)
  end

  # def feed(%{feed_publishes: _} = feed_for, _) do
  #   repo().maybe_preload(feed_for, [feed_publishes: [activity: [:verb, :object, subject_user: [:profile, :character]]]]) |> Map.get(:feed_publishes)
  # end

  @doc """
  Creates a new local activity and publishes to appropriate feeds
  """
  def publish(subject, verb_or_activity, object, opts \\ [])
  when is_atom(verb_or_activity) or is_struct(verb_or_activity) do
    # debug("FeedActivities: just making visible for and putting in these circles/feeds: #{inspect circles}")
    # Bonfire.Boundaries.maybe_make_visible_for(subject, object, circles) # |> debug("grant")
    Feeds.target_feeds(the_object(object), subject, opts)
    |> maybe_feed_publish(subject, verb_or_activity, object, ..., opts)
  end

  def publish(subject, verb, object, opts) do
    debug(verb, "Undefined verb, changing to :create")
    publish(subject, :create, object, opts)
  end

  @doc """
  Records a remote activity and puts in appropriate feeds
  """
  def save_fediverse_incoming_activity(subject, verb, object) when is_atom(verb) and not is_nil(subject) do
    # TODO: use the appropriate preset (eg "public" for public activities?)
    publish(subject, verb, object, boundary: "federated")
  end

  @doc """
  Takes or creates an activity and publishes to object creator's inbox
  """
  def maybe_notify_creator(subject, %{activity: %{id: _} = activity}, object),
    do: maybe_notify_creator(subject, activity, object)
  def maybe_notify_creator(subject, verb_or_activity, object) do
    the_object = Objects.preload_creator(the_object(object))
    object_creator = Objects.object_creator(the_object)
    if ulid(object_creator) && ulid(subject) != ulid(object_creator) do
      notify_characters(subject, verb_or_activity, object, [object_creator])
    else
      debug("no creator found, just creating an activity")
      publish(subject, verb_or_activity, object)
    end
    # TODO: notify remote users via AP
  end

  @doc """
  Arranges for an insert changeset to also publish to feeds related to some objects.

  Options:
  * `:inbox` - list of objects whose inbox we should attempt to insert into
  * `:outbox` - list of objects whose outbox we should attempt to insert into
  * `:notifications` - list of objects whose notifications we should attempt to insert into
  """
  def put_feed_publishes(changeset, options) do
    get_feed_publishes(options)
    |> Changesets.put_assoc(changeset, :feed_publishes, ...)
  end

  @doc """
  Creates the underlying data for `put_feed_publishes/2`.

  Options:
  * `:inbox` - list of objects whose inbox we should attempt to insert into.
  * `:outbox` - list of objects whose outbox we should attempt to insert into.
  * `:notifications` - list of objects whose notifications we should attempt to insert into.
  * `:feeds` - list of ids (or objects containing IDs of feeds to post to.
  """
  def get_feed_publishes(options) do
    keys = [:inbox, :outbox, :notifications]
    # process all the specifications
    options = get_feed_publishes_options(options)
    # build an index to look up the feed types by id
    index = get_feed_publishes_index(options, keys)
    # preload them all together
    all = Enum.flat_map(keys, &Keyword.get(options, &1, []))
    loaded = repo().maybe_preload(all, :character)
    # and finally, look up the appropriate feed from the loaded characters
    ids = for(character <- loaded, feed <- index[ulid(character)], do: Feeds.feed_id(feed, character))
    (ids ++ Keyword.get(options, :feeds, []))
    # Dedupe
    |> MapSet.new()
    |> MapSet.delete(nil)
    # turn into attrs
    |> Enum.map(&(%FeedPublish{feed_id: &1}))
  end

  defp get_feed_publishes_options(options) do
    for item <- options, reduce: %{} do
      acc ->
        case item do
          # named feeds should be collated together
          {:inbox, item_or_items} ->
            items = List.wrap(item_or_items)
            Map.update(acc, :inbox, items, &(items ++ &1))
          {:outbox, item_or_items} ->
            items = List.wrap(item_or_items)
            Map.update(acc, :outbox, items, &(items ++ &1))
          {:notifications, item_or_items} ->
            items = List.wrap(item_or_items)
            Map.update(acc, :notifications, items, &(items ++ &1))
          {:feed, item_or_items} ->
            Enum.reduce(List.wrap(item_or_items), acc, &put_feed_publish_item/2)
          # Loose things are assumed to be :feed
          _ -> put_feed_publish_item(item, acc)
        end
    end
    # filter nils
    |> Enum.map(fn {k, v} -> {k, Enum.reject(v, &is_nil/1)} end)
  end

  defp put_feed_publish_item(item, acc) do
    case item do
      nil ->
        acc
      _ when is_atom(item) ->
        items = [Feeds.named_feed_id(item)]
        Map.update(acc, :feeds, items, &(items ++ &1))
      _ when is_binary(item) ->
        Map.update(acc, :feeds, [item], &[item | &1])
      %_{id: id} ->
        Map.update(acc, :feeds, [id], &[id | &1])
      _ ->
        error(item, "Not sure what to do with")
        acc
    end
  end


  # builds an index of object ids to the names of the feeds we should query for them
  defp get_feed_publishes_index(options, keys) do
    for k <- keys,
        v <- Keyword.get(options, k, []),
        reduce: %{} do
      acc ->
        id = ulid(v)
        Map.update(acc, id, [k], &[k | &1])
    end
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes
  to object's notifications (if object is an actor)
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

  def notify_feeds(subject, verb_or_activity, object, feed_ids) do
    # debug(feed_ids)
    ret = publish(subject, verb_or_activity, object, to_feeds: feed_ids) #|> debug("notify_feeds")
    Bonfire.Social.LivePush.notify(subject, Activities.verb(verb_or_activity), object, feed_ids)
    ret
  end

  @doc """
  Creates a new local activity or takes an existing one and publishes to specified feeds
  """
  defp maybe_feed_publish(subject, verb_or_activity, object, feeds, opts \\ [])
  defp maybe_feed_publish(subject, verb, object, feeds, opts) when is_atom(verb), do: create_and_put_in_feeds(subject, verb, object, feeds, opts)
  defp maybe_feed_publish(subject, %Bonfire.Data.Social.Activity{} = activity, object, feeds, opts) do
    put_in_feeds_and_maybe_federate(feeds, subject, activity.verb.verb, object, activity, opts)
    {:ok, activity}
    # TODO: notify remote users via AP
  end
  defp maybe_feed_publish(subject, %{activity: %{id: _} = activity}, _, feeds, opts), do: maybe_feed_publish(subject, activity, nil, feeds, opts)
  defp maybe_feed_publish(subject, %{activity: _activity_not_loaded} = parent, _, feeds, opts), do: maybe_feed_publish(subject, parent |> repo().maybe_preload(:activity) |> e(:activity, nil), nil, feeds, opts)
  defp maybe_feed_publish(_, activity, _, _, _) do
    error("maybe_feed_publish: did not put in feeds or federate, expected an Activity or a Verb+Object, got #{inspect activity}")
    {:ok, activity}
  end


  defp create_and_put_in_feeds(subject, verb, object, feed_id, opts) when is_map(object) and is_binary(feed_id) or is_list(feed_id) do
    with {:ok, activity} <- Activities.create(subject, verb, object) do
      with {:ok, published} <- put_in_feeds_and_maybe_federate(feed_id, subject, verb, object, activity, opts) do # publish in specified feed
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
  defp create_and_put_in_feeds(subject, verb, object, %{feed_id: feed_id}, opts), do: create_and_put_in_feeds(subject, verb, object, feed_id, opts)
  defp create_and_put_in_feeds(subject, verb, object, _, opts) when is_map(object) do
    # for activities with no target feed, still create the activity and push it to AP
    ret = Activities.create(subject, verb, object)
    try do
      # FIXME only run if ActivityPub is a target circle/feed?
      # TODO: only run for non-local activity
        {:ok, activity} = ret
        maybe_federate_activity(verb, object, activity, opts)

        ret
      rescue
        e ->
          error(__STACKTRACE__, inspect e)
          ret
      end
  end

  defp put_in_feeds_and_maybe_federate(feeds, _subject, verb, object, activity, opts) do
    # This makes sure it gets put in feed even if the
    # federation hook fails
    feeds = feeds |> Utils.filter_empty([])
    ret = put_in_feeds(feeds, activity)
    # TODO: add ActivityPub feed for remote activities
    try do
    # FIXME only run if ActivityPub is a target circle/feed?
    # TODO: only run for non-local activity
        maybe_federate_activity(verb, object, activity, opts)
      ret
    rescue
      e ->
        error(__STACKTRACE__, inspect e)
        ret
    end
  end


  defp put_in_feeds(feeds, activity) when is_list(feeds) do
    feeds
    |> Circles.circle_ids() # ????
    |> Enum.map(fn x -> put_in_feeds(x, activity) end) # TODO: optimise?
  end

  defp put_in_feeds(feed_or_subject, activity)
  when is_map(feed_or_subject) or (is_binary(feed_or_subject) and feed_or_subject !="") do
    with feed_id <- ulid(feed_or_subject),
    {:ok, published} <- do_put_in_feeds(feed_id, ulid(activity)) do
      Bonfire.Social.LivePush.push_activity(feed_id, activity) # push to feeds of online users
      {:ok, Map.put(published, :activity, activity)}
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
    repo().insert(%FeedPublish{feed_id: feed, id: activity})
  end

  def the_object({%{} = object, _mixin_object}), do: object
  def the_object(object), do: object


  @doc "Delete an activity (usage by things like unlike)"
  def delete(objects, by_field \\ :id) do
    case ulid(objects) do
      # is_list(id_or_ids) ->
      #   Enum.each(id_or_ids, fn x -> delete(x, by_field) end)
      nil -> error("Nothing to delete")
      objects ->
        FeedPublish
        |> query_filter({by_field, objects})
        |> debug()
        |> repo().delete_many()
        |> elem(0)
    end
  end

  defp maybe_federate_activity(verb, object, activity, opts) do
    if e(opts, :boundary, nil) !="federated", do: Bonfire.Social.Integration.activity_ap_publish(activity.subject_id, verb, object, activity)
  end
end
