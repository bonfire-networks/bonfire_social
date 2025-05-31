defmodule Bonfire.Social.FeedLoader do
  @moduledoc """
  Determines the appropriate filters, joins, and/or preloads for feed queries based.

  Entrypoint for `Bonfire.Social.Feeds` and `Bonfire.Social.FeedActivities`, and `Bonfire.Social.Activities`.
  """

  use Arrows
  use Untangle
  use Bonfire.Common.E
  use Bonfire.Common.Localise
  use Bonfire.Common.Repo
  import Bonfire.Common.Utils
  use Bonfire.Common.Config
  use Bonfire.Common.Settings
  alias Bonfire.Common.Cache
  alias Bonfire.Common.Enums
  alias Bonfire.Common.Types
  alias Bonfire.Data.Social.Activity
  alias Bonfire.Data.Social.FeedPublish
  alias Bonfire.Data.Social.Message
  alias Bonfire.Data.Social.Seen
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social
  alias Bonfire.Social.Activities
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedFilters
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Threads
  alias Needle.Pointer

  # ==== START OF CODE TO REFACTOR ====
  def prepare_feed_filters(preset \\ nil, feed_name, opts) do
    with {:ok, _preset, filters} <- prepare_feed_preset_and_filters(preset, feed_name, opts) do
      {:ok, filters}
    end
  end

  def prepare_feed_preset_and_filters(preset \\ nil, feed_name, opts)

  def prepare_feed_preset_and_filters(%{} = preset, filters, opts) do
    prepare_feed_preset_and_filters({:ok, preset}, filters, opts)
  end

  def prepare_feed_preset_and_filters(preset, feed_name, opts)
      when (not is_nil(feed_name) and is_atom(feed_name)) or is_binary(feed_name) do
    prepare_feed_preset_and_filters(preset, %{feed_name: feed_name}, opts)
  end

  def prepare_feed_preset_and_filters(
        preset_tuple,
        %{feed_name: feed_name} = custom_filters,
        opts
      )
      when (not is_nil(feed_name) and is_atom(feed_name)) or is_binary(feed_name) or
             is_tuple(preset_tuple) do
    opts =
      to_options(opts)
      |> debug("opts with data for parameters")

    case (preset_tuple ||
            Bonfire.Social.Feeds.feed_preset_if_permitted(feed_name, opts))
         |> debug("feed_definition") do
      {:ok, %{parameterized: %{} = parameters, filters: preset_filters} = preset} ->
        preset_filters
        |> merge_feed_filters(custom_filters, opts[:feed_filters])
        |> parameterize_filters(parameters, opts)
        |> merge_some_defaults(opts)
        |> debug("merged feed_filters")
        |> FeedFilters.validate()
        |> debug("validated & parameterized feed_filters")
        ~> {:ok, preset, ...}

      {:ok, %{filters: preset_filters} = preset} ->
        preset_filters
        |> merge_feed_filters(custom_filters, opts[:feed_filters])
        |> merge_some_defaults(opts)
        |> debug("merged feed_filters")
        |> FeedFilters.validate()
        |> debug("validated feed_filters")
        ~> {:ok, preset, ...}

      {:error, :not_found} ->
        prepare_feed_preset_and_filters(nil, custom_filters |> Map.put(:feed_name, nil), opts)

      {:error, e} ->
        error(e)
    end
  end

  def prepare_feed_preset_and_filters(preset, %{feed_name: nil} = custom_filters, opts) do
    opts = to_options(opts)
    debug(custom_filters, "custom filters")

    custom_filters
    |> merge_feed_filters(opts[:feed_filters])
    |> merge_some_defaults(opts)
    |> debug("merged feed_filters")
    |> FeedFilters.validate()
    |> debug("validated custom feed_filters")
    ~> {:ok, preset, ...}
  end

  @doc """
  Gets a feed based on filters and options.

  ## Parameters
  - `name_or_filters` - A map of filter parameters (see `FeedFilters` for the list of supported filters) or a feed name atom/string if no other filters are needed
  - `opts` - Options that aren't filter-related

  ## Examples

      iex> %{edges: _, page_info: %Paginator.PageInfo{}} = feed(:explore)

      iex> %{edges: _, page_info: %Paginator.PageInfo{}} = feed(%{feed_name: :explore})

      > feed("feed123", [])
      %{edges: [%{activity: %{}}], page_info: %Paginator.PageInfo{}}

  """
  @spec feed(map() | atom() | String.t(), Keyword.t()) :: map()
  def feed(feed_name, %{feed_name: feed_name} = filters, opts) when is_list(opts) do
    feed(filters, opts)
  end

  def feed(feed_name, filters, opts) when is_list(opts) do
    feed(filters |> Map.put(:feed_name, feed_name), opts)
  end

  def feed(name_or_filters \\ nil, opts \\ [])

  def feed(:curated, opts) do
    # TODO: refactor to use `feed_filtered` like any others rather than delegating to the context
    Bonfire.Social.Pins.list_instance_pins(opts)
    # |> debug()
  end

  # def feed(:likes, opts) do
  #   # TODO: refactor to use `feed_filtered` like any others rather than delegating to the context
  #   Bonfire.Social.Likes.list_my(opts)
  #   # |> debug()
  # end

  # def feed(:bookmarks, opts) do
  #   # TODO: refactor to use `feed_filtered` like any others rather than delegating to the context
  #   Bonfire.Social.Bookmarks.list_my(opts)
  #   # |> debug()
  # end

  # def feed(:flags, opts) do
  #   # TODO: refactor to use `feed_filtered` like any others rather than delegating to the context
  #   Bonfire.Social.Flags.list_preloaded(opts ++ [include_flags: :mediate])
  # end

  def feed(%FeedFilters{} = filters, opts) when is_list(opts) do
    with preset <-
           opts[:feed_preset] ||
             (case Bonfire.Social.Feeds.feed_preset_if_permitted(filters, opts) do
                {:ok, preset} -> preset
                _ -> %{}
              end),
         # NOTE: we're not calling prepare_feed_filters/3 here because they must have already been prepared/validated since we're getting a FeedFilters struct
         {filters, opts} <-
           prepare_filters_and_opts(filters, Keyword.merge(opts, preset[:opts] || [])) do
      case preset[:base_query_fun] || opts[:base_query_fun] do
        fun when is_function(fun, 0) ->
          fun.()

        fun when is_function(fun, 1) ->
          fun.(opts)

        _ ->
          filters[:feed_name] || preset[:filters][:feed_name]
      end
      |> feed_filtered(filters, opts)
    else
      e ->
        error(e, "Could not process pre-prepared filters")
        # feed(%{feed_name: nil}, opts)
    end
  end

  def feed(%{} = filters, opts) when is_list(opts) do
    feed_name =
      filters[:feed_name]
      |> debug("feed_name")

    with {:ok, preset} <- Bonfire.Social.Feeds.feed_preset_if_permitted(filters, opts),
         {:ok, %FeedFilters{} = filters} <- prepare_feed_filters(preset, filters, opts) do
      feed(filters, Keyword.put(opts, :feed_preset, preset))
    else
      {:error, :not_found} when is_nil(feed_name) or feed_name == :custom ->
        filters
        |> Map.put(:feed_name, nil)
        |> prepare_feed_filters(opts)
        ~> feed(opts)

      # {:error, %Ecto.Changeset{} = cs} ->
      #   warn(filters, "Invalid filters")
      #   error(cs, "Could not validate feed filters")

      {:error, e} ->
        {:error, e}

      e ->
        error(e, "Could not find a preset for `#{feed_name}` or could not prepare filters")
        # feed(%{feed_name: nil}, opts)
    end
  end

  def feed([feed_name], opts)
      when ((not is_nil(feed_name) and is_atom(feed_name)) or is_binary(feed_name)) and
             is_list(opts),
      do: feed(feed_name, opts)

  def feed({feed_name, feed_id_or_ids}, opts)
      when is_atom(feed_name) and not is_nil(feed_name) and is_list(opts) do
    warn(feed_id_or_ids, "should we do something with feed_id_or_ids?")

    feed(%{feed_name: feed_name}, opts)
  end

  def feed(feed_name, opts)
      when ((not is_nil(feed_name) and is_atom(feed_name)) or is_binary(feed_name)) and
             is_list(opts) do
    feed(%{feed_name: feed_name}, opts)
  end

  def feed(custom_filters, opts)
      when (is_list(custom_filters) or is_map(custom_filters) or is_nil(custom_filters)) and
             is_list(opts) do
    # debug(custom_filters)
    Enum.into(custom_filters || %{}, %{feed_name: default_feed_name(opts)})
    |> feed(opts)
  end

  # def feed(%{id: feed_id}, opts), do: feed(feed_id, opts)

  # def feed(%{feed_publishes: _} = feed_for, _) do
  #   repo().maybe_preload(feed_for, [feed_publishes: [activity: [:verb, :object, subject_user: [:profile, :character]]]]) |> Map.get(:feed_publishes)
  # end

  #  TODO
  # def feed(:media, opts) do
  #   feed(
  #     {:media, :all},
  #     opts
  #   )
  # end
  # def feed({:media, type}, opts) do
  #   opts =
  #     opts
  #     |> Keyword.merge(
  #       # per_media_type: type, # TODO for filtering different types of media
  #       preload: List.wrap(e(opts, :preload, [])) ++ [:per_media]
  #     )

  #   feed(:explore, opts)
  # end

  defp merge_some_defaults(filters, opts) do
    # WIP: optimise by only loading if none is set in preset_filters/custom_filters
    current_user = current_user(opts)

    filters
    |> Map.put(
      :sort_by,
      filters[:sort_by] || opts[:sort_by] ||
        Settings.get([Bonfire.UI.Social.FeedLive, :sort_by], nil,
          current_user: current_user,
          name: l("Default Sort Order"),
          description: l("Default sorting order for feeds.")
        )
    )
    |> Map.put(
      :time_limit,
      filters[:time_limit] || opts[:time_limit] ||
        Settings.get([Bonfire.UI.Social.FeedLive, :time_limit], 7,
          current_user: current_user,
          name: l("Default Time Limit"),
          description: l("Default time window for feed content (in days).")
        )
    )
    |> debug("set sort_by and time_limit")
  end

  defp merge_feed_filters(nil, feed_filters), do: feed_filters
  defp merge_feed_filters(custom_filters, nil), do: custom_filters

  defp merge_feed_filters(custom_filters, feed_filters) do
    # Enums.merge_to_struct(FeedFilters, custom_filters, opts[:feed_filters] || %{})
    Enums.merge_as_map(
      Enums.filter_empty_enum(feed_filters, true) |> Map.new() |> debug("m0"),
      Enums.filter_empty_enum(custom_filters, true) |> Map.new() |> debug("m1")
    )
    |> debug("m2")
  end

  # TODO: optimise
  defp merge_feed_filters(preset_filters, custom_filters, feed_filters) do
    # Enums.merge_to_struct(FeedFilters, preset_filters, merge_feed_filters(custom_filters, feed_filters) |> debug("m1"))
    Enums.merge_as_map(
      preset_filters,
      merge_feed_filters(custom_filters, feed_filters)
    )
    |> debug("m3")
  end

  def skip_verbs_default,
    do:
      Bonfire.Common.Config.get([Bonfire.Social.Feeds, :skip_verbs], [:flag, :message],
        name: l("Feeds"),
        description: l("Verbs to exclude by default")
      )

  def skip_types_default,
    do:
      Bonfire.Common.Config.get([Bonfire.Social.Feeds, :skip_types], [Message],
        name: l("Feeds"),
        description: l("Object types to exclude by default")
      )

  def feed_filtered(feed_name, filters, opts) when is_atom(feed_name) and not is_nil(feed_name) do
    debug(feed_name, "Starting feed with name")

    {feed_ids, opts} =
      feed_ids_and_opts(feed_name, opts)
      |> debug("feed_ids_and_opts")

    feed_filtered(feed_ids, filters, opts)
  end

  def feed_filtered({feed_name, feed_id_or_ids}, filters, opts)
      when is_atom(feed_name) and not is_nil(feed_name) and
             (is_binary(feed_id_or_ids) or is_list(feed_id_or_ids)) do
    {feed_ids, opts} =
      feed_ids_and_opts({feed_name, feed_id_or_ids}, opts)
      |> debug("feed_ids_and_opts")

    feed_filtered(feed_ids, filters, opts)
  end

  def feed_filtered({feed_name, nil}, filters, opts) do
    feed_filtered(feed_name, filters, opts)
  end

  def feed_filtered({feed_name, feed_name_again}, filters, opts)
      when is_atom(feed_name) and not is_nil(feed_name) and is_atom(feed_name_again) do
    feed_filtered(feed_name, filters, opts)
  end

  # def feed_filtered(
  #       _feed,
  #       %Bonfire.Social.FeedFilters{base_query_fun: base_query_fun} = filters,
  #       opts
  #     )
  #     when is_function(base_query_fun) do
  #   feed_filtered(base_query_fun.(), filters, opts)
  # end

  def feed_filtered(%Ecto.Query{} = custom_query, filters, opts) do
    # opts = to_feed_options(filters, opts)

    custom_query
    |> proload([:activity])
    |> query_extras(filters, opts)
    |> paginate_and_boundarise_feed(filters, opts)
    |> prepare_feed(filters, opts)
  end

  def feed_filtered({feed_name, %{} = extra_filters}, filters, opts) do
    feed_filtered(feed_name, Map.merge(filters, extra_filters), opts)
  end

  def feed_filtered(id_or_ids, filters, opts)
      when is_binary(id_or_ids) or (is_list(id_or_ids) and id_or_ids != []) do
    if Keyword.keyword?(id_or_ids) do
      id_or_ids
      |> debug("id_or_idsss")
      |> feed_name_or_default(opts)
      |> debug("kkkk")
      |> feed_filtered(filters, opts)
    else
      debug(opts, "feed_opts for #{id_or_ids}")

      Types.uid_or_uids(id_or_ids)
      |> do_feed(filters, opts)
    end
  end

  def feed_filtered(
        nil,
        %Bonfire.Social.FeedFilters{feed_name: {:notifications, _} = feed_name} = filters,
        opts
      )
      when not is_nil(feed_name) do
    feed_filtered(feed_name, filters, opts)
  end

  def feed_filtered(other, filters, opts) do
    case other do
      :custom ->
        # For custom feeds, directly use the filters without looking up presets
        query_extras(filters, opts)
        |> paginate_and_boundarise_feed(filters, opts)
        |> prepare_feed(filters, opts)

      _ ->
        warn(other, "Not a recognised feed to query, defaulting to explore?")
        debug(filters, "with any provided filters")
        # raise e
        query_extras(filters, opts)
        |> paginate_and_boundarise_feed(filters, opts)
        |> prepare_feed(filters, opts)
    end
  end

  @doc """
  Returns a page of feed activities (reverse chronological) + pagination metadata

  TODO: consolidate with `feed/2`?

  ## Examples

      iex> %{edges: _, page_info: %{}} = feed_paginated([], [])

      iex> query = Ecto.Query.from(f in Bonfire.Data.Social.FeedPublish)
      iex> %{edges: _, page_info: %{}} = feed_paginated([], base_query: query)

  """
  def feed_paginated(filters \\ %{}, opts \\ []) do
    opts = to_options(opts)
    filters = Map.new(filters)

    do_query(filters, opts, opts[:base_query] || default_query())
    # |> debug("feed query")
    |> paginate_and_boundarise_feed(filters, opts)

    # |> prepare_feed(filters, opts)
  end

  @doc """
  Returns paginated results for the given query.

  ## Examples

      > feed_many_paginated(query, opts)
      %{edges: edges, page_info: page_info}
  """
  def feed_many_paginated(query, filters, opts) do
    do_feed_many_paginated(query, filters, prepare_opts_for_pagination(query, filters, opts))
  end

  defp prepare_opts_for_pagination(query, filters, opts) do
    opts = to_options(opts)

    deferred_join_multiply_limit = opts[:deferred_join_multiply_limit]

    if is_integer(deferred_join_multiply_limit) and
         deferred_join_multiply_limit > 1 do
      paginate_and_boundarise_feed_deferred_multiplied_opts(deferred_join_multiply_limit, opts)
      |> info("paginate the deferred join window from the get-go")
    else
      opts
    end
    |> Keyword.merge(
      Activities.order_pagination_opts(filters[:sort_by], filters[:sort_order])
      |> debug("pagination opts")
    )
  end

  defp do_feed_many_paginated(query, filters, opts) do
    Social.many(
      query,
      # |> debug("feed query"),
      opts[:paginate] || opts,
      opts
    )
  end

  @decorate time()
  defp paginate_and_boundarise_feed(query, filters, opts) do
    debug("Starting paginate_and_boundarise_feed")

    opts =
      prepare_opts_for_pagination(query, filters, opts)
      |> Keyword.put_new_lazy(:query_with_deferred_join, fn ->
        Config.get([Bonfire.Social.Feeds, :query_with_deferred_join], true,
          name: l("Use Deferred Joins"),
          description: l("Technical setting for query performance optimization.")
        )
      end)

    #   time_limit = e(debug(filters), :time_limit, nil)

    # opts =
    #   opts
    #   |> Keyword.put_new(
    #     :infinite_pages,
    #     opts[:query_with_deferred_join] || (is_integer(time_limit) and
    #     time_limit != 0)
    #   )
    #   |> debug("prepared opts")

    case opts[:return] do
      :explain ->
        (maybe_paginate_and_boundarise_feed_deferred_query(query, filters, opts) ||
           paginate_and_boundarise_feed_non_deferred_query(query, filters, opts))
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
        # deferred_opts =
        #   opts
        #   |> Keyword.put(
        #     :infinite_pages,
        #     true
        #     # !!Settings.get([:ui, :infinite_scroll], :preload, opts)
        #   )

        # NOTE: `infinite_pages = true` tells Paginator to always give us an `after` cursor, needed with deferred join since there may be more activities available than those that the join window is allowing Paginator to see

        with %Ecto.Query{} = deferred_query <-
               maybe_paginate_and_boundarise_feed_deferred_query(query, filters, opts),
             %{edges: []} <-
               do_feed_many_paginated(
                 deferred_query,
                 filters,
                 opts
               ) do
          # WIP: Try paginating to the next window of results if the initial one is empty
          paginate_and_boundarise_feed_deferred_fallback(query, filters, opts)
        else
          nil ->
            debug("deferred join is not enabled")

            paginate_and_boundarise_feed_non_deferred_query(query, filters, opts)
            |> do_feed_many_paginated(filters, opts)

          %Ecto.Query{} = query ->
            query

          result ->
            debug("we got results")

            result
        end
    end
  end

  defp maybe_paginate_and_boundarise_feed_deferred_query(initial_query, filters, opts) do
    # tries to speed up queries by applying filters (incl. pagination) in a deferred join before boundarising and extra joins/preloads

    if Keyword.get(opts, :query_with_deferred_join) do
      if Enum.any?(initial_query.joins, &(&1.as == :deferred_join_subquery)),
        do: throw("Feed query already deferred")

      initial_query =
        initial_query
        # |> debug()
        |> Ecto.Query.exclude(:select)
        |> select([:id])
        |> make_distinct(filters[:sort_by], filters[:sort_order], opts)
        |> FeedActivities.query_order(filters[:sort_by], filters[:sort_order])
        |> do_feed_many_paginated(
          filters,
          opts
          |> Keyword.merge(
            paginate: true,
            return: :query,
            multiply_limit: opts[:deferred_join_multiply_limit] || 2
          )
        )
        |> offset(^(opts[:deferred_join_offset] || 0))
        |> repo().make_subquery()

      # |> debug("deferred subquery")

      default_or_filtered_query(FeedActivities.base_query(opts), opts)
      |> join(:inner, [fp], ^initial_query, on: [id: fp.id], as: :deferred_join_subquery)
      # NOTE make_distinct needs to come before preloads as it may create a subquery
      |> make_distinct(filters[:sort_by], filters[:sort_order], opts)
      |> Activities.activity_preloads(
        opts[:preload],
        opts
      )
      |> FeedActivities.query_order(filters[:sort_by], filters[:sort_order])
      |> Activities.as_permitted_for(opts)

      # |> IO.inspect(label: "feed query")
      # |> debug("query with deferred join")
    end
  end

  defp paginate_and_boundarise_feed_deferred_multiplied_opts(
         previous_deferred_join_multiply_limit \\ nil,
         deferred_join_multiply_limit,
         opts
       ) do
    # Create new pagination options with the cursor from the empty result
    deferred_join_multiply_limit =
      case deferred_join_multiply_limit do
        0 -> 2
        limit when is_integer(limit) -> limit
        _ -> 2
      end

    Keyword.merge(
      repo().pagination_opts(opts),
      [
        # after: after_cursor,
        # Increase the limit to fetch more results 
        deferred_join_multiply_limit: deferred_join_multiply_limit,
        # Change the pagination offset to match - FIXME: shouldn't this use the previous limit?
        deferred_join_offset:
          (previous_deferred_join_multiply_limit || 2) *
            (opts[:limit] || Bonfire.Common.Config.get(:default_pagination_limit, 10))
      ]
      |> info("Empty results in first join window, attempting pagination to next window")
    )
  end

  defp paginate_and_boundarise_feed_deferred_fallback(query, filters, opts) do
    # WIP: Try paginating to the next window of results if the initial one is empty

    previous_deferred_join_multiply_limit = opts[:deferred_join_multiply_limit] || 2

    next_page_opts =
      paginate_and_boundarise_feed_deferred_multiplied_opts(
        previous_deferred_join_multiply_limit,
        previous_deferred_join_multiply_limit * 2,
        opts
      )

    # Try the query again with the new cursor
    with %Ecto.Query{} = deferred_query <-
           maybe_paginate_and_boundarise_feed_deferred_query(query, filters, next_page_opts),
         %{edges: []} <-
           do_feed_many_paginated(
             deferred_query,
             filters,
             next_page_opts
           ) do
      info("No results in next window either, falling back to non-deferred query")

      paginate_and_boundarise_feed_non_deferred_query(query, filters, opts)
      |> do_feed_many_paginated(filters, opts)
    end
  end

  defp paginate_and_boundarise_feed_non_deferred_query(query, filters, opts) do
    query
    |> make_distinct(filters[:sort_by], filters[:sort_order], opts)
    |> Activities.activity_preloads(
      opts[:preload],
      opts
    )
    |> Activities.as_permitted_for(opts)
    |> FeedActivities.query_order(filters[:sort_by], filters[:sort_order])
    |> info("non_deferred query")

    # |> debug()
  end

  @doc """
  Gets a user's home feed, a combination of all feeds the user is subscribed to.

  # TODO: should just be an alias to `feed(:my, opts)`

  ## Examples

      > Bonfire.Social.FeedActivities.my_feed([current_user: %{id: "user123"}])
      %{edges: [%{activity: %{}}], page_info: %{}}

      > Bonfire.Social.FeedActivities.my_feed([current_user: %{id: "user123"}], ["feed_id1", "feed_id2"])
      %{edges: [%{activity: %{}}], page_info: %{}}
  """
  def my_feed(opts, home_feed_ids \\ nil) do
    debug("1. Starting my_feed")

    opts =
      opts
      |> to_options()
      |> Keyword.put_new(:home_feed_ids, home_feed_ids)
      |> debug("1a. my_feed opts")

    feed(:my, opts)
  end

  defp do_feed(feed_id_or_ids_or_name, filters, opts) do
    debug("3. Starting do_feed")

    # opts =
    #   to_feed_options(filters, opts)
    #   |> debug("3a. feed options")

    if opts[:cache] do
      # FIXME: key should include filters
      key = feed_id_or_ids_or_name

      case Cache.get!(key) do
        nil ->
          debug(key, "querying and putting in cache")
          Cache.put(key, actually_do_feed(feed_id_or_ids_or_name, filters, opts))

        feed ->
          debug(key, "got from cache")
          feed
      end
    else
      debug("do not cache")
      |> debug("doof")

      actually_do_feed(feed_id_or_ids_or_name, filters, opts)
    end
  end

  defp actually_do_feed(feed_id_or_ids_or_name, filters, opts) do
    debug("4. Starting actually_do_feed")

    feed_id_or_ids_or_name
    |> feed_query(filters, opts)
    |> paginate_and_boundarise_feed(filters, opts)
    |> prepare_feed(filters, opts)
  end

  # def filters_from_opts(opts) do
  #   Enums.input_to_atoms(
  #     e(opts, :feed_filters, nil) || e(opts, :__context__, :current_params, nil) || %{}
  #   )
  # end

  # @decorate time()
  @doc """
  Gets feed ids and options for the given feed or list of feeds.

  # TODO: this should be replaced by feed presets
  ## Examples

      > feed_ids_and_opts(feed_name, opts)
      {feed_ids, opts}

      > feed_ids_and_opts({feed_name, feed_id}, opts)

      > feed_ids_and_opts(:my, [current_user: me])
      {["feed_id1", "feed_id2"], [exclude_activity_types: [:flag, :boost, :follow]]}

      > feed_ids_and_opts({:notifications, "feed_id3"}, [current_user: me])
      {"feed_id3", [include_flags: true, exclude_activity_types: false, show_objects_only_once: false, preload: [:notifications]]}


  """
  def feed_ids_and_opts(feed_name, opts)

  def feed_ids_and_opts({:my, feed_ids}, opts) do
    feed_ids_and_opts(:my, opts ++ [home_feed_ids: feed_ids])
  end

  def feed_ids_and_opts(:my, opts) do
    # opts = to_feed_options(filters, opts)

    home_feed_ids =
      if is_list(opts[:home_feed_ids]),
        do: opts[:home_feed_ids],
        else: Feeds.my_home_feed_ids(opts)

    {home_feed_ids, opts}
  end

  # def feed_ids_and_opts(:notifications = feed_name, opts) do
  #   feed_ids_and_opts(
  #     {:notifications,
  #      named_feed_ids(
  #        feed_name,
  #        opts
  #      )},
  #     opts
  #   )
  # end

  # def feed_ids_and_opts({:notifications, feed_id}, opts) do
  #   opts =
  #     opts
  #     |> Keyword.merge(
  #       # so we can show flags to admins in notifications
  #       skip_boundary_check: :admins,
  #       include_flags: true,
  #       exclude_verb_ids: false,
  #       exclude_activity_types: false,
  #       show_objects_only_once: false
  #       # preload: List.wrap(e(opts, :preload, [])) ++ [:notifications]
  #     )

  #   {feed_id, opts}
  # end

  def feed_ids_and_opts(feed_name, opts) when is_atom(feed_name) and not is_nil(feed_name) do
    {named_feed_ids(
       feed_name,
       opts
     ), opts}
  end

  def feed_ids_and_opts({feed_name, feed_id}, opts)
      when is_atom(feed_name) and not is_nil(feed_name) and
             (is_binary(feed_id) or is_list(feed_id)) do
    {feed_id, opts}
  end

  def feed_ids_and_opts(feed, opts) when is_binary(feed) or is_list(feed) do
    {feed, opts}
  end

  def default_feed_name(opts) do
    current_user = current_user(opts)

    if not is_nil(current_user) do
      # || current_account(socket)
      # my feed
      Settings.get(
        [Bonfire.UI.Social.FeedLive, :default_feed],
        :my,
        current_user: current_user,
        name: l("Default Feed"),
        description: l("Default feed to display when visiting the feed page.")
      )
    else
      # fallback to showing instance feed
      :local
    end

    # |> debug("default feed to load:")
  end

  def feed_name_or_default(name, opts) when is_nil(name) or name == :default do
    default_feed_name(opts)
  end

  def feed_name_or_default(name, _opts) when is_atom(name) or is_binary(name) do
    name
  end

  def feed_name_or_default(filters, opts) do
    case e(filters, :feed_name, nil) || e(filters, :feed_id, nil) || e(filters, :feed_ids, nil) ||
           e(filters, :id, nil) |> debug("fffff") do
      nil ->
        throw("Unexpected feed id(s)")

      name ->
        feed_name_or_default(name, opts)
    end
  end

  defp named_feed_ids(feed_name, opts \\ [])
  defp named_feed_ids(:explore, _opts), do: nil

  defp named_feed_ids(feed_name, opts)
       when is_atom(feed_name) and not is_nil(feed_name) do
    # current_user = current_user(current_user_or_socket)
    case Feeds.named_feed_id(feed_name, opts) || Feeds.my_feed_id(feed_name, opts) do
      feed when is_binary(feed) or is_list(feed) ->
        # debug(uid(current_user(opts)), "current_user")
        # debug(feed_name, "feed_name")
        debug(feed, "feed id(s)")
        feed

      itself when itself == feed_name ->
        Feeds.my_feed_id(feed_name, opts) ||
          (
            debug(feed_name, "not an internal feed")
            nil
          )

      e ->
        error(e, "not a known feed: `#{inspect(feed_name)}`")

        debug(opts)
        nil
    end
  end

  defp default_query(), do: select(Needle.Pointers.query_base(), [p], p)

  defp default_or_filtered_query(filtered \\ nil, default_query, opts) do
    case filtered || e(opts, :feed_filters, nil) do
      %Ecto.Query{} = query ->
        query

      _ ->
        default_query
        |> proload(:activity)
    end
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

  defp make_distinct(query, id, :asc, _opts) when is_nil(id) or id == false or id == :id do
    distinct(query, [activity: activity], asc: activity.id)
  end

  defp make_distinct(query, id, _desc, _opts) when is_nil(id) or id == false or id == :id do
    distinct(query, [activity: activity], desc: activity.id)
  end

  defp make_distinct(query, other, :asc, opts) do
    debug(other, "making a subquery to show distinct activities with field other than :id")

    distinct(query, [activity: activity], asc: activity.id)
    |> make_distinct_subquery(opts)
  end

  defp make_distinct(query, other, _desc, opts) do
    debug(other, "making a subquery to show distinct activities with field other than :id")

    distinct(query, [activity: activity], desc: activity.id)
    |> make_distinct_subquery(opts)
  end

  defp make_distinct_subquery(query, opts) do
    # FIXME: if `query` already has some preloads those should be applied at the top level
    subquery =
      query
      |> repo().make_subquery()

    default_or_filtered_query(default_query(), opts)
    |> join(:inner, [fp], ^subquery, on: [id: fp.id])
  end

  # @decorate time()
  # PLEASE: note this query is not boundarised, it is your responsibility to do so in the calling function!
  defp feed_query(feed_id_or_ids, filters, opts) do
    debug("5. Starting feed_query")

    # opts = to_feed_options(filters, opts)

    specific_feed_ids = Types.uids(feed_id_or_ids)

    local_feed_id = Feeds.named_feed_id(:local)
    federated_feed_id = Feeds.named_feed_id(:activity_pub)
    # fetcher_user_id = "1ACT1V1TYPVBREM0TESFETCHER"

    cond do
      # NOTE: made into local and remote filters instead
      # :local in feed_ids or local_feed_id in feed_ids ->
      #   debug("local feed")

      #   # excludes likes/etc from local feed - TODO: configurable
      #   Enums.deep_merge(filters, exclude_activity_types: [:like, :pin])
      #   # |> debug("local_opts")
      #   |> query_extras(..., opts)
      #   |> proload(
      #     activity: [subject: {"subject_", character: [:peered]}, object: {"object_", [:peered]}]
      #   )
      #   |> where(
      #     [fp, activity: activity, subject_peered: subject_peered, object_peered: object_peered],
      #     (fp.feed_id == ^local_feed_id or
      #        (is_nil(subject_peered.id) and is_nil(object_peered.id))) and
      #       activity.subject_id != ^fetcher_user_id
      #   )

      # :activity_pub in feed_ids or federated_feed_id in feed_ids ->
      #   debug("remote/federated feed")

      #   Enums.deep_merge(filters, exclude_activity_types: [:like, :pin])
      #   |> query_extras(..., opts)
      #   |> proload(
      #     activity: [subject: {"subject_", character: [:peered]}, object: {"object_", [:peered]}]
      #   )
      #   |> where(
      #     [fp, activity: activity, subject_peered: subject_peered, object_peered: object_peered],
      #     fp.feed_id == ^federated_feed_id or
      #       (not is_nil(subject_peered.id) or not is_nil(object_peered.id)) or
      #       activity.subject_id == ^fetcher_user_id
      #   )

      :local in specific_feed_ids or :activity_pub in specific_feed_ids or
        federated_feed_id in specific_feed_ids or local_feed_id in specific_feed_ids ->
        debug(feed_id_or_ids, "local or remote feed")

        query_extras(filters, opts)

      specific_feed_ids != [] ->
        debug(feed_id_or_ids, "specific feed(s)")

        query_extras(filters, opts)
        |> where([fp], fp.feed_id in ^specific_feed_ids)
        |> debug("generic with ids")

      true ->
        debug(feed_id_or_ids, "unknown feed")

        query_extras(filters, opts)
    end
    |> debug("feed query")
  end

  @doc "Return a boundarised query for a feed"
  def query(filters \\ [], opts \\ [], query \\ default_query()) do
    do_query(filters, opts, query)
    |> Activities.as_permitted_for(opts)
  end

  # NOT boundarised!
  defp do_query(filters \\ [], opts \\ [], query \\ default_query())

  defp do_query(filters, opts, query) when is_list(filters) or is_map(filters) do
    query
    |> query_extras(filters, opts)
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

  # @doc "add assocs needed in timelines/feeds"
  # def query_extras_boundarised(query \\ nil, filters, opts) do
  #   query_extras(query, filters, opts)
  #   |> Activities.as_permitted_for(opts)
  #   |> Activities.activity_preloads(
  #     opts[:preload],
  #     opts
  #   )
  # end

  @doc "add assocs needed in lists of objects"
  def query_object_extras_boundarised(query \\ nil, filters, opts) do
    # opts = to_options(opts)

    (query || default_or_filtered_query(filters, FeedActivities.base_query(opts), opts))
    |> proload([:activity])
    |> maybe_filter(filters)
    |> query_optional_extras(filters, opts)
    |> Objects.as_permitted_for(opts)
    |> Activities.activity_preloads(
      opts[:preload],
      opts
    )
  end

  defp query_extras(query \\ nil, filters, opts) do
    # exclude_feed_ids = e(opts, :exclude_feed_ids, []) |> List.wrap() # WIP - to exclude activities that also appear in another feed

    (query || default_or_filtered_query(filters, FeedActivities.base_query(opts), opts))
    |> reusable_join(:inner, [root], assoc(root, :activity), as: :activity)
    |> proload([:activity])
    |> query_optional_extras(filters, opts)
    |> maybe_filter(filters, opts)

    # where: fp.feed_id not in ^exclude_feed_ids,

    # |> debug("pre-preloads")
    # preload all things we commonly want in feeds
    # |> Activities.activity_preloads(e(opts, :preload, :with_object), opts) # if we want to preload the rest later to allow for caching
    # |> Activities.activity_preloads(opts[:preload], opts)
    # |> debug("post-preloads")
  end

  @doc """
  Converts socket, assigns, or options to feed options.

  ## Examples

      > assigns = %{exclude_activity_types: [:flag, :boost]}
      > to_feed_options(filters, assigns)
      [exclude_activity_types: [:flag, :boost, :follow]]
  """
  def prepare_filters_and_opts(filters, opts) do
    opts = to_options(opts)
    current_user = current_user(opts)

    preload =
      case opts[:preload] do
        false ->
          []

        preloads when is_list(preloads) ->
          preloads

        _ ->
          contextual_preloads_from_filters(filters, opts[:preload_context] || :query)
          |> debug("preloads to apply based on filters")
      end

    # postload = opts[:postload] || contextual_preloads_from_filters(filters, :post)

    include_flags =
      opts[:include_flags]
      |> debug("include_flags?")

    skip_boundary_check =
      case include_flags do
        :admins -> maybe_apply(Bonfire.Me.Accounts, :is_admin?, [opts], fallback_return: nil)
        nil -> false
        false -> false
        verb when is_atom(verb) or is_list(verb) -> Bonfire.Boundaries.can?(opts, verb, :instance)
        _ -> false
      end
      |> debug("skip_boundary_check?")

    {filters
     |> Map.put_new_lazy(:exclude_table_ids, fn ->
       Objects.prepare_exclude_object_types(
         e(filters, :exclude_object_types, []) ++ e(opts, :exclude_object_types, []),
         skip_types_default()
       )
     end)
     |> Map.put_new_lazy(:exclude_verb_ids, fn ->
       exclude_activity_types =
         debug(
           opts[:exclude_activity_types] || filters[:exclude_activity_types],
           "exclude_activity_typess"
         )

       if exclude_activity_types == false or exclude_activity_types == [false] do
         []
       else
         exclude_activity_types =
           List.wrap(exclude_activity_types)
           |> List.flatten()

         activity_types =
           List.wrap(filters[:activity_types] || opts[:activity_types])
           |> List.flatten()

         #  if(
         #    :follow in exclude_activity_types or
         #      (:follow not in activity_types and
         #         !Bonfire.Common.Settings.get(
         #           [Bonfire.Social.Feeds, :include, :follow],
         #           false,
         #           current_user: current_user,
         #           name: l("Include Follows in Feed"),
         #           description: l("Show follow activities in your feed.")
         #         )),
         #    do: [:follow],
         #    else: [exclude_activity_types]
         #  ) ++
         #  if(
         #    :boost in exclude_activity_types or
         #      (:boost not in activity_types and
         #         !Bonfire.Common.Settings.get(
         #           [Bonfire.Social.Feeds, :include, :boost],
         #           true,
         #           current_user: current_user,
         #           name: l("Include Boosts in Feed"),
         #           description: l("Show boosted/reshared content in your feed.")
         #         )),
         #    do: [:boost],
         #    else: []
         #  ) ++
         #  if(
         #    :reply in exclude_activity_types or
         #      (:reply not in activity_types and
         #         !Bonfire.Common.Settings.get(
         #           [Bonfire.Social.Feeds, :include, :reply],
         #           true,
         #           current_user: current_user,
         #           name: l("Include Replies in Feed"),
         #           description: l("Show reply activities in your feed.")
         #         )),
         #    do: [:reply],
         #    else: []
         #  ) ++
         exclude_activity_types =
           exclude_activity_types ++
             if(:label in activity_types or opts[:include_labelling],
               do: [],
               else: [:label]
             ) ++
             (if include_flags == true or skip_boundary_check do
                []
              end || skip_verbs_default())

         # end

         exclude_activity_types
         |> List.flatten()
         |> Enums.filter_empty([])
         |> debug("computed exclude_activity_types")
         |> Enum.map(&Bonfire.Social.Activities.verb_id(&1))
         |> Enum.uniq()
       end
     end)
     #  |> Map.put_new(
     #    :skip_boundary_check,
     #    skip_boundary_check
     #  )
     |> Map.drop([:exclude_object_types, :exclude_activity_types]),
     opts
     |> Keyword.merge(
       preload: preload,
       skip_boundary_check: skip_boundary_check
       #  postload: postload
     )}
    |> debug("feed query filters & opts")
  end

  defp maybe_filter(query, filters, opts \\ [])

  defp maybe_filter(query, filters, opts) when is_list(filters) or is_map(filters) do
    #  TODO: put in config
    priority_filters_ordered = [:exclude_object_types, :exclude_table_ids]

    {to_run_first, remaining} =
      Enums.struct_to_map(filters)
      |> Map.drop([:__typename])
      |> Map.split(priority_filters_ordered)
      |> debug("filters to apply")

    query
    |> do_apply_filters(priority_filters_ordered, to_run_first, opts)
    |> proload(activity: [:object])
    |> do_apply_filters(Map.keys(remaining), remaining, opts)
    # |> FeedActivities.query_filter(Keyword.drop(filters, @skip_warn_filters))
    |> debug("query with Activities & Objects filters applied")
  end

  defp maybe_filter(query, filters, _opts) do
    # cond do

    #   # is_list(filters) or (is_map(filters) and Map.keys(filters) |> List.first() |> is_atom()) ->
    #   #   debug(filters, "no known extra filters defined")
    #   #   query

    #   # true ->
    #   #   filters
    #     # |> debug("filters")
    #     # |> Enums.input_to_atoms()
    #     # |> debug("as atoms")
    #     # |> maybe_filter(query, ...)

    #   true ->
    warn(filters, "no supported filters defined")
    query
    # end
  end

  defp do_apply_filters(query, filter_keys, filter_map, opts) do
    Enum.reduce(filter_keys, query, fn filter_key, query ->
      filter = {filter_key, Map.get(filter_map, filter_key)}

      query
      # |> maybe_filter(filter, opts)
      |> Activities.maybe_filter(filter, opts)
      |> debug("Activities filter #{inspect(filter_key)} applied")
      #  TODO: can we avoid loading the object if not needed by a filter?
      # |> proload(activity: [:object])
      |> Objects.maybe_filter(filter, opts)
      |> debug("Objects filter #{inspect(filter_key)} applied")
    end)
  end

  defp query_optional_extras(query, filters, opts) do
    current_user = current_user(opts)

    query
    |> FeedActivities.query_maybe_exclude_mine(current_user)
    # |> Threads.maybe_filter(
    #   filters,
    #   opts |> Keyword.put(:replied_preload_fun, &FeedActivities.maybe_preload_replied/1)
    # )
    |> Objects.query_maybe_time_limit(
      info(e(filters, :time_limit, nil) || opts[:time_limit], "apply_time_limit")
    )
  end

  def feed_contains?(feed_name, object, opts \\ [])

  def feed_contains?({:error, e}, object, opts) do
    error(e, "Feed returned an error")
    false
  end

  def feed_contains?(%{edges: []}, object, opts) do
    debug("empty feed")
    false
  end

  def feed_contains?([], object, opts) do
    debug("empty list")
    false
  end

  def feed_contains?(%{edges: edges}, object, opts) when is_list(edges) and edges != [] do
    debug(edges, "edges")
    feed_contains?(edges, object, opts)
  end

  def feed_contains?(feed, objects_or_filters, opts)
      when is_list(objects_or_filters) and objects_or_filters != [] do
    debug(objects_or_filters, "some kinda list")

    if Keyword.keyword?(objects_or_filters) and is_atom(feed) do
      case feed_contains_many(feed, objects_or_filters, opts) do
        [] -> false
        items -> items
      end
    else
      Enum.all?(objects_or_filters, &feed_contains?(feed, &1, opts))
    end
  end

  def feed_contains?(feed, id_or_html_body, opts)
      when is_list(feed) and (is_binary(id_or_html_body) or is_struct(id_or_html_body)) do
    debug(id_or_html_body, "id_or_html_body")

    q_id =
      e(id_or_html_body, :object_id, nil) || Enums.id(e(id_or_html_body, :object, nil)) ||
        e(id_or_html_body, :activity, :object_id, nil) ||
        Enums.id(e(id_or_html_body, :activity, :object, nil)) || Types.uid(id_or_html_body)

    q_body =
      if is_map(id_or_html_body) do
        e(id_or_html_body, :post_content, :html_body, nil) ||
          e(id_or_html_body, :object, :post_content, :html_body, nil) ||
          e(id_or_html_body, :activity, :object, :post_content, :html_body, nil)
      else
        if !q_id, do: id_or_html_body
      end
      |> debug("q_body")

    feed =
      if opts[:postload] != false do
        feed
        |> repo().maybe_preload(activity: [object: [:post_content]])
      else
        feed
      end

    feed
    |> Enum.find_value(fn fi ->
      a_body =
        e(fi.activity, :object, :post_content, :html_body, nil)
        |> debug("a_body")

      if q_id do
        if fi.activity.object_id == q_id, do: fi.activity
      else
        if(
          a_body && q_body &&
            a_body =~ q_body,
          do: fi.activity
        )
      end
    end) ||
      (
        dump(
          feed
          |> Enum.map(fn fi ->
            # e(fi, :activity, :object, nil) ||
            e(fi, :activity, :object, :post_content, nil) ||
              e(fi, :activity, nil) || fi
          end),
          "object `#{q_body}` with ID `#{q_id}` not found in feed containing"
        )

        false
      )
  end

  def feed_contains?(feed, object, opts) when is_map(object) or is_binary(object) do
    # debug(object, "object")
    opts = to_options(opts)

    case Types.uid(object) do
      nil ->
        debug(
          object,
          "assume we want to look up a string in the object fields, so query the feed first"
        )

        feed_contains_many(feed, opts[:feed_filters] || %{}, opts)
        |> feed_contains?(object, opts)

      id ->
        debug(id, "lookup by ID")

        feed_contains?(feed, [objects: id], opts)
        |> feed_contains?(object, opts)
    end
  end

  def feed_contains_single?(feed_name, filters, opts)
      when (is_atom(feed_name) and is_list(filters)) or is_map(filters) do
    case feed_contains_query(feed_name, filters, opts) do
      %Ecto.Query{} = query ->
        repo().one(query)

      # |> id()
      e ->
        error(e)
    end
  end

  defp feed_contains_many(feed_name, filters, opts) do
    case feed_contains_query(feed_name, filters, opts) do
      %Ecto.Query{} = query -> repo().many(query)
      e -> error(e)
    end
  end

  defp feed_contains_query(feed_name, filters, opts) when is_list(filters) or is_map(filters) do
    opts = to_options(opts)
    feed(feed_name, Enum.into(filters, %{time_limit: 0}), Keyword.put(opts, :return, :query))

    # {feed_ids, opts} = feed_ids_and_opts(feed_name, to_options(opts) ++ [limit: 10])

    # feed_query(
    #   feed_ids,
    #   Map.new(filters),
    #   opts
    # )
    # |> Activities.as_permitted_for(opts)
  end

  @doc """
  Returns the count of items in a feed based on given filters and options.

  ## Examples

      > count(filters, current_user: me)
      10
  """
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

  @doc """
  Returns the count of distinct subjects in a feed based on given filters and options.

  ## Examples

      > count_subjects(filters, opts)
      3
  """
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

  @decorate time()
  defp prepare_feed(result, filters, opts)

  defp prepare_feed(%{edges: edges, page_info: page_info}, filters, opts)
       when is_list(edges) and edges != [] do
    # debug(edges, "7a. edges to prepare")

    edges =
      if filters[:show_objects_only_once] != false and opts[:show_objects_only_once] != false do
        info(length(edges), "Starting prepare_feed with N edges")

        # TODO: try doing this in queries in a way that it's not needed here?

        edges
        # |> debug("Starting prepare_feed with #{length(edges)} edges")
        # |> Enum.uniq_by(&id(&1))
        |> Enum.uniq_by(
          &(e(&1, :activity, :object_id, nil) || e(&1, :activity, :id, nil) || Enums.id(&1))
        )

        # |> debug("deduped edges")
      else
        edges
      end

    # |> debug("7b. after dedup")

    # TODO: where best to do these postloads? and try to optimise into one call

    # |> Bonfire.Common.Needles.Preload.maybe_preload_nested_pointers(
    #   [activity: [replied: [:reply_to]]],
    #   opts
    # )
    # |> Bonfire.Common.Needles.Preload.maybe_preload_nested_pointers(
    #   [activity: [:object]],
    #   opts
    # )
    # |> repo().maybe_preload(
    #   # FIXME: this should happen in `Activities.activity_preloads`
    #   [activity: Activities.maybe_with_labelled()],
    #   opts |> Keyword.put_new(:follow_pointers, false)
    # )

    # run post-preloads to follow pointers and catch anything else missing - TODO: only follow some pointers
    # |> Activities.activity_preloads(opts[:preload], opts |> Keyword.put_new(:follow_pointers, true))
    # |> Activities.activity_preloads(opts[:preload], opts |> Keyword.put_new(:follow_pointers, false))

    %{edges: Activities.prepare_subject_and_creator(edges, opts), page_info: page_info}
  end

  defp prepare_feed(%Ecto.Query{} = query, _filters, _opts) do
    query
  end

  defp prepare_feed(result, _filters, _opts) do
    info(result, "seems like empty feed")
    # debug(result, "seems like empty feed")
    result
  end

  # ==== END OF CODE TO REFACTOR ====

  @doc """
  Gets an aliased feed's filters by name, with optional parameters.

  ## Examples

      # 1: Retrieve a preset feed without parameters
      iex> {:ok, %{feed_name: :local}} = preset_feed_filters(:local, [])

      # 1: Retrieve a preset feed without parameters
      iex> {:ok, %{feed_name: :local}} =preset_feed_filters(:local, [])

      # 2: Retrieve a preset feed with parameters
      iex> {:ok, %{subjects: ["alice"]}} = preset_feed_filters(:user_activities, [by: "alice"])

      # 3: Feed not found (error case)
      iex> preset_feed_filters("unknown_feed", [])
      {:error, :not_found}

      # 4: Preset feed with parameterized filters
      iex> {:ok, %{activity_types: [:like], subjects: [%{id: "alice"}]}} = preset_feed_filters(:likes, current_user: %{id: "alice"})

      # 5: Feed with `current_user_required` should check for current user
      iex> {:ok, %{activity_types: [:flag]}} = preset_feed_filters(:my_flags, current_user: %{id: "alice"})

      # 6: Feed with `current_user_required` and no current user
      iex> preset_feed_filters(:my_flags, [])
      {:error, :unauthorized}
      # ** (Bonfire.Fail.Auth) You need to log in first. 

      # 7: Custom feed with additional parameters
      iex> {:ok, %{activity_types: [:follow], objects: ["alice"]}} = preset_feed_filters(:user_followers, [by: "alice"])

  """
  @spec preset_feed_filters(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def preset_feed_filters(name, opts \\ []) do
    case Bonfire.Social.Feeds.feed_preset_if_permitted(name, opts) do
      {:error, e} ->
        {:error, e}

      {:ok, %{parameterized: %{} = parameters, filters: filters}} ->
        {:ok, parameterize_filters(filters, parameters, opts)}

      {:ok, %{filters: filters}} ->
        {:ok, filters}
    end
  end

  @doc """
  Parameterizes the filters by replacing parameterized values with values from `opts`.

  ## Examples

      # 1: Parameterizing a simple filter
      iex> parameterize_filters(%{}, %{subjects: [:me]}, current_user: %{id: "alice"})
      %{subjects: [%{id: "alice"}]}

      # 2: Parameterizing multiple filters
      iex> parameterize_filters(%{}, %{subjects: [:me], tags: [:tags]}, current_user: %{id: "alice"}, tags: "elixir")
      %{subjects: [%{id: "alice"}], tags: ["elixir"]}

      # 3: Parameterizing with undefined options
      iex> parameterize_filters(%{}, %{subjects: :me}, current_user: nil)
      %{subjects: nil}

      # 4: Handling filters that don't require parameterization
      iex> parameterize_filters(%{activity_types: ["like"]}, %{}, current_user: "bob")
      %{activity_types: ["like"]}
  """
  def parameterize_filters(filters, parameters, opts) when is_struct(parameters),
    do: parameterize_filters(filters, Enums.struct_to_map(parameters), opts)

  def parameterize_filters(filters, parameters, opts) when is_list(filters),
    do: parameterize_filters(Map.new(filters), parameters, opts)

  def parameterize_filters(filters, parameters, opts) do
    parameters =
      parameters
      |> debug()
      |> Enum.map(fn
        {k, v} when is_list(v) ->
          # TODO: optimise by not iterating over params already set in filters
          existing_v = ed(filters, k, :none) |> debug("existing?")

          {k,
           if existing_v == :none or existing_v == v or List.wrap(existing_v) == v do
             Enum.map(v, &replace_parameters(&1, filters, opts))
             |> List.flatten()
             |> debug("replaced")
           else
             existing_v
           end}

        {k, v} ->
          existing_v = ed(filters, k, :none) |> debug("existing?")

          {k,
           if existing_v == :none or existing_v == v or List.wrap(v) == existing_v do
             replace_parameters(v, filters, opts)
             |> debug("replaced")
           else
             existing_v
           end}
      end)
      |> Map.new()

    Map.merge(filters, parameters)
  end

  @doc """
  Replaces parameters in the filter value with the actual values from `opts`.

  ## Examples

      # Replacing a `me` parameter with the current user
      iex> replace_parameters(:me, %{}, current_user: %{id: "alice"})
      %{id: "alice"}

      # Replacing a `:current_user` parameter with the current user only if available
      iex> replace_parameters(:current_user, %{}, current_user: nil)
      nil

      # Replacing a `by` parameter with the a value from the filters
      iex> replace_parameters(:by, %{by: %{id: "alice"}}, [])
      %{id: "alice"}

      # Replacing a `by` parameter with the a value from the opts
      iex> replace_parameters(:by, %{}, by: %{id: "alice"})
      %{id: "alice"}

      # (Currently disabled:) Replacing a `:by` parameter with the current user as a fallback
      # iex> replace_parameters(:by, %{}, current_user: %{id: "alice"})
      # %{id: "alice"}

      # Failing with `:current_user_required` parameter if we have no current user
      iex> replace_parameters(:current_user_required, %{}, current_user: nil)
      ** (Bonfire.Fail.Auth) You need to log in first. 

      # Handling a parameter that is in the opts
      iex> replace_parameters(:type, %{}, type: "post")
      "post"

      # Handling a parameter that is in the filters
      iex> replace_parameters(:type, %{type: "post"}, [])
      "post"

      # Handling a parameter that is in the filters with string key
      iex> replace_parameters(:type, %{"type"=> "post"}, [])
      "post"

      # # Handling a string key parameter that is in the filters
      # iex> replace_parameters("type", %{type: "post"}, [])
      # "post"

      # # Handling a string key parameter that is in the opts - FIXME
      # iex> replace_parameters("type", %{}, type: "post")
      # "post"

      # Handling a parameter that is not in the opts
      iex> replace_parameters(:unknown, %{}, current_user: "bob")
      :unknown
  """
  def replace_parameters(:current_user, _filters, opts) do
    current_user(opts)
  end

  def replace_parameters(:me, _filters, opts) do
    current_user(opts)
  end

  def replace_parameters(:current_user_required, _filters, opts) do
    current_user_required!(opts)
  end

  def replace_parameters(:by, filters, opts) do
    e(filters, :by, fn ->
      debug(
        filters,
        "parameter `:by` was not found in filters"
      )

      e(opts, :by, fn ->
        error(
          opts,
          "parameter `:by` was not found in filters or opts, defaulting to current_user if available instead"
        )

        # current_user(opts)

        raise "Dunno who's feed to show"
      end)
    end)
  end

  def replace_parameters(value, filters, opts) do
    ed(filters, value, fn ->
      ed(opts, value, fn ->
        warn(filters, "parameter #{inspect(value)} was not found in filters")
        error(opts, "parameter #{inspect(value)} was not found (in filters or) opts")
        value
      end)
    end)
  end

  def replace_parameters(value, _filters, _params), do: value

  def preloads_from_filters_rules do
    # Default Rules, TODO: move to config
    Config.get([__MODULE__, :preload_rules], %{},
      name: l("Preload Rules"),
      description: l("Rules for preloading data based on filters (technical setting).")
    )
  end

  def preloads_by_context_rules do
    # Default Rules, TODO: move to config
    Config.get([__MODULE__, :preload_by_context], %{},
      name: l("Context Preload Rules"),
      description: l("Rules for preloading data based on context (technical setting).")
    )
  end

  def contextual_preloads_from_filters(
        feed_filters,
        context,
        context_rules \\ preloads_by_context_rules()
      ) do
    preloads_from_filters =
      preloads_from_filters(feed_filters)

    # |> debug("all preloads for filter")

    case context_rules[context] do
      context_preloads when is_list(context_preloads) and context_preloads != [] ->
        context_preloads = MapSet.new(context_preloads)

        preloads_from_filters
        |> Enum.filter(&MapSet.member?(context_preloads, &1))

      nil ->
        preloads_from_filters
    end
    |> debug("contextual (#{inspect(context)}) preloads for filter")
  end

  @doc """
  Computes the list of preloads to apply based on the provided filters.
  Returns a list of preload atoms.

  Uses rules defined in configuration rather than code.

  Multiple rules can match and their preloads will be merged, with exclusions applied last.

  ## Examples

      iex> filters = %{feed_name: "remote"}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [:with_creator, :with_media, :with_object_more, :with_object_peered, :with_reply_to, :with_subject]

      iex> filters = %{subjects: ["alice"]}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [:with_creator, :with_media, :with_object_more, :with_object_peered, :with_reply_to]

      iex> filters = %{feed_name: "unknown"}
      iex> preloads_from_filters(filters) |> Enum.sort()
      [
        :with_creator,
        :with_media,
        :with_object_more,
        :with_object_peered,
        :with_reply_to,
        :with_subject
      ]

  """
  def preloads_from_filters(feed_filters, filter_rules \\ preloads_from_filters_rules()) do
    preload_rules_from_filters(feed_filters, filter_rules)
    |> merge_rules()
    |> apply_exclusions()
    |> Enum.sort()
  end

  defp preload_rules_from_filters(feed_filters, rules \\ preloads_from_filters_rules()) do
    Enum.filter(rules, fn {_name, %{match: rule_match}} ->
      matches_filter?(rule_match, feed_filters)
    end)
  end

  @doc """
  Match feed filters against rule criteria.

  ## Examples

      iex> matches_filter?(%{types: "*"}, %{types: "post"})
      true

      iex> matches_filter?(%{types: ["post", "comment"]}, %{types: ["comment", "reaction"]})
      true

      iex> matches_filter?(%{types: "post"}, %{types: ["comment", "post"]})
      true

      iex> matches_filter?(%{types: :post}, %{types: ["comment", "post"]})
      true

      iex> matches_filter?(%{types: "post"}, %{types: [:comment, :post]})
      true

      iex> matches_filter?(%{types: ["post"]}, %{types: "post"})
      true

      iex> matches_filter?(%{types: "post"}, %{types: "comment"})
      false

      iex> matches_filter?(%{types: :post}, %{types: "post"})
      true
  """
  def matches_filter?(rule_match_criteria, feed_filters) do
    Enum.all?(rule_match_criteria, fn {key, rule_value} ->
      with filter_value <- ed(feed_filters, key, nil) do
        cond do
          is_nil(rule_value) and is_nil(filter_value) ->
            true

          is_nil(filter_value) ->
            false

          # Wildcard match
          rule_value == "*" ->
            true

          # Direct match
          filter_value == rule_value ->
            true

          # Both are lists - check for any intersection
          is_list(rule_value) and is_list(filter_value) ->
            rule_set = MapSet.new(rule_value, &normalize_value/1)
            filter_set = MapSet.new(filter_value, &normalize_value/1)
            not MapSet.disjoint?(rule_set, filter_set)

          # Rule is list, filter is single - check membership
          is_list(rule_value) ->
            MapSet.new(rule_value, &normalize_value/1)
            |> MapSet.member?(normalize_value(filter_value))

          # Filter is list, rule is single - check membership
          is_list(filter_value) ->
            MapSet.new(filter_value, &normalize_value/1)
            |> MapSet.member?(normalize_value(rule_value))

          # String equality after normalization
          true ->
            normalize_value(filter_value) == normalize_value(rule_value)
        end
      end
    end)
  end

  # Helper to normalize values to strings for comparison
  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value), do: to_string(value)

  defp merge_rules([]), do: %{include: [], exclude: []}

  defp merge_rules(rules) do
    Enum.reduce(rules, %{include: [], exclude: []}, fn {_name, rule}, acc ->
      %{
        include: acc.include ++ Map.get(rule, :include, []),
        exclude: acc.exclude ++ Map.get(rule, :exclude, [])
      }
    end)
  end

  defp apply_exclusions(%{include: includes, exclude: excludes}) do
    includes
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(excludes))
    |> MapSet.to_list()
  end

  def preload_presets do
    Config.get(
      [__MODULE__, :preload_presets],
      [],
      name: l("Feed Preload Presets"),
      description: l("Predefined preload settings for feeds (technical setting).")
    )
  end

  @doc """
  Maps high-level preload keys to their corresponding detailed preload lists.

  ## Examples

      # Single preload key
      iex> map_activity_preloads([:feed]) |> Enum.sort()
      [
        :with_creator,
        :with_media,
        :with_object_more,
        :with_replied,
        :with_subject
      ]

      # Multiple preload keys
      iex> map_activity_preloads([:feed, :notifications]) |> Enum.sort()
      [:notifications, :with_creator, :with_media, :with_object_more, :with_replied, :with_subject]

      # With :all key it includes all defined preloads
      iex> map_activity_preloads([:all]) |> Enum.sort()
      [
        :maybe_with_labelled,
        :tags,
        :with_creator,
        :with_media,
        :with_object_more,
        :with_parent,
        :with_post_content,
        :with_replied,
        :with_reply_to,
        :with_seen,
        :with_subject,
        :with_thread_name,
        :with_verb
      ]

      # With unknown key
      iex> map_activity_preloads([:unknown_key])
      [:unknown_key]

      # Empty list returns empty list
      iex> map_activity_preloads([])
      []

      # Removes duplicates when preload lists overlap
      iex> map_activity_preloads([:posts, :posts_with_thread]) |> Enum.sort()
      [
        :with_post_content,
        :with_replied,
        :with_subject,
        :with_thread_name
      ]
  """
  def map_activity_preloads(
        preloads,
        already_preloaded \\ [],
        preload_presets \\ preload_presets()
      )

  def map_activity_preloads(preloads, already_preloaded, preload_presets)
      when (is_list(preloads) and is_list(preload_presets)) or is_map(preload_presets) do
    already_preloaded = MapSet.new(already_preloaded || [])

    if Enum.member?(preloads, :all) do
      Enums.fun(preload_presets, :keys)
    else
      preloads
      |> do_filter_already_preloaded(already_preloaded)
    end
    |> do_map_preloads(preload_presets, MapSet.new())
    # TODO: optimise
    |> do_filter_already_preloaded(already_preloaded)
  end

  defp do_map_preloads(preloads, mappings, seen) when is_list(preloads) do
    preloads
    |> Enum.flat_map(fn preload ->
      if MapSet.member?(seen, preload) do
        # Prevent infinite recursion
        []
      else
        case ed(mappings, preload, nil) do
          expanded when is_list(expanded) ->
            # Add current preload to seen set to prevent cycles
            seen = MapSet.put(seen, preload)
            # Recursively expand any mapped keys in the result
            do_map_preloads(expanded, mappings, seen)

          _ ->
            # Not a mapped key, return as-is
            [preload]
        end
      end
    end)
    |> Enum.uniq()
  end

  def filter_already_preloaded(preloads, already_preloaded) do
    already_preloaded = MapSet.new(already_preloaded || [])

    (preloads || [])
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(already_preloaded, &1)))
  end

  defp do_filter_already_preloaded(preloads, already_preloaded) do
    (preloads || [])
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(already_preloaded, &1)))
  end
end
