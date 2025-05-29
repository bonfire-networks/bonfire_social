defmodule Bonfire.Social.FeedActivities do
  @moduledoc """
  Helpers to create or query a feed's activities.

  This is the [context](https://hexdocs.pm/phoenix/contexts.html) for `Bonfire.Data.Social.FeedPublish`, which has two foreign fields:
  - id (of the activity, see `Bonfire.Social.Activities`)
  - feed (see `Bonfire.Social.Feeds`)
  """

  use Arrows
  use Untangle
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  import Ecto.Query
  # alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Data.Social.Activity
  alias Bonfire.Data.Social.FeedPublish
  alias Bonfire.Data.Social.Message
  alias Bonfire.Data.Social.Seen
  alias Bonfire.Social
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Objects

  alias Needle.Pointer
  alias Needle.Changesets

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: FeedPublish
  def query_module, do: __MODULE__

  @doc """
  Casts the changeset to publish an activity to the given creator and feed IDs.

  ## Examples

      > cast(changeset, creator, opts)
      %Ecto.Changeset{}
  """
  def cast(changeset, creator, opts) do
    Feeds.target_feeds(changeset, creator, opts)
    |> cast(changeset, ...)
  end

  @doc """
  Casts the changeset to publish an activity to the given feed IDs.

  ## Examples

      > cast(changeset, feed_ids)
      %Ecto.Changeset{}
  """
  def cast(changeset, feed_ids) do
    Enum.map(feed_ids || [], &%{feed_id: &1})
    |> Changesets.put_assoc!(changeset, :feed_publishes, ...)
  end

  defdelegate feed(name \\ nil, opts \\ []), to: FeedLoader
  defdelegate feed(name, filters, opts), to: FeedLoader

  def base_query(_opts \\ []) do
    # feeds = from fp in FeedPublish, # why the subquery?..
    #   where: fp.feed_id in ^feed_ids,
    #   group_by: fp.id,
    #   select: %{id: fp.id, dummy: count(fp.feed_id)}

    from(fp in FeedPublish,
      as: :main_object,
      # join: fp in subquery(feeds), on: p.id == fp.id,
      join: activity in Activity,
      as: :activity,
      on: activity.id == fp.id
      # distinct: [desc: activity.id],
      # order_by: [desc: activity.id]
    )
  end

  def query_order(query, :num_replies = sort_by, sort_order) do
    query
    |> maybe_preload_replied()
    |> Activities.query_order(sort_by, sort_order)
  end

  def query_order(query, sort_by, sort_order) do
    Activities.query_order(query, sort_by, sort_order)
  end

  def query_maybe_exclude_mine(query, me) do
    if not is_nil(me) and
         !Bonfire.Common.Settings.get(
           [Bonfire.Social.Feeds, :include, :outbox],
           true,
           me
         ) do
      where(query, [activity: activity], activity.subject_id != ^id(me))
    else
      query
    end
  end

  def maybe_preload_replied(%{aliases: %{replied: _}} = query) do
    query
  end

  def maybe_preload_replied(query) do
    query
    |> proload(activity: [:replied])
  end

  @doc """
  Gets a list of feed ids this activity was published to from the database.

  Currently only used by the ActivityPub integration.

  ## Examples

      > feeds_for_activity(%{id: id})
      [feed_id1, feed_id2]

      > feeds_for_activity(id)
      [feed_id1, feed_id2]

      > feeds_for_activity(activity)
      []
  """
  def feeds_for_activity(%{id: id}), do: feeds_for_activity(id)

  def feeds_for_activity(id) when is_binary(id) do
    repo().all(from(f in FeedPublish, where: f.id == ^id, select: f.feed_id))
  end

  def feeds_for_activity(activity) do
    error(activity, "dunno how to get feeds for this")
    []
  end

  @doc """
  Creates a new local activity and publishes to appropriate feeds
  TODO: make this re-use the changeset-based code like in Epics instead of duplicating logic (currently it is only used in VF extension anyway)

  ## Examples

      > subject = %{id: "user123"}
      > verb = :create
      > object = %{id: "post456"}
      > Bonfire.Social.FeedActivities.publish(subject, verb, object, [])
      {:ok, %Bonfire.Data.Social.Activity{}}
  """
  def publish(subject, verb_or_activity, object, opts \\ [])

  def publish(subject, verb_or_activity, object, opts)
      when is_atom(verb_or_activity) or is_struct(verb_or_activity) do
    # debug("FeedActivities: just making visible for and putting in these circles/feeds: #{inspect circles}")
    # Bonfire.Boundaries.maybe_make_visible_for(subject, object, circles) # |> debug("grant")
    Feeds.target_feeds(the_object(object), subject, opts)
    |> debug("feeds to publish to")
    |> maybe_feed_publish(subject, verb_or_activity, object, ..., opts)
  end

  def publish(subject, verb, object, opts) do
    debug(verb, "Undefined verb, changing to :create")
    publish(subject, :create, object, opts)
  end

  # @doc "Records a remote activity and puts in appropriate feeds"
  # defp save_fediverse_incoming_activity(subject, verb, object)
  #      when is_atom(verb) and not is_nil(subject) do
  #   # TODO: use the appropriate preset (eg "public" for public activities?)
  #   publish(subject, verb, object, boundary: "public_remote")
  # end

  # @doc "Takes or creates an activity and publishes to object creator's inbox"
  # defp maybe_notify_creator(subject, %{activity: %{id: _} = activity}, object),
  #   do: maybe_notify_creator(subject, activity, object)

  # defp maybe_notify_creator(subject, verb_or_activity, object) do
  #   the_object = Objects.preload_creator(the_object(object))
  #   object_creator = Objects.object_creator(the_object)

  #   if uid(object_creator) && uid(subject) != uid(object_creator) do
  #     notify_characters(subject, verb_or_activity, object, [object_creator])
  #   else
  #     debug("no creator found, just creating an activity")
  #     publish(subject, verb_or_activity, object)
  #   end

  #   # TODO: notify remote users via AP
  # end

  @doc """
  Arranges for an insert changeset to also publish to feeds related to some objects.

  Options: see `get_publish_feed_ids/1`

  ## Examples

      > changeset = %Ecto.Changeset{}
      > options = [feeds: ["feed123", "feed456"]]
      > Bonfire.Social.FeedActivities.put_feed_publishes(changeset, options)
      %Ecto.Changeset{}
  """
  def put_feed_publishes(changeset, options) do
    get_feed_publishes(options)
    |> debug("got_feed_publishes")
    |> Changesets.put_assoc!(changeset, :feed_publishes, ...)
  end

  @doc """
  Creates the underlying data for `put_feed_publishes/2`.

  Options: see `get_publish_feed_ids/1`

  ## Examples

      > options = [feeds: ["feed123", "feed456"]]
      > Bonfire.Social.FeedActivities.get_feed_publishes(options)
      [%{feed_id: "feed123"}, %{feed_id: "feed456"}]
  """
  def get_feed_publishes(options) do
    debug(options, "get_feed_publishes input")

    options
    # |> info()
    |> get_publish_feed_ids()
    # |> info()
    # Dedup
    |> MapSet.new()
    |> MapSet.delete(nil)
    # turn into attrs
    # |> Enum.map(&(%FeedPublish{feed_id: &1}))
    |> Enum.map(&%{feed_id: &1})

    # |> info()
  end

  @doc """
  Computes the feed ids for `get_feed_publishes/2`.

  Options:
  * `:inbox` - list of users/characters whose inbox we should attempt to insert into.
  * `:outbox` - list of users/characters whose outbox we should attempt to insert into.
  * `:notifications` - list of users/characters whose notifications we should attempt to insert into.
  * `:feeds` - list of ids (or objects containing IDs) of feeds to post to.

  ## Examples

      > options = [outbox: [%{id: "author123"}], inbox: [%{id: "mention987"}], notifications: [%{id: "reply654"}], feeds: ["feed456"]]
      > Bonfire.Social.FeedActivities.get_publish_feed_ids(options)
      ["inbox_feed_id_for_user123", "feed456"]
  """
  def get_publish_feed_ids(options) do
    keys = [:inbox, :outbox, :notifications]
    # process all the specifications
    options = get_feed_publishes_options(options)
    debug(options, "processed feed options")
    # build an index to look up the feed types by id
    index = get_feed_publishes_index(options, keys)
    debug(index, "feed publish index")
    # preload them all together
    all = Enum.flat_map(keys, &Keyword.get(options, &1, []))
    debug(all, "all characters to preload")
    all = repo().maybe_preload(all, :character)
    # and finally, look up the appropriate feed from the loaded characters
    ids =
      for(
        character <- all,
        feed <- index[uid(character)],
        do: Feeds.feed_id(feed, character)
      )

    debug(ids, "resolved feed IDs")

    ids ++ Keyword.get(options, :feeds, [])
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
          _ ->
            put_feed_publish_item(item, acc)
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
        id = uid(v)
        Map.update(acc, id, [k], &[k | &1])
    end
  end

  # @doc "Creates a new local activity or takes an existing one and publishes to object's notifications (if object is an actor)"
  # defp notify_characters(subject, verb_or_activity, object, characters) do
  #   # TODO: notify remote users via AP?
  #   # debug(characters)
  #   Feeds.feed_ids(:notifications, characters)
  #   |> Enums.filter_empty([])
  #   |> notify_to_feed_ids(subject, verb_or_activity, object, ...)
  # end

  # @doc "Creates a new local activity or takes an existing one and publishes to object's inbox (assuming object is a character)"
  # defp notify_object(subject, verb_or_activity, object) do
  #   notify_characters(subject, verb_or_activity, object, [the_object(object)])
  # end

  # @doc "Creates a new local activity or takes an existing one and publishes to creator's inbox"
  # defp notify_admins(subject, verb_or_activity, object) do
  #   inboxes = Feeds.admins_notifications()
  #   # |> debug()
  #   notify_to_feed_ids(subject, verb_or_activity, object, inboxes)
  # end

  # defp notify_to_feed_ids(subject, verb_or_activity, object, feed_ids) do
  #   # debug(feed_ids)
  #   # |> debug("notify_to_feed_ids")
  #   ret = publish(subject, verb_or_activity, object, to_feeds: feed_ids)
  #   maybe_apply(Bonfire.Social.LivePush, :notify, [
  #     subject, verb_or_activity, object, feed_ids
  #     ])
  #   ret
  # end

  @doc """
  Creates a new local activity or takes an existing one and publishes to specified feeds

  ## Examples

      > subject = %{id: "user123"}
      > verb = :create
      > object = %{id: "post456"}
      > feeds = ["feed789"]
      > opts = []
      > Bonfire.Social.FeedActivities.maybe_feed_publish(subject, verb, object, feeds, opts)
      {:ok, %Bonfire.Data.Social.Activity{}}
  """
  def maybe_feed_publish(subject, verb_or_activity, object, feeds, opts)

  def maybe_feed_publish(subject, verb, object, feeds, opts)
      when is_atom(verb),
      do: create_and_put_in_feeds(subject, verb, object, feeds, opts)

  def maybe_feed_publish(
        subject,
        %Bonfire.Data.Social.Activity{} = activity,
        object,
        feeds,
        opts
      ) do
    put_in_feeds_and_maybe_federate(
      feeds,
      subject,
      activity.verb.verb,
      object,
      activity,
      opts
    )

    # TODO: notify remote users via AP
  end

  def maybe_feed_publish(
        subject,
        %{activity: %{id: _} = activity},
        _,
        feeds,
        opts
      ),
      do: maybe_feed_publish(subject, activity, nil, feeds, opts)

  def maybe_feed_publish(
        subject,
        %{activity: _activity_not_loaded} = parent,
        _,
        feeds,
        opts
      ),
      do:
        maybe_feed_publish(
          subject,
          parent |> repo().maybe_preload(:activity) |> e(:activity, nil),
          nil,
          feeds,
          opts
        )

  def maybe_feed_publish(_, activity, _, _, _) do
    error(
      activity,
      "maybe_feed_publish: did not put in feeds or federate, expected an Activity or a Verb+Object, but got"
    )

    {:ok, activity}
  end

  defp create_activity(subject, verb, object, true) do
    dump([subject, verb, uid(object), true])
    Bonfire.Social.APActivities.create(subject, %{verb: verb}, uid(object))
  end

  defp create_activity(subject, verb, object, %{} = json),
    do: Bonfire.Social.APActivities.create(subject, Enum.into(json, %{verb: verb}), uid(object))

  defp create_activity(subject, verb, object, _), do: Activities.create(subject, verb, object)

  defp create_and_put_in_feeds(subject, verb, %{} = object, feed_ids, opts)
       when is_binary(feed_ids) or is_list(feed_ids) do
    with {:ok, activity} <-
           create_activity(subject, verb, object, e(opts, :activity_json, nil))
           |> debug("created") do
      # publish in specified feed
      # meh
      with {:ok, published} <-
             put_in_feeds_and_maybe_federate(
               feed_ids,
               subject,
               verb,
               object,
               activity,
               opts
             ) do
        # debug(published, "create_and_put_in_feeds")
        {:ok, published}
      else
        publishes when is_list(publishes) and length(publishes) > 0 ->
          {:ok, activity}

        e ->
          warn(e, "did not put_in_feeds or federate: #{inspect(feed_ids)}")
          {:ok, activity}
      end
    end
  end

  defp create_and_put_in_feeds(
         subject,
         verb,
         object,
         %{feed_id: feed_id},
         opts
       ),
       do: create_and_put_in_feeds(subject, verb, object, feed_id, opts)

  defp create_and_put_in_feeds(subject, verb, object, _, opts)
       when is_map(object) do
    # fallback for activities with no target feed, still create the activity and push it to AP
    {:ok, activity} = Activities.create(subject, verb, object, e(opts, :activity_id, nil))

    try do
      # FIXME only run if ActivityPub is a target circle/feed?
      do_maybe_federate_activity(subject, verb, object, activity, opts)
    rescue
      e ->
        error(__STACKTRACE__, inspect(e))
        {:ok, activity}
    end
  end

  defp put_in_feeds_and_maybe_federate(
         feeds,
         subject,
         verb,
         object,
         activity,
         opts
       ) do
    # This makes sure it gets put in feed even if the
    # federation hook fails
    feeds = Enums.filter_empty(feeds, [])
    # ret =
    activity = put_in_feeds(feeds, activity) || activity
    # TODO: add ActivityPub feed for remote activities
    try do
      # FIXME only run if ActivityPub is a target circle/feed?
      # TODO: only run for non-local activity
      do_maybe_federate_activity(subject, verb, object, activity, opts)
    rescue
      e ->
        error("Error occurred when trying to federate, skip...")
        error(__STACKTRACE__, inspect(e))
        {:ok, activity}
    end
  end

  defp put_in_feeds(feeds, activity, push? \\ true)

  defp put_in_feeds(feeds, activity, push?) when is_list(feeds) and feeds != [] do
    # fa =
    feeds
    # |> Circles.circle_ids()
    |> Enum.map(fn x -> put_in_feeds(x, id(activity), false) end)

    if push?, do: maybe_apply(Bonfire.Social.LivePush, :push_activity, [feeds, activity])
  end

  defp put_in_feeds(feed_or_subject, activity, push?)
       when is_map(feed_or_subject) or
              (is_binary(feed_or_subject) and feed_or_subject != "") do
    with feed_id <- uid(feed_or_subject),
         {:ok, _published} <- do_put_in_feeds(feed_id, uid(activity)) do
      # push to feeds of online users
      if push?, do: maybe_apply(Bonfire.Social.LivePush, :push_activity, [feed_id, activity])
    else
      e ->
        error(
          "FeedActivities.put_in_feeds: error when trying with feed_or_subject: #{inspect(e)}"
        )

        nil
    end
  end

  defp put_in_feeds(_, _, _) do
    error("FeedActivities: did not put_in_feeds")
    nil
  end

  defp do_put_in_feeds(feed, activity)
       when is_binary(activity) and is_binary(feed) do
    repo().upsert(
      Ecto.Changeset.cast(%FeedPublish{}, %{feed_id: feed, id: activity}, [:feed_id, :id])
    )
  end

  def the_object({%{} = object, _mixin_object}), do: object
  def the_object(object), do: object

  @doc """
  Remove one or more activities from all feeds

  ## Examples

      > Bonfire.Social.FeedActivities.delete("123", :object_id)
      {1, nil}
  """
  def delete(objects, by_field) when is_atom(by_field) do
    case Types.uid_or_uids(objects) do
      # is_list(id_or_ids) ->
      #   Enum.each(id_or_ids, fn x -> delete(x, by_field) end)
      nil ->
        warn(objects, "No activities to delete from feed")

      objects ->
        debug(objects)
        delete({by_field || :id, objects})
    end
  end

  @doc """
  Remove activities from feeds, using specific filters

  ## Examples

      > filters = [object_id: "123"]
      > Bonfire.Social.FeedActivities.delete(filters)
      {5, nil}
  """
  def delete(filters) when is_list(filters) or is_tuple(filters) do
    q =
      FeedPublish
      |> query_filter(filters)

    q
    |> repo().many()
    |> hide_activities()
    |> debug("pushed deletions to feeds")

    q
    |> repo().delete_many()
    |> elem(0)
  end

  defp hide_activities(fp) when is_list(fp) do
    for %{id: activity, feed_id: feed_id} <- fp do
      maybe_apply(Bonfire.Social.LivePush, :hide_activity, [
        feed_id,
        activity
      ])
    end
  end

  defp do_maybe_federate_activity(subject, verb, object, activity, opts) do
    if e(opts, :boundary, nil) != "public_remote",
      do:
        Bonfire.Social.maybe_federate_and_gift_wrap_activity(
          subject || e(activity, :subject, nil) || e(activity, :subject_id, nil),
          activity,
          verb: verb,
          object: object
        )
  end

  defp unseen_query(feed_id, opts) do
    table_id = Bonfire.Common.Types.table_id(Seen)
    current_user = current_user(opts)

    feed_id =
      if is_uid?(feed_id),
        do: feed_id,
        else: Bonfire.Social.Feeds.my_feed_id(feed_id, current_user)

    uid = uid(current_user)

    if uid && table_id && feed_id,
      do:
        {:ok,
         from(fp in FeedPublish,
           left_join: seen_edge in Edge,
           on:
             fp.id == seen_edge.object_id and seen_edge.table_id == ^table_id and
               seen_edge.subject_id == ^uid,
           where: fp.feed_id == ^feed_id,
           where: is_nil(seen_edge.id)
         )}

    # |> debug()
  end

  @doc """
  Returns the count of unseen items in a feed for the current user.

  ## Examples

      > unseen_count(feed_id, current_user: me)
      5
  """
  def unseen_count(feed_id, opts) do
    unseen_query(feed_id, opts)
    ~> select(count())
    |> repo().one()
  end

  @doc """
  Returns the total count of activities in feeds.
  """
  def count_total(), do: repo().one(select(FeedPublish, [u], count(u.id)))

  @doc """
  Marks all unseen items in a feed as seen for the current user.

  ## Examples

      > mark_all_seen(feed_id, current_user: me)
      {:ok, number_of_marked_items}
  """
  def mark_all_seen(feed_id, opts) do
    current_user = current_user_required!(opts)

    unseen_query(feed_id, opts)
    ~> select([c], %{id: c.id})
    |> repo().all()
    |> Bonfire.Social.Seen.mark_seen(current_user, ...)
  end
end
