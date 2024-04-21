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
  alias Bonfire.Social.Objects
  alias Bonfire.Social.LivePush

  alias Needle
  alias Needle.Pointer
  alias Needle.Changesets

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: FeedPublish
  def query_module, do: __MODULE__

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

  def to_feed_options(socket_or_opts) do
    opts = to_options(socket_or_opts)
    # TODO: clean up this code
    exclude_verbs =
      if opts[:exclude_verbs] == false do
        false
      else
        opts[:exclude_verbs] || skip_verbs_default()
      end

    # exclude_verbs = opts[:exclude_verbs] || skip_verbs_default()

    exclude_verbs =
      if opts[:exclude_verbs] != false and
           !Bonfire.Common.Settings.get(
             [Bonfire.Social.Feeds, :include, :boost],
             true,
             opts
           ),
         do: exclude_verbs ++ [:boost],
         else: exclude_verbs

    exclude_verbs =
      if opts[:exclude_verbs] != false and
           !Bonfire.Common.Settings.get(
             [Bonfire.Social.Feeds, :include, :follow],
             false,
             opts
           ),
         do: exclude_verbs ++ [:follow],
         else: exclude_verbs

    opts
    |> Keyword.merge(
      exclude_verbs: exclude_verbs,
      exclude_replies:
        !Bonfire.Common.Settings.get(
          [Bonfire.Social.Feeds, :include, :reply],
          true,
          opts
        )
    )
  end

  # @decorate time()
  def feed_ids_and_opts(feed_name, opts)

  def feed_ids_and_opts({:my, feed_ids}, opts) do
    feed_ids_and_opts(:my, opts ++ [home_feed_ids: feed_ids])
  end

  def feed_ids_and_opts(:my, opts) do
    # opts = to_feed_options(opts)

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
      opts
      |> Keyword.merge(
        # so we can show flags to admins in notifications
        skip_boundary_check: :admins,
        include_flags: true,
        exclude_verbs: false,
        skip_dedup: true,
        preload: List.wrap(e(opts, :preload, [])) ++ [:notifications]
      )

    {feed_id, opts}
  end

  def feed_ids_and_opts(feed_name, opts) when is_atom(feed_name) and not is_nil(feed_name) do
    opts =
      opts
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
      opts
      |> Keyword.put_new_lazy(:exclude_verbs, &skip_verbs_default/0)

    {feed_id, opts}
  end

  def feed_ids_and_opts(feed, opts) when is_binary(feed) or is_list(feed) do
    opts =
      opts
      |> Keyword.put_new_lazy(:exclude_verbs, &skip_verbs_default/0)

    {feed, opts}
  end

  @doc """
  Gets a user's home feed, a combination of all feeds the user is subscribed to.
  """
  def my_feed(opts, home_feed_ids \\ nil) do
    opts =
      opts
      |> to_options()
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
    do_query(filters, opts, query)
    # |> debug
    |> paginate_and_boundarise_feed(opts)

    # |> prepare_feed(opts)
  end

  def feed_many_paginated(query, opts) do
    opts = to_options(opts)

    Integration.many(
      query,
      opts[:paginate],
      opts ++ Activities.order_pagination_opts(opts[:sort_by], opts[:sort_order])
    )
  end

  defp paginate_and_boundarise_feed_deferred_query(initial_query, opts) do
    # speeds up queries by applying filters (incl. pagination) in a deferred join before boundarising and extra joins/preloads

    initial_query =
      initial_query
      |> select([:id])
      # to avoid 'cannot preload in subquery' error
      |> make_distinct(opts[:sort_order], opts[:sort_order], opts)
      |> query_order(opts[:sort_by], opts[:sort_order])
      |> feed_many_paginated(opts ++ [paginate: true, return: :query, multiply_limit: 2])
      |> repo().make_subquery()

    # |> debug("deferred subquery")

    default_or_filtered_query(opts)
    |> join(:inner, [fp], ^initial_query, on: [id: fp.id])
    |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
    |> Activities.as_permitted_for(opts)
    |> query_order(opts[:sort_by], opts[:sort_order])

    # |> debug("query with deferred join")
  end

  defp paginate_and_boundarise_feed(query, opts) do
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
             |> debug("final query")
             |> feed_many_paginated(opts ++ [infinite_pages: true]) do
          %{edges: []} ->
            debug(
              "there were no results, try without the deferred query in case some where missing because of boundaries"
            )

            paginate_and_boundarise_feed_non_deferred_query(query, opts)

          result ->
            debug("we got results")

            result
        end
        # TODO: where best to do these postloads? and try to optimise into one call
        |> Bonfire.Common.Needles.Preload.maybe_preload_nested_pointers(
          [activity: [replied: [:reply_to]]],
          opts
        )
        |> Bonfire.Common.Needles.Preload.maybe_preload_nested_pointers(
          [activity: [:object]],
          opts
        )

        # run post-preloads to follow pointers and catch anything else missing - TODO: only follow some pointers
        # |> Activities.activity_preloads(e(opts, :preload, :feed), opts |> Keyword.put_new(:follow_pointers, true))
    end
  end

  defp paginate_and_boundarise_feed_non_deferred_query(query, opts) do
    query
    |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
    |> Activities.as_permitted_for(opts)
    |> query_order(opts[:sort_by], opts[:sort_order])
    |> feed_many_paginated(opts)

    # |> debug()
  end

  # defp paginate_and_boundarise_feed(query, opts) do
  #   paginate = e(opts, :paginate, nil) || e(opts, :after, nil) || opts

  #   # WIP: BOUNDARISE with deferred join to speed up queries!

  #   (from top_root in subquery(
  #     query
  #     # |> as(:root)
  #     |> Ecto.Query.exclude(:preload) # to avoid 'cannot preload in subquery' error
  #     |> feed_many_paginated(paginate ++ [return: :query])
  #   ), as: :top_root)
  #   # |> Activities.as_permitted_for_subqueried(opts)
  #   |> Activities.as_permitted_for(opts)
  #   |> select([:top_root])
  #   |> debug()
  #   # |> preload([top_root, activity], activity: activity)
  #   # |> proload(top_root: :activity)
  #   # |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
  #   |> feed_many_paginated(paginate)
  # end

  def feed_name(name, current_user_or_socket) when is_nil(name) or name == :default do
    debug(current_user_or_socket)
    current = current_user_id(current_user_or_socket)
    # || current_account(socket)

    if not is_nil(current) do
      # my feed
      :my
    else
      # fallback to showing instance feed
      :local
    end
    |> debug("default feed to load:")
  end

  def feed_name(name, _socket) when is_atom(name) or is_binary(name) do
    name
  end

  def feed_name(opts, socket) do
    case e(opts, :feed_name, nil) || e(opts, :feed_id, nil) || e(opts, :id, nil) |> debug("fffff") do
      nil ->
        throw("Unexpected feed id(s)")

      name ->
        feed_name(name, socket)
    end
  end

  @doc """
  Gets a feed by id or ids or a thing/things containing an id/ids.
  """
  def feed(feed, opts \\ [])
  def feed(%{id: feed_id}, opts), do: feed(feed_id, opts)
  def feed([feed_id], opts), do: feed(feed_id, opts)

  def feed(id_or_ids, opts)
      when is_binary(id_or_ids) or (is_list(id_or_ids) and id_or_ids != []) do
    if Keyword.keyword?(id_or_ids) do
      id_or_ids
      |> debug("id_or_idsss")
      |> feed_name(opts)
      |> debug("kkkk")
      |> feed(opts)
    else
      opts =
        opts
        |> debug("feed_opts for #{id_or_ids}")

      ulid(id_or_ids)
      |> do_feed(opts)
    end
  end

  def feed(:explore, opts) do
    opts
    |> Enums.deep_merge(exclude_verbs: [:like, :pin])
    |> do_feed(:explore, ...)

    # |> debug("explore feed")
  end

  def feed(:curated, opts) do
    Bonfire.Social.Pins.list_instance_pins(opts)
    # |> debug()
  end

  def feed(:likes, opts) do
    Bonfire.Social.Likes.list_my(opts)
    # |> debug()
  end

  def feed(:bookmarks, opts) do
    Bonfire.Social.Bookmarks.list_my(opts)
    # |> debug()
  end

  def feed(:flags, opts) do
    Bonfire.Social.Flags.list_preloaded(opts ++ [include_flags: :moderators])
  end

  def feed(:media, opts) do
    feed(
      {:media, :all},
      opts
    )
  end

  def feed({:media, type}, opts) do
    opts =
      opts
      |> Keyword.merge(
        per_media_type: type,
        preload: List.wrap(e(opts, :preload, [])) ++ [:per_media]
      )

    feed(:explore, opts)
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
    # opts = to_feed_options(opts)

    custom_query
    |> proload([:activity])
    |> query_extras(opts)
    |> paginate_and_boundarise_feed(maybe_merge_filters(opts[:feed_filters], opts))
    |> prepare_feed(opts)
  end

  def feed({feed_name, %{} = filters}, opts) do
    feed(feed_name, [feed_filters: input_to_atoms(filters)] ++ opts)
  end

  def feed(other, _) do
    e = l("Not a recognised feed to query")
    error(other, e)
    raise e
  end

  defp do_feed(feed_id_or_ids_or_name, opts) do
    if opts[:cache] do
      key = feed_id_or_ids_or_name

      case Cache.get!(key) do
        nil ->
          debug(key, "querying and putting in cache")
          Cache.put(key, actually_do_feed(feed_id_or_ids_or_name, opts))

        feed ->
          debug(key, "got from cache")
          feed
      end
    else
      debug("do not cache")
      actually_do_feed(feed_id_or_ids_or_name, opts)
    end
  end

  defp actually_do_feed(feed_id_or_ids_or_name, opts) do
    feed_id_or_ids_or_name
    |> feed_query(opts)
    |> paginate_and_boundarise_feed(maybe_merge_filters(opts[:feed_filters], opts))
    # |> debug()
    |> prepare_feed(opts)
  end

  defp named_feed(feed_name, opts \\ [])
  defp named_feed(:explore, _opts), do: nil

  defp named_feed(feed_name, opts)
       when is_atom(feed_name) and not is_nil(feed_name) do
    # current_user = current_user(current_user_or_socket)
    case Feeds.named_feed_id(feed_name, opts) || Feeds.my_feed_id(feed_name, opts) do
      feed when is_binary(feed) or is_list(feed) ->
        # debug(ulid(current_user(opts)), "current_user")
        # debug(feed_name, "feed_name")
        debug(feed, "feed id(s)")
        feed

      itself when itself == feed_name ->
        Feeds.my_feed_id(feed_name, opts) ||
          (
            error("FeedActivities.feed: no known feed #{inspect(feed_name)}")
            nil
          )

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

  def feed_contains?(%{edges: edges}, object, opts) do
    feed_contains?(edges, object, opts)
  end

  def feed_contains?(feed, id_or_html_body, _opts)
      when is_list(feed) and (is_binary(id_or_html_body) or is_map(id_or_html_body)) do
    Enum.find_value(feed, fn fi ->
      if fi.activity.object_id == id(id_or_html_body) or
           e(fi.activity.object, :post_content, :html_body, "") =~ id_or_html_body do
        id(fi.activity.object)
      end
    end) ||
      (
        debug(feed, "object not found in feed")
        false
      )
  end

  def feed_contains?(feed_name, filters, opts) when is_list(filters) do
    {feed_ids, opts} = feed_ids_and_opts(feed_name, to_options(opts))

    feed_query(
      feed_ids,
      Keyword.put(
        opts,
        :feed_filters,
        Enum.into(
          filters,
          e(opts, :feed_filters, %{})
        )
      )
    )
    |> Activities.as_permitted_for(opts)
    |> repo().one()
    |> id()
  end

  def feed_contains?(feed, object, opts) when is_map(object) or is_binary(object) do
    case ulid(object) do
      nil ->
        do_feed(feed, opts)
        |> feed_contains?(object, opts)

      id ->
        feed_contains?(feed, [object: id], opts)
    end
  end

  # @decorate time()
  defp prepare_feed(result, opts)

  defp prepare_feed(%{edges: edges} = result, opts)
       when is_list(edges) and edges != [] do
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
      # TODO: try doing this in queries in a way that it's not needed here?
      edges
      # |> Enum.uniq_by(&id(&1))
      |> Enum.uniq_by(&e(&1, :activity, :object_id, nil))
    end
  end

  defp default_query(), do: select(Needle.Pointers.query_base(), [p], p)

  defp base_query(_opts \\ []) do
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

  # defp make_distinct(query, _) do
  # query
  # |> group_by([fp], fp.id)
  # |> select([fp], max(fp.feed_id))
  # end

  defp make_distinct(%Ecto.Query{distinct: distinct} = query, _, _, _opts)
       when not is_nil(distinct) do
    debug("skip because we already have a distinct clause")
    query
  end

  defp make_distinct(query, nil, :asc, _opts) do
    distinct(query, [activity: activity], asc: activity.id)
  end

  defp make_distinct(query, nil, _, _opts) do
    distinct(query, [activity: activity], desc: activity.id)
  end

  defp make_distinct(query, _, :asc, opts) do
    distinct(query, [activity: activity], asc: activity.id)
    |> make_distinct_subquery(opts)
  end

  defp make_distinct(query, _, _, opts) do
    distinct(query, [activity: activity], desc: activity.id)
    |> make_distinct_subquery(opts)
  end

  defp make_distinct_subquery(query, opts) do
    subquery =
      query
      |> repo().make_subquery()

    default_or_filtered_query(opts)
    |> join(:inner, [fp], ^subquery, on: [id: fp.id])
  end

  defp default_or_filtered_query(filters \\ nil, opts) do
    case filters || e(opts, :feed_filters, nil) do
      %Ecto.Query{} = query ->
        query

      _ ->
        default_query()
        |> proload(:activity)
    end
  end

  defp base_or_filtered_query(filters \\ nil, opts) do
    case filters || e(opts, :feed_filters, nil) do
      %Ecto.Query{} = query ->
        query

      _ ->
        base_query(opts)
    end
  end

  # @decorate time()
  # PLEASE: note this query is not boundarised, it is your responsibility to do so in the calling function!
  defp feed_query(feed_id_or_ids, opts) do
    opts = to_feed_options(opts)

    feed_ids = List.wrap(feed_id_or_ids)

    specific_feeds? = is_binary(feed_id_or_ids) or (is_list(feed_id_or_ids) and feed_ids != [])

    local_feed_id = Feeds.named_feed_id(:local)
    federated_feed_id = Feeds.named_feed_id(:activity_pub)
    fetcher_user_id = "1ACT1V1TYPVBREM0TESFETCHER"

    cond do
      :local in feed_ids or local_feed_id in feed_ids ->
        debug("local feed")

        # excludes likes/follows from local feed - TODO: configurable
        Enums.deep_merge(opts, exclude_verbs: [:like, :pin])
        # |> debug("local_opts")
        |> query_extras()
        |> proload(
          activity: [subject: {"subject_", character: [:peered]}, object: {"object_", [:peered]}]
        )
        |> where(
          [fp, activity: activity, subject_peered: subject_peered, object_peered: object_peered],
          (fp.feed_id == ^local_feed_id or
             (is_nil(subject_peered.id) and is_nil(object_peered.id))) and
            activity.subject_id != ^fetcher_user_id
        )

      :activity_pub in feed_ids or federated_feed_id in feed_ids ->
        debug("remote/federated feed")

        Enums.deep_merge(opts, exclude_verbs: [:like, :pin])
        |> query_extras()
        |> proload(
          activity: [subject: {"subject_", character: [:peered]}, object: {"object_", [:peered]}]
        )
        |> where(
          [fp, activity: activity, subject_peered: subject_peered, object_peered: object_peered],
          fp.feed_id == ^federated_feed_id or
            (not is_nil(subject_peered.id) or not is_nil(object_peered.id)) or
            activity.subject_id == ^fetcher_user_id
        )

      specific_feeds? and
          not is_struct(e(opts, :feed_filters, nil)) ->
        debug(feed_id_or_ids, "specific feed(s)")
        generic_feed_query(feed_id_or_ids, opts)

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

  @doc "Return a boundarised query for a feed"
  def query(filters \\ [], opts \\ [], query \\ default_query()) do
    do_query(filters, opts, query)
    |> Activities.as_permitted_for(opts)
  end

  # NOT boundarised!
  defp do_query(filters \\ [], opts \\ [], query \\ default_query())

  # defp do_query([feed_id: feed_id_or_ids], opts) when is_binary(feed_id_or_ids) or is_list(feed_id_or_ids) do
  #   # debug(feed_id_or_ids: feed_id_or_ids)
  #   feed_query(feed_id_or_ids, opts)
  #   do_query([], opts, query)
  # end
  defp do_query(filters, opts, query) when is_list(filters) do
    query
    |> query_extras(opts)
    |> query_filter(filters, nil, nil)

    # |> debug("FeedActivities - query")
  end

  defp do_query(filters, _opts, query) do
    # |> query_extras(current_user)
    # |> query_filter(filters, nil, nil)
    warn(
      query,
      "invalid feed query with filters #{inspect(filters)}"
    )
  end

  @doc "add assocs needed in timelines/feeds"
  def query_extras_boundarised(query \\ nil, opts) do
    query_extras(query, opts)
    |> Activities.as_permitted_for(opts)
    |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
  end

  @doc "add assocs needed in lists of objects"
  def query_object_extras_boundarised(query \\ nil, opts) do
    opts = to_options(opts)
    filters = filters_from_opts(opts)

    (query || base_or_filtered_query(filters, opts))
    |> proload([:activity])
    # |> query_activity_extras(opts)
    |> query_optional_extras(filters, opts)
    |> maybe_filter(filters)
    |> Objects.as_permitted_for(opts)
    |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
  end

  defp query_extras(query \\ nil, opts) do
    opts =
      to_options(opts) ++
        [exclude_table_ids: exclude_object_types(e(opts, :exclude_object_types, []))]

    filters = filters_from_opts(opts)

    (query || base_or_filtered_query(filters, opts))
    |> query_activity_extras(opts)
    |> query_object_extras(opts)
    |> query_optional_extras(filters, opts)
    |> maybe_filter(filters)

    # |> debug("pre-preloads")
    # preload all things we commonly want in feeds
    # |> Activities.activity_preloads(e(opts, :preload, :with_object), opts) # if we want to preload the rest later to allow for caching
    # |> Activities.activity_preloads(e(opts, :preload, :feed), opts)
    # |> debug("post-preloads")
  end

  defp query_activity_extras(query, opts) do
    opts = to_feed_options(opts)
    # current_user = current_user(opts)
    # debug(opts)

    exclude_table_ids =
      opts[:exclude_table_ids] || exclude_object_types(e(opts, :exclude_object_types, []))

    # exclude certain activity types
    exclude_verbs =
      (e(opts, :exclude_verbs, nil) || []) ++
        [:message] ++
        if opts[:include_labelling] do
          debug("include labelling for all")
          []
        else
          debug("do not include labelling")
          [:label]
        end ++
        if opts[:include_flags] == :moderators and
             Bonfire.Boundaries.can?(opts, :mediate, :instance) do
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

    exclude_verb_ids =
      exclude_verbs
      |> List.wrap()
      |> Enum.map(&Bonfire.Social.Activities.verb_id(&1))
      |> Enum.uniq()

    # |> debug("exxclude_verbs")

    # exclude_feed_ids = e(opts, :exclude_feed_ids, []) |> List.wrap() # WIP - to exclude activities that also appear in another feed

    query
    # |> proload([:activity])
    |> reusable_join(:inner, [root], assoc(root, :activity), as: :activity)
    |> reusable_join(:inner, [activity: activity], activity_pointer in Pointer,
      as: :activity_pointer,
      on:
        activity_pointer.id == activity.id and
          is_nil(activity_pointer.deleted_at) and
          activity_pointer.table_id not in ^exclude_table_ids
    )
    # FIXME: are filters already applied in base_or_filtered_query above?
    # where: fp.feed_id not in ^exclude_feed_ids,
    # Don't show messages or anything deleted
    |> where(
      [activity: activity],
      activity.verb_id not in ^exclude_verb_ids
    )
  end

  defp query_object_extras(query, opts) do
    opts = to_feed_options(opts)
    # current_user = current_user(opts)

    # debug(opts)

    exclude_table_ids =
      opts[:exclude_table_ids] || exclude_object_types(e(opts, :exclude_object_types, []))

    query
    |> proload([:activity])
    |> reusable_join(:inner, [activity: activity], object in Pointer,
      as: :object,
      on:
        object.id == activity.object_id and
          is_nil(object.deleted_at) and
          (is_nil(object.table_id) or object.table_id not in ^exclude_table_ids)
    )

    # Don't show messages or anything deleted
  end

  defp query_optional_extras(query, filters, opts) do
    current_user = current_user(opts)

    query
    |> maybe_exclude_mine(current_user)
    |> maybe_exclude_replies(filters, opts)
    |> maybe_only_replies(filters, opts)
    |> maybe_time_limit(opts[:time_limit])
  end

  def exclude_object_types(extras \\ []) do
    # eg. private messages should never appear in feeds
    exclude_object_types = [Message] ++ extras

    exclude_object_types
    |> List.wrap()
    |> Enum.map(&maybe_apply(&1, :__pointers__, :table_id))
    |> Enum.uniq()

    # |> debug("exxclude_tables")
  end

  defp query_order(query, :num_replies = sort_by, sort_order) do
    query
    |> maybe_preload_replied()
    |> Activities.query_order(sort_by, sort_order)
  end

  defp query_order(query, sort_by, sort_order) do
    Activities.query_order(query, sort_by, sort_order)
  end

  defp maybe_time_limit(query, 0), do: query

  defp maybe_time_limit(query, x_days) when is_integer(x_days) do
    limit_pointer =
      DatesTimes.past(x_days, :day)
      |> debug("from date")
      |> Needle.ULID.generate()

    where(query, [activity: activity], activity.id > ^limit_pointer)
  end

  defp maybe_time_limit(query, _), do: query

  defp maybe_filter(query, %{object_type: object_type}) when not is_nil(object_type) do
    case Bonfire.Common.Types.table_types(object_type) |> debug() do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [object: object], object.table_id in ^table_ids)

      other ->
        warn(other, "Unrecognised object_type '#{object_type}'")
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

  defp maybe_exclude_mine(query, me) do
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

  defp maybe_preload_replied(%{aliases: %{replied: _}} = query) do
    query
  end

  defp maybe_preload_replied(query) do
    query
    |> proload(activity: [:replied])
  end

  defp maybe_exclude_replies(query, filters, opts) do
    if e(opts, :exclude_replies, nil) == true or e(filters, :object_type, nil) == "posts" do
      query
      |> maybe_preload_replied()
      |> where(
        [replied: replied],
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
      |> maybe_preload_replied()
      |> where(
        [replied: replied],
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
  #   publish(subject, verb, object, boundary: "public_remote")
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
  #   LivePush.notify(subject, verb_or_activity, object, feed_ids)
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
    fa =
      feeds
      |> Circles.circle_ids()
      |> Enum.map(fn x -> put_in_feeds(x, activity, false) end)

    if push?, do: LivePush.push_activity(feeds, activity)
  end

  defp put_in_feeds(feed_or_subject, activity, push?)
       when is_map(feed_or_subject) or
              (is_binary(feed_or_subject) and feed_or_subject != "") do
    with feed_id <- ulid(feed_or_subject),
         {:ok, published} <- do_put_in_feeds(feed_id, ulid(activity)) do
      # push to feeds of online users
      if push?, do: LivePush.push_activity(feed_id, activity)
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

  @doc "Remove one or more activities from all feeds"
  def delete(objects, by_field) when is_atom(by_field) do
    case ulid(objects) do
      # is_list(id_or_ids) ->
      #   Enum.each(id_or_ids, fn x -> delete(x, by_field) end)
      nil ->
        error(objects, "Nothing to delete")

      objects ->
        debug(objects)
        delete({by_field || :id, objects})
    end
  end

  @doc "Remove activities from feeds, using specific filters"
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
      LivePush.hide_activity(feed_id, activity)
    end
  end

  defp do_maybe_federate_activity(subject, verb, object, activity, opts) do
    if e(opts, :boundary, nil) != "public_remote",
      do:
        Bonfire.Social.Integration.maybe_federate_and_gift_wrap_activity(
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
      if is_ulid?(feed_id),
        do: feed_id,
        else: Bonfire.Social.Feeds.my_feed_id(feed_id, current_user)

    uid = ulid(current_user)

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
    current_user = current_user_required!(opts)

    unseen_query(feed_id, opts)
    ~> select([c], %{id: c.id})
    |> repo().all()
    |> Bonfire.Social.Seen.mark_seen(current_user, ...)
  end
end
