defmodule Bonfire.Social.FeedActivities do
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
  alias Bonfire.Social.Integration
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.Activities
  # alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  # alias Bonfire.Social.Objects

  alias Pointers
  alias Pointers.Pointer
  alias Pointers.Changesets

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: FeedPublish

  def cast(changeset, creator, opts) do
    Feeds.target_feeds(changeset, creator, opts)
    |> cast(changeset, ...)
  end

  def cast(changeset, feed_ids) do
    Enum.map(feed_ids, &%{feed_id: &1})
    |> Changesets.put_assoc!(changeset, :feed_publishes, ...)
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
    error("feeds_for_activity: dunno how to get feeds for #{inspect(activity)}")
    []
  end

  # TODO: put in config
  def skip_verbs_default, do: [:flag]

  @decorate time()
  def feed_ids_and_opts(feed_name, opts)

  def feed_ids_and_opts({:my, feed_ids}, opts) do
    feed_ids_and_opts(:my, to_options(opts) ++ [home_feed_ids: feed_ids])
  end

  def feed_ids_and_opts(:my, opts) do
    opts = to_options(opts)

    # TODO: clean up this code
    exclude_verbs =
      if !Bonfire.Me.Settings.get(
           [Bonfire.Social.Feeds, :my_feed_includes, :boost],
           true,
           opts
         ),
         do: [:boost],
         else: opts[:exclude_verbs] || skip_verbs_default()

    exclude_verbs =
      if !Bonfire.Me.Settings.get(
           [Bonfire.Social.Feeds, :my_feed_includes, :follow],
           false,
           opts
         ),
         do: exclude_verbs ++ [:follow],
         else: exclude_verbs

    # |> debug("exclude_replies")

    opts =
      opts
      |> Keyword.merge(
        exclude_verbs: exclude_verbs,
        exclude_replies:
          !Bonfire.Me.Settings.get(
            [Bonfire.Social.Feeds, :my_feed_includes, :reply],
            true,
            opts
          )
      )

    home_feed_ids =
      if is_list(opts[:home_feed_ids]),
        do: opts[:home_feed_ids],
        else: Feeds.my_home_feed_ids(opts)

    {home_feed_ids, opts}
  end

  def feed_ids_and_opts(:notifications = feed_name, opts) do
    feed_ids_and_opts(
      {:notifications,
       named_feed(
         feed_name,
         opts
       )},
      opts
    )
  end

  def feed_ids_and_opts({:notifications, feed_id}, opts) do
    opts =
      to_options(opts)
      |> Keyword.merge(
        # so we can show flags to admins in notifications
        skip_boundary_check: :admins,
        include_flags: true,
        skip_dedup: true,
        preload: :notifications
      )

    {feed_id, opts}
  end

  def feed_ids_and_opts(feed_name, opts) when is_atom(feed_name) and not is_nil(feed_name) do
    opts =
      to_options(opts)
      |> Keyword.put_new_lazy(:exclude_verbs, &skip_verbs_default/0)

    {named_feed(
       feed_name,
       opts
     ), opts}
  end

  def feed_ids_and_opts({feed_name, feed_id}, opts)
      when is_atom(feed_name) and not is_nil(feed_name) and
             (is_binary(feed_id) or is_list(feed_id)) do
    opts =
      to_options(opts)
      |> Keyword.put_new_lazy(:exclude_verbs, &skip_verbs_default/0)

    {feed_id, opts}
  end

  def feed_ids_and_opts(feed, opts) when is_binary(feed) or is_list(feed) do
    opts =
      to_options(opts)
      |> Keyword.put_new_lazy(:exclude_verbs, &skip_verbs_default/0)

    {feed, opts}
  end

  @doc """
  Gets a user's home feed, a combination of all feeds the user is subscribed to.
  """
  def my_feed(opts, home_feed_ids \\ nil) do
    opts =
      to_options(opts)
      |> Keyword.put_new(:home_feed_ids, home_feed_ids)

    feed(:my, opts)
  end

  defp maybe_merge_filters(filters, opts) when is_struct(filters) do
    warn(filters, "did we filter?")
    opts
  end

  defp maybe_merge_filters(filters, opts) when is_nil(filters) or filters == [] do
    opts
  end

  defp maybe_merge_filters(filters, opts) do
    Enum.into(filters, opts)
  end

  @doc """
  Return a page of Feed Activities (reverse chronological) + pagination metadata
  TODO: consolidate with `feed/2`
  """
  def feed_paginated(filters \\ [], opts \\ []) do
    feed_paginated(filters, opts, default_query())
  end

  def feed_paginated(filters, opts, query) do
    query(filters, opts, query)
    # |> debug
    |> paginate_and_boundarise_feed(opts)
    |> prepare_feed(opts)
  end

  defp paginate_and_boundarise_feed_deferred_query(initial_query, opts) do
    # WIP: BOUNDARISE with deferred join to speed up queries!

    initial_query =
      initial_query
      |> select([:id])
      # to avoid 'cannot preload in subquery' error
      |> Ecto.Query.exclude(:preload)
      |> repo().many_paginated(opts ++ [return: :query, multiply_limit: 2])
      |> subquery()

    base_or_filtered_query(opts)
    |> join(:inner, [fp], ^initial_query, on: [id: fp.id])
    |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
    |> Activities.as_permitted_for(opts)
    |> distinct([activity: activity], desc: activity.id)
    |> debug()
  end

  defp paginate_and_boundarise_feed(query, opts) do
    paginate = e(opts, :paginate, nil) || opts

    case opts[:return] do
      :explain ->
        paginate_and_boundarise_feed_deferred_query(query, opts)
        |> Ecto.Adapters.SQL.explain(repo(), :all, ...,
          analyze: true,
          verbose: false,
          costs: true,
          timing: true,
          summary: true,
          format: :text
        )
        |> IO.puts()

        throw("Explanation printed.")

      :stream ->
        repo().transaction(fn ->
          opts[:stream_callback].(
            repo().stream(Ecto.Query.exclude(query, :preload), max_rows: 100)
          )
        end)

      _ ->
        # ^ tell Paginator to always give us and `after` cursor
        case paginate_and_boundarise_feed_deferred_query(query, opts)
             |> repo().many_paginated(Keyword.new(paginate) ++ [infinite_pages: true]) do
          %{edges: []} -> paginate_and_boundarise_feed_non_deferred_query(query, paginate, opts)
          # ^ if there were no results, try without the deferred query in case some where missing because of boundaries
          result -> result
        end
    end
  end

  defp paginate_and_boundarise_feed_non_deferred_query(query, paginate \\ nil, opts) do
    query
    |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
    |> Activities.as_permitted_for(opts)
    |> repo().many_paginated(paginate || opts)

    # |> debug()
  end

  # defp paginate_and_boundarise_feed(query, opts) do
  #   paginate = e(opts, :paginate, nil) || e(opts, :after, nil) || opts

  #   # WIP: BOUNDARISE with deferred join to speed up queries!

  #   (from top_root in subquery(
  #     query
  #     # |> as(:root)
  #     |> Ecto.Query.exclude(:preload) # to avoid 'cannot preload in subquery' error
  #     |> repo().many_paginated(paginate ++ [return: :query])
  #   ), as: :top_root)
  #   # |> Activities.as_permitted_for_subqueried(opts)
  #   |> Activities.as_permitted_for(opts)
  #   |> select([:top_root])
  #   |> debug()
  #   # |> preload([top_root, activity], activity: activity)
  #   # |> proload(top_root: :activity)
  #   # |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
  #   |> repo().many_paginated(paginate)
  # end

  @doc """
  Gets a feed by id or ids or a thing/things containing an id/ids.
  """
  def feed(feed, opts \\ [])
  def feed(%{id: feed_id}, opts), do: feed(feed_id, opts)
  def feed([feed_id], opts), do: feed(feed_id, opts)

  def feed(id_or_ids, opts)
      when is_binary(id_or_ids) or (is_list(id_or_ids) and id_or_ids != []) do
    opts =
      to_options(opts)
      |> debug("feed_opts for #{id_or_ids}")

    ulid(id_or_ids)
    |> feed_query(opts)
    |> paginate_and_boundarise_feed(maybe_merge_filters(opts[:feed_filters], opts))
    # |> debug()
    |> prepare_feed(opts)
  end

  def feed(:flags, opts) do
    Bonfire.Social.Flags.list(to_options(opts) ++ [include_flags: :moderators])
    # |> debug()
  end

  def feed(feed_name, opts) when is_atom(feed_name) and not is_nil(feed_name) do
    {feed_ids, opts} =
      feed_ids_and_opts(feed_name, opts)
      |> debug("feed_ids_and_opts")

    feed(feed_ids, opts)
  end

  def feed({feed_name, feed_id_or_ids}, opts)
      when is_atom(feed_name) and not is_nil(feed_name) and
             (is_binary(feed_id_or_ids) or is_list(feed_id_or_ids)) do
    {feed_ids, opts} =
      feed_ids_and_opts({feed_name, feed_id_or_ids}, opts)
      |> debug("feed_ids_and_opts")

    feed(feed_ids, opts)
  end

  def feed({feed_name, feed_name_again}, opts)
      when is_atom(feed_name) and not is_nil(feed_name) and is_atom(feed_name_again) do
    feed(feed_name, opts)
  end

  def feed(%Ecto.Query{} = custom_query, opts) do
    opts = to_options(opts)

    custom_query
    |> proload([:activity])
    |> query_extras(opts)
    # |> debug()
    |> paginate_and_boundarise_feed(maybe_merge_filters(opts[:feed_filters], opts))
    |> prepare_feed(opts)
  end

  def feed({feed_name, %{} = filters}, opts) do
    feed(feed_name, [feed_filters: input_to_atoms(filters)] ++ to_options(opts))
  end

  def feed(other, _) do
    error(other, "Not a recognised feed to query")
  end

  defp named_feed(feed_name, opts)
       when is_atom(feed_name) and not is_nil(feed_name) do
    # current_user = current_user(current_user_or_socket)
    # debug(opts)
    case Feeds.named_feed_id(feed_name) || Feeds.my_feed_id(feed_name, opts) do
      feed when is_binary(feed) or is_list(feed) ->
        # debug(ulid(current_user(opts)), "current_user")
        # debug(feed_name, "feed_name")
        debug(feed, "feed id(s)")
        feed

      e ->
        error("FeedActivities.feed: no known feed #{inspect(feed_name)} - #{inspect(e)}")

        debug(opts)
        nil
    end
  end

  def feed_with_object(feed_name, object, opts \\ []) do
    feed(
      feed_name,
      Keyword.put(
        opts,
        :feed_filters,
        Map.merge(
          e(opts, :feed_filters, %{}),
          %{object: object}
        )
      )
    )
  end

  def feed_contains?(feed_name, object, opts \\ [])

  def feed_contains?(feed, html_body, _opts) when is_binary(html_body) and is_list(feed) do
    Enum.find_value(feed, fn fi -> fi.activity.object.post_content.html_body =~ html_body end)
  end

  def feed_contains?(%{edges: feed}, html_body, opts) do
    feed_contains?(feed, html_body, opts)
  end

  def feed_contains?(feed_name, object, opts) do
    {feed_ids, opts} = feed_ids_and_opts(feed_name, opts)

    feed_query(
      feed_ids,
      Keyword.put(
        opts,
        :feed_filters,
        Map.merge(
          e(opts, :feed_filters, %{}),
          %{object: object}
        )
      )
    )
    |> repo().exists?()
  end

  @decorate time()
  defp prepare_feed(result, opts)

  defp prepare_feed(%{edges: edges} = result, opts)
       when is_list(edges) and edges != [] do
    # post_preloads = (if Enum.any?(List.wrap(e(opts, :preload, :feed)), fn p -> p in [:feed, :with_reply_to, :posts_with_reply_to, :feed_metadata] end), do: :with_reply_to, else: [])
    # info("this will be preloaded now (after the query, so boundaries can be applied)") # NOTE: not needed because preloads are also done in FeedLive

    Map.put(
      result,
      :edges,
      edges
      |> maybe_dedup_feed_objects(opts)
      # |> Activities.activity_preloads(post_preloads, opts)
    )
  end

  defp prepare_feed(result, _opts) do
    debug(result, "seems like empty feed")
    result
  end

  defp maybe_dedup_feed_objects(edges, opts) do
    if e(opts, :skip_dedup, nil) do
      edges
    else
      Enum.uniq_by(edges, &e(&1, :activity, :object_id, nil))
    end
  end

  defp default_query(), do: select(Pointers.query_base(), [p], p)

  defp base_query(_opts \\ []) do
    # feeds = from fp in FeedPublish, # why the subquery?..
    #   where: fp.feed_id in ^feed_ids,
    #   group_by: fp.id,
    #   select: %{id: fp.id, dummy: count(fp.feed_id)}

    from(fp in FeedPublish,
      # join: fp in subquery(feeds), on: p.id == fp.id,
      join: activity in Activity,
      as: :activity,
      on: activity.id == fp.id,
      # distinct: [desc: fp.id],
      order_by: [desc: fp.id]
    )
  end

  defp base_or_filtered_query(filters \\ nil, opts) do
    case filters || e(opts, :feed_filters, nil) do
      %Ecto.Query{} = query -> query
      _ -> base_query(opts)
    end
  end

  # @decorate time()
  defp feed_query(feed_ids, opts) do
    opts = to_options(opts)
    local_feed_id = Feeds.named_feed_id(:local)
    federated_feed_id = Feeds.named_feed_id(:activity_pub)

    cond do
      :local == feed_ids or local_feed_id == feed_ids ->
        debug("local feed")

        # excludes likes/follows from local feed - TODO: configurable
        (opts ++ [exclude_verbs: [:like, :follow]])
        |> debug()
        |> query_extras()
        |> proload(activity: [object: {"object_", [:peered]}])
        |> where(
          [fp, activity: activity, object_peered: object_peered],
          fp.feed_id in ^ulids(feed_ids) or is_nil(object_peered.id)
        )

      :activity_pub == feed_ids or federated_feed_id == feed_ids ->
        debug("federated feed")

        query_extras(opts)
        |> proload(activity: [object: {"object_", [:peered]}])
        |> where(
          [fp, object_peered: object_peered],
          fp.feed_id in ^ulids(feed_ids) or not is_nil(object_peered.id)
        )

      (is_list(feed_ids) or is_binary(feed_ids)) and feed_ids != [] and not is_nil(feed_ids) and
          not is_struct(e(opts, :feed_filters, nil)) ->
        debug(feed_ids, "specific feed(s)")
        generic_feed_query(feed_ids, opts)

      true ->
        debug("unknown feed")
        query_extras(opts)
    end

    # |> debug()
  end

  defp generic_feed_query(feed_ids, opts) do
    query_extras(opts)
    |> where([fp], fp.feed_id in ^ulids(feed_ids))

    # |> debug("generic")
  end

  def query(filters \\ [], opts \\ []),
    do: query(filters, opts, default_query())

  # def query(filters, opts, query, true = _distinct)  do
  #   query(filters, opts, query, false)
  #     |> distinct([activity: activity], [desc: activity.id])
  # end

  # def query([feed_id: feed_id_or_ids], opts) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do
  #   # debug(feed_id_or_ids: feed_id_or_ids)
  #   feed_query(feed_id_or_ids, opts)
  #   query([], opts, query)
  # end

  def query(filters, opts, query) when is_list(filters) do
    query
    |> query_extras(opts)
    |> query_filter(filters, nil, nil)

    # |> debug("FeedActivities - query")
  end

  def query(filters, _opts, query) do
    # |> query_extras(current_user)
    # |> query_filter(filters, nil, nil)
    warn(
      query,
      "invalid feed query with filters #{inspect(filters)}"
    )
  end

  # add assocs needed in timelines/feeds
  @doc false
  def query_extras_boundarised(query \\ nil, opts) do
    query_extras(query, opts)
    |> Activities.as_permitted_for(opts)
  end

  defp query_extras(query \\ nil, opts) do
    opts = to_options(opts)
    current_user = current_user(opts)
    # debug(opts)
    # eg. private messages should never appear in feeds
    exclude_object_types = [Message] ++ e(opts, :exclude_object_types, [])
    # exclude certain activity types
    exclude_verbs =
      e(opts, :exclude_verbs, []) ++
        [:message] ++
        if opts[:include_flags] == :moderators and
             (Bonfire.Boundaries.can?(current_user, :mediate, :instance) or
                Integration.is_admin?(current_user)) do
          debug("include flags for mods/admins")
          []
        else
          if opts[:include_flags] do
            debug("include flags for all")
            []
          else
            debug("do not include flags")
            [:flag]
          end
        end

    exclude_table_ids =
      exclude_object_types
      |> Enum.map(&maybe_apply(&1, :__pointers__, :table_id))
      |> List.wrap()

    exclude_verb_ids =
      exclude_verbs
      |> debug("exxclude_verbs")
      |> Enum.map(&Bonfire.Social.Activities.verb_id(&1))
      |> List.wrap()

    # exclude_feed_ids = e(opts, :exclude_feed_ids, []) |> List.wrap() # WIP - to exclude activities that also appear in another feed
    filters = filters_from_opts(opts)

    (query || base_or_filtered_query(filters, opts))
    # |> proload([:activity])
    |> reusable_join(:left, [root], assoc(root, :activity), as: :activity)
    |> reusable_join(:left, [activity: activity], activity_pointer in Pointer,
      as: :activity_pointer,
      on: activity_pointer.id == activity.id
    )
    |> reusable_join(:left, [activity: activity], object in Pointer,
      as: :object,
      on: object.id == activity.object_id
    )
    |> maybe_filter(filters)
    # where: fp.feed_id not in ^exclude_feed_ids,
    # Don't show messages or anything deleted
    |> where(
      [activity: activity, activity_pointer: activity_pointer, object: object],
      activity.verb_id not in ^exclude_verb_ids and
        is_nil(object.deleted_at) and
        is_nil(activity_pointer.deleted_at) and
        activity_pointer.table_id not in ^exclude_table_ids and
        object.table_id not in ^exclude_table_ids
    )
    |> maybe_exclude_replies(filters, opts)
    |> maybe_only_replies(filters, opts)

    # |> debug("pre-preloads")
    # preload all things we commonly want in feeds
    # |> Activities.activity_preloads(e(opts, :preload, :with_object), opts) # if we want to preload the rest later to allow for caching
    # |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
    # |> debug("post-preloads")
  end

  defp maybe_filter(query, %{object_type: object_type}) when not is_nil(object_type) do
    case Bonfire.Common.Types.table_types(object_type) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [object: object], object.table_id in ^table_ids)

      _ ->
        query
    end
  end

  defp maybe_filter(query, %{object: object}) do
    case ulid(object) do
      id when is_binary(id) ->
        where(query, [activity: activity], activity.object_id == ^id)

      ids when is_list(ids) and ids != [] ->
        where(query, [activity: activity], activity.object_id in ^ids)

      _ ->
        query
    end
  end

  defp maybe_filter(query, filters) do
    if Map.keys(filters) |> List.first() |> is_atom() do
      warn(filters, "no known extra filters defined")
      query
    else
      maybe_filter(query, input_to_atoms(filters))
    end
  end

  defp maybe_exclude_replies(query, filters, opts) do
    if e(opts, :exclude_replies, nil) == true or e(filters, :object_type, nil) == "posts" do
      query
      |> proload(activity: [object: {"object_", [:replied]}])
      |> where(
        [object_replied: replied],
        is_nil(replied.reply_to_id)
      )

      # |> debug("exclude_replies")
    else
      query
    end
  end

  defp maybe_only_replies(query, filters, opts) do
    debug(filters)

    if e(opts, :only_replies, nil) == true or e(filters, :object_type, nil) == "discussions" do
      query
      |> proload(activity: [object: {"object_", [:replied]}])
      |> where(
        [object_replied: replied],
        not is_nil(replied.reply_to_id)
      )

      # |> debug("exclude_replies")
    else
      query
    end
  end

  def filters_from_opts(opts) do
    input_to_atoms(
      e(opts, :feed_filters, nil) || e(opts, :__context__, :current_params, nil) || %{}
    )
  end

  # def feed(%{feed_publishes: _} = feed_for, _) do
  #   repo().maybe_preload(feed_for, [feed_publishes: [activity: [:verb, :object, subject_user: [:profile, :character]]]]) |> Map.get(:feed_publishes)
  # end

  @doc """
  Creates a new local activity and publishes to appropriate feeds
  TODO: make this re-use the changeset-based code like in Epics instead of duplicating logic (currently it is only used in VF extension anyway)
  """
  def publish(subject, verb_or_activity, object, opts \\ [])

  def publish(subject, verb_or_activity, object, opts)
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

  # @doc "Records a remote activity and puts in appropriate feeds"
  # defp save_fediverse_incoming_activity(subject, verb, object)
  #      when is_atom(verb) and not is_nil(subject) do
  #   # TODO: use the appropriate preset (eg "public" for public activities?)
  #   publish(subject, verb, object, boundary: "federated")
  # end

  # @doc "Takes or creates an activity and publishes to object creator's inbox"
  # defp maybe_notify_creator(subject, %{activity: %{id: _} = activity}, object),
  #   do: maybe_notify_creator(subject, activity, object)

  # defp maybe_notify_creator(subject, verb_or_activity, object) do
  #   the_object = Objects.preload_creator(the_object(object))
  #   object_creator = Objects.object_creator(the_object)

  #   if ulid(object_creator) && ulid(subject) != ulid(object_creator) do
  #     notify_characters(subject, verb_or_activity, object, [object_creator])
  #   else
  #     debug("no creator found, just creating an activity")
  #     publish(subject, verb_or_activity, object)
  #   end

  #   # TODO: notify remote users via AP
  # end

  @doc """
  Arranges for an insert changeset to also publish to feeds related to some objects.

  Options: see `get_feed_ids/1`
  """
  def put_feed_publishes(changeset, options) do
    get_feed_publishes(options)
    # |> debug()
    |> Changesets.put_assoc!(changeset, :feed_publishes, ...)
  end

  @doc """
  Creates the underlying data for `put_feed_publishes/2`.
  """
  def get_feed_publishes(options) do
    options
    # |> info()
    |> get_feed_ids()
    # |> info()
    # Dedupe
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
  * `:inbox` - list of objects whose inbox we should attempt to insert into.
  * `:outbox` - list of objects whose outbox we should attempt to insert into.
  * `:notifications` - list of objects whose notifications we should attempt to insert into.
  * `:feeds` - list of ids (or objects containing IDs of feeds to post to.
  """
  def get_feed_ids(options) do
    keys = [:inbox, :outbox, :notifications]
    # process all the specifications
    options = get_feed_publishes_options(options)
    # build an index to look up the feed types by id
    index = get_feed_publishes_index(options, keys)
    # preload them all together
    all = Enum.flat_map(keys, &Keyword.get(options, &1, []))
    all = repo().maybe_preload(all, :character)
    # and finally, look up the appropriate feed from the loaded characters
    ids =
      for(
        character <- all,
        feed <- index[ulid(character)],
        do: Feeds.feed_id(feed, character)
      )

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
        id = ulid(v)
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
  #   Bonfire.Social.LivePush.notify(subject, verb_or_activity, object, feed_ids)
  #   ret
  # end

  @doc "Creates a new local activity or takes an existing one and publishes to specified feeds"
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
    dump([subject, verb, ulid(object), true])
    Bonfire.Social.APActivities.create(subject, %{verb: verb}, ulid(object))
  end

  defp create_activity(subject, verb, object, %{} = json),
    do: Bonfire.Social.APActivities.create(subject, Enum.into(json, %{verb: verb}), ulid(object))

  defp create_activity(subject, verb, object, _), do: Activities.create(subject, verb, object)

  defp create_and_put_in_feeds(subject, verb, object, feed_id, opts)
       when (is_map(object) and is_binary(feed_id)) or is_list(feed_id) do
    with {:ok, activity} <- create_activity(subject, verb, object, e(opts, :activity_json, nil)) do
      # publish in specified feed
      # meh
      with {:ok, published} <-
             put_in_feeds_and_maybe_federate(
               feed_id,
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
          warn(e, "did not put_in_feeds or federate: #{inspect(feed_id)}")
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
    put_in_feeds(feeds, activity)
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

  defp put_in_feeds(feeds, activity) when is_list(feeds) do
    feeds
    # ????
    |> Circles.circle_ids()
    # TODO: optimise?
    |> Enum.map(fn x -> put_in_feeds(x, activity) end)
  end

  defp put_in_feeds(feed_or_subject, activity)
       when is_map(feed_or_subject) or
              (is_binary(feed_or_subject) and feed_or_subject != "") do
    with feed_id <- ulid(feed_or_subject),
         {:ok, published} <- do_put_in_feeds(feed_id, ulid(activity)) do
      # push to feeds of online users
      Bonfire.Social.LivePush.push_activity(feed_id, activity)
      {:ok, Map.put(published, :activity, activity)}
    else
      e ->
        error(
          "FeedActivities.put_in_feeds: error when trying with feed_or_subject: #{inspect(e)}"
        )

        {:ok, nil}
    end
  end

  defp put_in_feeds(_, _) do
    error("FeedActivities: did not put_in_feeds")
    {:ok, nil}
  end

  defp do_put_in_feeds(feed, activity)
       when is_binary(activity) and is_binary(feed) do
    repo().insert(%FeedPublish{feed_id: feed, id: activity})
  end

  def the_object({%{} = object, _mixin_object}), do: object
  def the_object(object), do: object

  @doc "Remove one or more activities from all feeds"
  def delete(objects, by_field) when is_atom(by_field) do
    case ulid(objects) do
      # is_list(id_or_ids) ->
      #   Enum.each(id_or_ids, fn x -> delete(x, by_field) end)
      nil ->
        error("Nothing to delete")

      objects ->
        debug(objects)
        delete({by_field || :id, objects})
    end
  end

  @doc "Remove activities from feeds, using specific filters"
  def delete(filters) when is_list(filters) or is_tuple(filters) do
    FeedPublish
    |> query_filter(filters)
    # |> debug()
    |> repo().delete_many()
    |> elem(0)
  end

  defp do_maybe_federate_activity(subject, verb, object, activity, opts) do
    if e(opts, :boundary, nil) != "federated",
      do:
        Bonfire.Social.Integration.maybe_federate_and_gift_wrap_activity(
          subject || e(activity, :subject, nil) || e(activity, :subject_id, nil),
          activity,
          verb,
          object
        )
  end

  def unseen_query(feed_id, opts) do
    table_id = Bonfire.Common.Types.table_id(Seen)
    current_user = current_user(opts)

    feed_id =
      if is_ulid?(feed_id),
        do: feed_id,
        else: Bonfire.Social.Feeds.my_feed_id(feed_id, current_user)

    uid = ulid(current_user)

    if uid && table_id,
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

  def unseen_count(feed_id, opts) do
    unseen_query(feed_id, opts)
    ~> select(count())
    |> repo().one()
  end

  def count(filters \\ [], opts \\ []) do
    query(filters, opts, opts[:query] || default_query())
    |> Ecto.Query.exclude(:select)
    # |> Ecto.Query.exclude(:distinct)
    |> Ecto.Query.exclude(:preload)
    |> Ecto.Query.exclude(:order_by)
    ~> select(count())
    |> debug()
    |> repo().one()
  end

  def count_subjects(filters \\ [], opts \\ []) do
    query(filters, opts, opts[:query] || default_query())
    |> Ecto.Query.exclude(:select)
    |> Ecto.Query.exclude(:distinct)
    |> Ecto.Query.exclude(:preload)
    |> Ecto.Query.exclude(:order_by)
    ~> select([subject: subject], count(subject.id, :distinct))
    |> debug()
    |> repo().one()
  end

  def count_total(), do: repo().one(select(FeedPublish, [u], count(u.id)))

  def mark_all_seen(feed_id, opts) do
    unseen_query(feed_id, opts)
    ~> select([c], %{id: c.id})
    |> repo().all()
    |> Bonfire.Social.Seen.mark_seen(current_user_required!(opts), ...)
  end
end
