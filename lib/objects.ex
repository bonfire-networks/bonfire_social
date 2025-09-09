defmodule Bonfire.Social.Objects do
  @moduledoc """
  Generic helpers for querying and mutating objects.

  This module provides functions for working with social objects, including:
  - Casting common associations when creating objects
  - Reading and querying objects
  - Deleting objects
  - Publishing and setting boundaries
  - Handling ActivityPub federation
  """

  use Arrows

  use Bonfire.Common.Repo,
    schema: Needle.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]

  use Bonfire.Common.Utils
  import Untangle
  import Bonfire.Boundaries.Queries

  alias Bonfire.Common
  alias Bonfire.Data.Identity.Caretaker
  alias Bonfire.Data.Identity.CareClosure
  alias Bonfire.Data.Social.Activity
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Tags
  alias Bonfire.Social.Threads

  alias Needle.Changesets
  alias Needle.Pointer

  alias Bonfire.Epics.Epic

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module, do: ["Delete", {"Create", "Tombstone"}]

  @doc """
  Casts various attributes for an object changeset.

  Handles casting:
  - Creator
  - Caretaker
  - Threaded replies (when present)
  - Tags/Mentions (when present)
  - ACLs
  - Activity

  ## Examples

      iex> cast(changeset, %{}, user, [])
      %Ecto.Changeset{}

  """
  def cast(changeset, attrs, creator, opts) do
    # debug(creator, "creator")
    changeset
    |> cast_creator_caretaker(creator)
    # record replies & threads. preloads data that will be checked by `Acls`
    |> Threads.cast(attrs, creator, opts)
    # record tags & mentions. uses data preloaded by `PostContents`
    |> Tags.maybe_cast(attrs, creator, opts)
    # apply boundaries on all objects, note that ORDER MATTERS, as it uses data preloaded by `Threads` and `PostContents`
    |> cast_acl(creator, opts)
    |> cast_activity(attrs, creator, opts)

    # |> debug()
  end

  def cast_acl(changeset, creator, opts) do
    Acls.cast(changeset, creator, opts)
  end

  defp cast_activity(changeset, %{id: id} = attrs, creator, opts)
       when is_binary(id) do
    changeset
    # manually set the ULID of the object (which will be the same as the Activity ID)
    |> Changeset.cast(attrs, [:id])
    # create activity & put in feeds
    |> Activities.cast(Map.get(attrs, :verb, :create), creator, opts)
  end

  defp cast_activity(changeset, attrs, creator, opts) do
    # TODO: generate 
    Map.put_new_lazy(attrs, :id, fn -> Needle.UID.generate(Activity) end)
    |> cast_activity(changeset, ..., creator, opts)
  end

  def cast_creator(changeset, creator),
    do: cast_creator(changeset, creator, uid(creator))

  defp cast_creator(changeset, _creator, nil), do: changeset

  defp cast_creator(changeset, _creator, creator_id) do
    Changesets.put_assoc(changeset, :created, %{creator_id: creator_id})
  end

  def cast_caretaker(changeset, caretaker),
    do: cast_caretaker(changeset, caretaker, uid(caretaker))

  defp cast_caretaker(changeset, _caretaker, nil), do: changeset

  defp cast_caretaker(changeset, _caretaker, caretaker_id) do
    Changesets.put_assoc(changeset, :caretaker, %{caretaker_id: caretaker_id})
  end

  def cast_creator_caretaker(changeset, user) do
    changeset
    |> cast_creator(user)
    |> cast_caretaker(user)
  end

  @doc """
  Reads an object by its ID.

  ## Examples

      iex> read("123", [])
      {:ok, %{id: "123", activity: %{}}}

  """
  def read(object_id, opts) when is_binary(object_id) do
    # |> debug
    opts =
      to_options(opts)
      |> Keyword.merge(skip_opts_check: true, verbs: [:read])

    Common.Needles.pointer_query([id: object_id], opts)
    # |> debug()
    |> Activities.read(
      opts
      |> Keyword.put(:skip_boundary_check, true)
      # ^ skipping because Needles.pointer_query already checks the boundary
    )
    # |> debug("object with activity")
    ~> maybe_preload_activity_object(opts)
    ~> to_ok()

    # |> debug("final object")
  end

  def read(%Ecto.Query{} = query, opts \\ []) do
    opts =
      to_options(opts)
      |> Keyword.put(:verbs, [:read])

    with {:ok, object} <-
           query
           |> Activities.read_query(opts)
           |> as_permitted_for(opts)
           #  |> debug("q")
           |> repo().single() do
      {:ok,
       object
       |> maybe_preload_activity_object(opts)}
    end
  end

  def maybe_preload_activity_object(
        %{activity: %{object: %{id: _}}} = pointer,
        opts
      ) do
    pointer
    |> Activities.prepare_subject_and_creator(opts)
    |> Common.Needles.Preload.maybe_preload_nested_pointers(
      [activity: [:object]],
      opts
    )
    |> Activities.activity_under_object()
  end

  def maybe_preload_activity_object(pointer, opts),
    do:
      pointer
      |> Activities.prepare_subject_and_creator(opts)
      |> Activities.activity_under_object()

  @doc """
  Preloads the reply creator for an object.

  ## Examples

      iex> preload_reply_creator(%Object{})
      %Object{replied: %{reply_to: ...}}

  """
  def preload_reply_creator(object) do
    object
    # |> debug
    |> repo().maybe_preload(replied: [reply_to: [created: [creator: [:character]]]])
    # |> repo().maybe_preload([replied: [:reply_to]]) #|> debug
    # |> debug
    #  FIXME: is this loaded the same creator twice?
    |> repo().maybe_preload(replied: [reply_to: [creator: [:character]]])
  end

  @doc """
  Preloads the creator for an object.

  ## Examples

      iex> preload_creator(%Object{})
      %Object{}

  """
  def preload_creator(activity, opts \\ [])
  # TODO: does not take permissions into consideration
  def preload_creator(%Activity{} = activity, opts) do
    activity
    |> repo().maybe_preload([:subject, object: [created: [creator: [:character]]]], opts)
  end

  def preload_creator(%{created: _} = object, opts) do
    object
    |> repo().maybe_preload([created: [creator: [:character]]], opts)
  end

  def preload_creator(%{creator: _} = object, opts) do
    object
    |> repo().maybe_preload([creator: [:character]], opts)
  end

  def preload_creator(%{activity: _} = object, opts) do
    # debug("preload_creator starting with type: #{inspect(object.__struct__)}")

    # NOTE: not sure we need this? First resolve if it's a Pointer using Bonfire.Common.Needles
    # case object do
    #   %Needle.Pointer{} ->
    #     # Use Bonfire.Common.Needles for proper pointer resolution
    #     Common.Needles.follow!(object) || object

    #   _ ->
    #     object
    # end

    # Preload all creator-related associations at once
    object
    |> repo().maybe_preload(
      [activity: [:subject, object: [created: [creator: [:character]]]]],
      opts
    )
  end

  def preload_creator(object, _opts) do
    warn(object, "unrecognised object, skipping creator preload")
    object
  end

  @doc """
  Gets the creator of an object (if preloaded)

  ## Examples

      iex> object_creator(%Object{})
      %User{}

  """
  def object_creator(%{} = object_or_activity) do
    # debug(object_or_activity, "object_creator: checking object")

    e(object_or_activity, :created, :creator, nil) || e(object_or_activity, :creator, nil) ||
      e(object_or_activity, :object, :created, :creator, nil) ||
      e(object_or_activity, :activity, :object, :created, :creator, nil) ||
      e(object_or_activity, :post_content, :created, :creator, nil) ||
      e(object_or_activity, :subject, nil) || e(object_or_activity, :activity, :subject, nil)
  end

  def object_creator(object_id) when is_binary(object_id) do
    # Look up the object by ID and get its creator
    object =
      repo().get(Created, object_id)
      |> repo().maybe_preload([:creator])
      |> e(:creator, nil)
  end

  def query_maybe_time_limit(query, 0), do: query

  def query_maybe_time_limit(query, x_days) when is_integer(x_days) do
    # we add 12h of leeway 
    with limit_pointer when is_binary(limit_pointer) <-
           DatesTimes.past(x_days * 24 + 12, :hour)
           # |> info("from date")
           |> DatesTimes.generate_ulid()
           |> debug("date-based UID") do
      where(query, [activity: activity], activity.id > ^limit_pointer)
    else
      e ->
        error(e)
        raise ArgumentError, "Invalid time limit"
    end
  end

  def query_maybe_time_limit(query, x_days) when is_binary(x_days) do
    query_maybe_time_limit(query, Types.maybe_to_integer(x_days))
  end

  def query_maybe_time_limit(query, _), do: query

  @doc """
  Lists objects in a paginated manner.

  ## Examples

      iex> list_paginated([object_types: :post], [])
      %Page{}

  """
  def list_paginated(filters, opts \\ [])

  def list_paginated(%Ecto.Query{} = query, opts) do
    # debug(opts)
    list_query(query, opts)
    |> FeedLoader.feed_many_paginated(%{}, opts)
  end

  def list_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    # debug(opts)
    list_query(filters, opts)
    |> FeedLoader.feed_many_paginated(filters, opts)
  end

  def list_query(type_or_query \\ nil, opts)

  def list_query(%Ecto.Query{} = query, opts) do
    debug(query)
    FeedLoader.query_object_extras_boundarised(query, opts)
  end

  def list_query(type, opts) when is_atom(type) do
    debug(type)

    query_base(type)
    |> list_query(opts)
  end

  def list_query(filters, opts) do
    warn(filters, "TODO: do something with these?")

    query_base()
    |> list_query(opts)
  end

  def maybe_filter(query, filters, opts \\ [])

  def maybe_filter(query, filters, opts) when is_list(filters) or is_map(filters) do
    # filters = Keyword.new(filters)
    # |> debug("filters")

    Enum.reduce(filters, query, &maybe_filter(&2, &1, opts))
    # |> query_filter(Keyword.drop(filters, @skip_warn_filters))
    |> debug()
  end

  # doc "List objects created by a user and which are in their outbox, which are not replies"
  def maybe_filter(query, {:creators, user}, _opts) do
    case uid(user) do
      nil ->
        query

      id ->
        # user = repo().maybe_preload(user, [:character])
        verb_id = Verbs.get_id!(:create)

        query
        |> proload(activity: [:object, :replied])
        |> where(
          [activity: activity, replied: replied],
          is_nil(replied.reply_to_id) and
            activity.verb_id == ^verb_id and
            activity.subject_id == ^id
        )
    end
  end

  # def maybe_filter(query, {:objects, object}, _opts) do
  #   # TODO? for cases where we're not already filtering by object_id in Activities.maybe_filter
  #   query
  #   # case Types.uid_or_uids(object) do
  #   #   id when is_binary(id) ->
  #   #     where(query, [object: object], object.id == ^id)

  #   #   ids when is_list(ids) and ids != [] ->
  #   #     where(query, [object: object], object.id in ^ids)

  #   #   _ ->
  #   #     query
  #   # end
  # end

  # def maybe_filter(query, {:exclude_object_types, types}, opts) do
  #   # TODO? for cases where we're not already filtering by table_ids in Activities.maybe_filter
  #   case prepare_object_types(types)
  #        |> debug("exclude_object_types_tables") do
  #     {table_ids, []} when is_list(table_ids) and table_ids != [] ->
  #       maybe_filter(query, {:exclude_table_ids, table_ids}, opts)

  #       other ->
  #         warn(other, "Unrecognised prepare_object_types for '#{inspect types}'")
  #       query
  #   end
  # end

  # def maybe_filter(query, {:exclude_object_types, types}, _opts) do
  #   # TODO? for cases where we're not already filtering by object_id in Activities.maybe_filter
  #   query
  # end

  # def maybe_filter(query, {:exclude_table_ids, table_ids}, _opts)
  #     when is_list(table_ids) and table_ids != [] do
  #   # TODO? for cases where we're not already filtering by table_ids in Activities.maybe_filter
  #   query
  #   # |> reusable_join(:inner, [activity: activity], object in Pointer,
  #   #   as: :object,
  #   #   # Don't show certain object types (like messages) or anything deleted
  #   #   on:
  #   #     object.id == activity.object_id and
  #   #       is_nil(object.deleted_at) and object.table_id not in ^table_ids
  #   # )
  # end

  def maybe_filter(query, {:media_types, types}, _opts) when is_list(types) and types != [] do
    case prepare_media_type(types) do
      :all ->
        query
        |> Activities.join_per_media(:inner)
        |> proload(:left, activity: [:media])
        |> where([media: media], not is_nil(media.media_type))

      [first | rest] ->
        rest
        |> Enum.reduce(
          query
          |> Activities.join_per_media(:inner)
          |> proload(:left, activity: [:media])
          |> where([media: media], ilike(media.media_type, ^"#{first}%")),
          fn type, query ->
            or_where(query, [media: media], ilike(media.media_type, ^"#{type}%"))
          end
        )

      other ->
        warn(other, "Unrecognised media type")
        query
    end
  end

  def maybe_filter(query, {:exclude_media_types, types}, opts)
      when is_list(types) and types != [] do
    case prepare_media_type(types) do
      :all ->
        query
        # TODO: only join
        |> proload(activity: [:media])
        |> where([media: media], is_nil(media.media_type))

      [first | rest] ->
        # NOTE: when excluding media types do we want to show only media or any object types (in both cases excluding media of specified types)? for now going with the second option
        rest
        |> Enum.reduce(
          query
          |> Activities.join_per_media(:left)
          |> proload(activity: [:media])
          |> where([media: media], is_nil(media.id) or not ilike(media.media_type, ^"#{first}%")),
          fn type, query ->
            where(query, [media: media], not ilike(media.media_type, ^"#{type}%"))
          end
        )

      other ->
        warn(other, "Unrecognised media type")
        query
    end
  end

  def maybe_filter(query, {:tags, tags}, _opts)
      when is_binary(tags) or (is_list(tags) and tags != []) do
    case tags
         |> debug("tags provided")
         |> Types.partition_uids(
           prepare_non_uid_fun: fn tag ->
             maybe_apply(Bonfire.Tag.Hashtag, :normalize_name, [tag], fallback_return: tag)
           end
         )
         |> debug("partitioned") do
      {[], []} ->
        query

      {ids, []} ->
        query
        # |> proload(:inner, activity: [:object])
        #   |> reusable_join(:inner, [object: object], object_tagged in Tagged,
        #   as: :object_tagged,
        #   on: tagged.tag_id in ^ids and object_tagged.object_id == object.id
        # )
        |> proload(:inner, activity: [object: [:tagged]])
        |> where([tagged: tagged], tagged.tag_id in ^ids)

      {[], hashtags} ->
        query
        |> proload(:inner, activity: [object: [tagged: {"tagged_", [:named]}]])
        |> where([tagged_named: tagged_named], tagged_named.name in ^hashtags)

      {ids, hashtags} ->
        query
        |> proload(:inner, activity: [object: [:tagged]])
        |> proload(activity: [object: [tagged: {"tagged_", [:named]}]])
        |> where(
          [tagged: tagged, tagged_named: tagged_named],
          tagged.tag_id in ^ids or tagged_named.name in ^hashtags
        )
    end
  end

  def maybe_filter(query, filters, _opts) do
    warn(filters, "no supported object-related filters defined")
    query
  end

  defp prepare_media_type(types) do
    cond do
      "*" in types or :* in types ->
        :all

      :link in types or "link" in types ->
        ["link", "article", "profile", "website"] ++ types

      true ->
        types
    end
  end

  def prepare_object_types(types) do
    cond do
      "*" in types ->
        {[], [], false}

      :* in types ->
        {[], [], false}

      true ->
        partition_table_types(types)
    end
  end

  @doc """
  Takes a list of types and returns a tuple containing:
  1. A list of valid table type IDs extracted from the types
  2. A list of types that couldn't be converted to table IDs

  This is useful when you need to process known table types and unknown types differently.

  ## Examples

      iex> partition_table_types([Bonfire.Data.Social.Post, "unknown_type", %{table_id: "30NF1REAPACTTAB1ENVMBER0NE"}])
      {["30NF1REP0STTAB1ENVMBER0NEE", "30NF1REAPACTTAB1ENVMBER0NE"], ["unknown_type"]}

      iex> partition_table_types(Bonfire.Data.Social.Post)
      {["30NF1REP0STTAB1ENVMBER0NEE"], []}

      iex> partition_table_types("unknown_type")
      {[], ["unknown_type"]}

      iex> partition_table_types([])
      {[], []}
  """
  def partition_table_types(types) do
    case types do
      nil ->
        {[], [], nil}

      [] ->
        {[], [], nil}

      types ->
        # Prepare the types
        types = List.wrap(types) |> List.flatten()

        # Process each item to attempt table type extraction
        Enum.reduce(types, {[], []}, fn type, {valid_table_ids, unknown_types} ->
          case Types.table_type(type) do
            table_id when is_binary(table_id) ->
              # Successfully extracted a table ID
              {valid_table_ids ++ [table_id], unknown_types}

            _ ->
              if is_binary(type) or (is_atom(type) and not is_nil(type) and type != false) do
                {valid_table_ids, unknown_types ++ [to_string(type)]}
              else
                warn(type, "Unrecognised type")
                {valid_table_ids, unknown_types}
              end
          end
        end)
        # Return the accumulated lists with duplicates removed
        |> then(fn {valid_table_ids, unknown_types} ->
          unknown_types = unknown_types |> Enum.dedup() |> Enums.filter_empty([])

          {
            valid_table_ids |> Enum.dedup() |> Enums.filter_empty([]),
            unknown_types,
            Enum.any?(unknown_types, &(&1 in ["article", :article]))
          }
        end)
    end
  end

  @doc """
  Returns a basic query over undeleted pointable objects in the system,
  optionally limited to one or more types.
  """
  def query_base(type \\ nil), do: Needle.Pointers.query_base(type)

  @doc """
  Sets the name/title of an object.

  ## Examples

      iex> set_name("123", "New Name", [])
      {:ok, %Object{id: "123", named: %{name: "New Name"}}}
  """
  def set_name(id, name, opts) when is_binary(id) do
    Bonfire.Common.Needles.one(id, opts)
    ~> set_name(name, opts)
  end

  def set_name(%{} = object, name, _opts) do
    # TODO: check user's edit permissions
    object
    |> repo().maybe_preload(:named)
    |> changeset_named(%{named: %{id: uid(object), name: name}})
    |> repo().update()
  end

  def changeset_named(object \\ %{}, attrs) do
    Needle.Changesets.cast(object, attrs, [])
    |> Needle.Changesets.cast_assoc(:named, [])
    |> debug("cs")
  end

  def as_permitted_for(q, opts \\ [], verbs \\ [:see, :read]) do
    to_options(opts)
    |> Keyword.put_new(:verbs, verbs)
    |> boundarise(q, main_object.id, ...)
  end

  @doc """
  Deletes an object if the current users (provided in opts) has permission to, along with related associations (such as mixins).

  ## Examples

      iex> delete(%Object{}, current_user: me)
      {:ok, %Object{}}

  """
  def delete(object, opts) when is_map(object) do
    opts = to_options(opts)

    # load & check permission
    with true <-
           Bonfire.Boundaries.can?(
             current_user(opts),
             :delete,
             object
           ) do
      do_delete(object, opts)
    else
      _ ->
        error("No permission to delete this")
    end
  end

  def delete(object, opts) when is_binary(object) do
    opts =
      to_options(opts)
      |> Keyword.put(:verbs, [:delete])
      |> Keyword.put_new(:skip_boundary_check, :admins)

    # load & check permission
    # TODO: don't load if being passed an obj
    with %{__struct__: _type} = object <-
           Bonfire.Common.Needles.get(
             object,
             opts
           )
           ~> debug("WIP: deletion") do
      do_delete(object, opts)
    else
      _ ->
        error(object, l("Object not found or you have no permission to delete it"))
    end
  end

  # for internal use, please call `delete/2` which checks for permissiom
  def do_delete(objects, opts \\ [])

  def do_delete(objects, opts) when is_list(objects) do
    Enum.map(objects, &do_delete(&1, opts))
  end

  def do_delete(%{__struct__: type, id: id} = object, opts) do
    always_delete_associations = [
      :created,
      :caretaker,
      :activities,
      :peered,
      :controlled
    ]

    opts =
      opts
      |> to_options()
      |> Keyword.put(:action, :delete)
      # generic assocs to delete from all object types if they exist
      |> Keyword.update(:delete_associations, always_delete_associations, fn
        false ->
          []

        extra_delete_associations ->
          Enum.uniq(extra_delete_associations ++ always_delete_associations)
      end)

    # TODO? these mixins should be deleted if their associated pointer is deleted
    # [
    #   Bonfire.Data.AccessControl.InstanceAdmin,
    #   Bonfire.Data.Identity.Email,
    #   Bonfire.Data.Identity.Accounted,
    #   Bonfire.Data.Identity.Named,
    #   Bonfire.Data.Identity.ExtraInfo,
    #   Bonfire.Data.Social.Inbox,
    #   Bonfire.Data.Social.Profile,
    #   Bonfire.Data.ActivityPub.Peered,
    #   Bonfire.Data.Social.Created,
    #   Bonfire.Data.ActivityPub.Actor,
    #   Bonfire.Data.Identity.Credential,
    #   Bonfire.Boundaries.Stereotype,
    #   Bonfire.Data.Social.Replied,
    #   Bonfire.Tag.Tagged,
    #   Bonfire.Data.Identity.Caretaker,
    #   Bonfire.Data.Identity.Self,
    #   Bonfire.Data.Social.PostContent
    # ]

    # WIP: load Activity if we don't have it, get the verb, check for a context module for the verb with `Bonfire.Common.ContextModule.context_module(verb)` and call the `delete_activity` function on that module if it exists 
    object = repo().maybe_preload(object, [:activity])

    if verb = e(object, :activity, :verb_id, nil) |> debug() do
      if verb_slug = Bonfire.Boundaries.Verbs.get_slug(verb) |> debug() do
        with {:ok, verb_context} <-
               Bonfire.Common.ContextModule.context_module(verb_slug) |> debug() do
          maybe_apply(
            verb_context,
            :delete_activity,
            [object, opts],
            &delete_apply_error/2
          )
        end
      end
    end

    Activities.delete_by_object(id)
    |> debug("Delete the object's Activity and remove from feeds first")

    object_type = Bonfire.Common.Types.object_type(object)

    with object_type when not is_nil(object_type) <- object_type,
         context_module when not is_nil(context_module) <-
           Bonfire.Common.ContextModule.maybe_context_module(object_type),
         {:none, _} <-
           maybe_apply(
             context_module,
             :delete,
             [object, opts],
             &delete_apply_error/2
           ),
         {:none, _} <-
           maybe_apply(
             context_module,
             :soft_delete,
             [object, opts],
             &delete_apply_error/2
           ),
         {:none, _} <-
           maybe_apply(
             context_module,
             :soft_delete,
             [object],
             &delete_apply_error/2
           ),
         {:error, e} <-
           try_generic_delete(
             object_type || type,
             object,
             opts,
             "there's no delete function defined for this type, so try with generic deletion"
           ) do
      error(e, "Unable to delete this")
    else
      nil ->
        try_generic_delete(
          object_type || type,
          object,
          opts,
          "could not find the type or context module for this object, so try with generic deletion"
        )

      {:ok, del} ->
        debug(del, "deleted!")
        if opts[:socket_connected], do: Activities.maybe_remove_for_deleters_feeds(id)
        {:ok, del}

      %{id: deleted_id} = del when deleted_id == id ->
        debug(del, "deleted!")
        if opts[:socket_connected], do: Activities.maybe_remove_for_deleters_feeds(id)
        {:ok, del}

      other ->
        error(other, "Unknown deletion error")
    end
  end

  defp try_generic_delete(type, object, options, msg) do
    warn(
      type,
      msg
    )

    maybe_generic_delete(type, object, options)
  end

  @doc """
  Attempts a generic deletion of an object, to be used when no specific delete function is defined for a schema.

  ## Parameters

  - `type`: The type of the object to delete.
  - `object`: The object to delete.
  - `options`: A keyword list of options for the deletion.

  ## Examples

      iex> maybe_generic_delete(MyApp.SomeType, %MyApp.SomeType{}, [])
      {:ok, %MyApp.SomeType{}}

  """
  def maybe_generic_delete(type, object, options \\ [])

  def maybe_generic_delete(_type, object, options) do
    options =
      to_options(options)
      |> Keyword.put(:action, :delete)

    # cover our bases with some more common mixins
    delete_extras =
      Bonfire.Common.Needles.Tables.schema_mixin_assocs(object) ++
        [
          :post_content,
          :profile,
          :character,
          :named
        ]

    if options[:delete_caretaken] do
      debug("first delete all objects that we're the caretaker of")
      delete_caretaken(object)
      # TODO: handle returns?
    end

    object = repo().maybe_preload(object, [:media])
    delete_media = e(object, :media, [])

    options
    |> Keyword.update(
      :delete_associations,
      delete_extras,
      &Enum.uniq(&1 ++ delete_extras)
    )
    |> Keyword.update(
      :delete_media,
      delete_media,
      &Enum.uniq(List.wrap(&1) ++ delete_media)
    )
    |> debug("deletion opts")
    |> Keyword.put(:object, object)
    |> run_epic(:delete, ..., :object)
    |> debug("fini")
  end

  # def maybe_generic_delete(type, _object, _options) do
  #   warn(type, "Deletion not implemented for")
  #   nil
  # end

  @doc """
  Deletes objects that are taken care of by the given main object(s).

  This function recursively deletes caretakers and their objects, except for the original object (i.e if Alice is a user who takes care of some posts but also a group that in turn takes care of some posts or boosts, it will delete all of those except Alice herself).

  ## Parameters

  - `main`: The main object or list of objects to start the deletion from.

  ## Examples

      iex> delete_caretaken(%Object{id: "main_id"})
      {:ok, [%Object{}, %Object{}]}

  """
  def delete_caretaken(main) do
    mains = List.wrap(main)
    main_ids = Enums.ids(mains)

    caretakers =
      (care_closures(main) ++ mains)
      |> Enums.uniq_by_id()
      |> debug(
        "First of all, we must collate a list of recursive caretakers, plus ID(s) provided"
      )

    caretaker_ids = Types.uids(caretakers)

    # TODO: some types of Objects (eg. Feed, Circle) may not need to use a whole Epic but can simply be deleted from DB directly, as long as they cascade deletes to eg. FeedPublish and Encircle

    care_taken(caretaker_ids)
    |> Enum.reject(&(Enums.id(&1) in caretaker_ids))
    |> debug(
      "then delete list things they are caretaker of (and don't federate deletion of those things individually, as hopefully that cascades from the Actor deletion)"
    )
    |> do_delete(skip_boundary_check: true, skip_federation: true)
    |> debug("deleted care_taken")

    caretakers
    |> Enum.reject(&(Enums.id(&1) in main_ids))
    |> debug(
      "then delete the caretakers themselves (except the main one since that one should be handled by the caller)"
    )
    |> do_delete(skip_boundary_check: true, delete_caretaken: false)
    |> debug("deleted caretakers")

    # Bonfire.Ecto.Acts.Delete.maybe_delete(main, repo()) # main thing should be deleted by the caller
  end

  @doc """
  Retrieves care closures for the given IDs.

  ## Parameters

  - `ids`: A list of IDs to find care closures for.

  ## Examples

      iex> care_closures(["id1", "id2"])

  """
  def care_closures(ids), do: repo().all(CareClosure.by_branch(Types.uids(ids)))

  @doc """
  Retrieves a list of objects that are taken care of by the given caretaker IDs.

  ## Parameters

  - `ids`: A list of caretaker IDs.

  ## Examples

      iex> care_taken(["caretaker1", "caretaker2"])
      [%Object{}, %Object{}]

  """
  def care_taken(ids),
    do:
      repo().all(
        from(c in Caretaker, where: c.caretaker_id in ^Types.uids(ids))
        |> proload(:pointer)
      )
      |> repo().maybe_preload(:pointer)
      |> Enum.map(&(e(&1, :pointer, nil) || Utils.id(&1)))

  @doc """
  Runs an epic for a given type and options.

  ## Parameters

  - `type`: The type of epic to run.
  - `options`: A keyword list of options for the epic.
  - `on`: The key in the epic's assigns to return (default: `:object`).

  ## Examples

      iex> run_epic(:delete, [object: %Object{}])
      {:ok, %Object{}}

  """
  def run_epic(type, options \\ [], on \\ :object) do
    Bonfire.Epics.run_epic(__MODULE__, type, Keyword.put(options, :on, on))
  end

  def delete_apply_error(error, _args) do
    debug(error, "no delete function match")

    {:none, error}
  end

  @doc """
  Publishes an object.

  ## Examples

      iex> publish(%User{}, :create, %Object{}, [], __MODULE__)
      {:ok, %Activity{}}

  """
  # used in Classify, Geolocate, etc
  def publish(creator, verb, thing, opts_or_attrs \\ nil, for_module \\ __MODULE__)

  def publish(creator, verb, %{id: _} = thing, opts_or_attrs, for_module) do
    creator =
      creator || e(thing, :creator, nil) || e(thing, :created, :creator, nil) ||
        e(thing, :created, :creator_id, nil) || e(thing, :provider, nil)

    # make visible but don't put in feeds
    opts_with_boundaries =
      set_boundaries(
        creator,
        thing,
        opts_or_attrs,
        for_module
      )

    # add to activity feed + maybe federate
    if creator do
      Bonfire.Social.FeedActivities.publish(creator, verb, thing, opts_with_boundaries)
    else
      warn("No creator for object so we can't publish it")
      {:ok, nil}
    end
  end

  @doc """
  Sets boundaries for an object.

  ## Examples

      iex> set_boundaries(%User{}, %Object{}, [], __MODULE__)
      [boundary: "public", to_circles: [], to_feeds: []]

  """
  def set_boundaries(creator, thing, opts_or_attrs \\ [], for_module \\ __MODULE__) do
    # TODO: make default audience configurable & per object audience selectable by user in API and UI (note: also in `Federation.ap_prepare_activity`)
    boundary_preset =
      e(opts_or_attrs, :boundary, nil) || e(opts_or_attrs, :attrs, :to_boundaries, nil) ||
        e(opts_or_attrs, :to_boundaries, nil) ||
        if(e(opts_or_attrs, :is_public, nil) == false or e(opts_or_attrs, :public, nil) == false,
          do: "mentions"
        ) ||
        Bonfire.Common.Config.get_ext(for_module, :boundary_preset, "public")

    to_circles =
      e(opts_or_attrs, :attrs, :to_circles, nil) || e(opts_or_attrs, :to_circles, nil) ||
        Bonfire.Common.Config.get_ext(for_module, :publish_to_default_circles, [])

    to_feeds =
      Bonfire.Social.Feeds.feed_ids(:notifications, [
        e(thing, :context_id, nil) || e(opts_or_attrs, :attrs, :context_id, nil) ||
          e(opts_or_attrs, :context_id, nil)
      ])

    opts =
      to_options(opts_or_attrs) ++
        [
          boundary: boundary_preset,
          to_circles: to_circles,
          to_feeds: to_feeds,
          for_module: for_module
        ]

    (opts ++
       [
         boundaries_as_set:
           if(module_enabled?(Bonfire.Boundaries),
             do:
               Bonfire.Boundaries.set_boundaries(
                 opts[:boundaries_caretaker] || creator,
                 thing,
                 opts
               )
           )
       ])
    |> debug(
      "boundaries set & recipients to include (should include scope, provider, and receiver if any)"
    )
  end

  @doc """
  Resets the preset boundary for an object.

  ## Examples

      iex> reset_preset_boundary(%User{}, %Object{}, "public", [to_boundaries: "local"], __MODULE__)
      {:ok, %Boundary{}}

  """
  def reset_preset_boundary(
        creator,
        thing,
        previous_preset,
        opts_or_attrs \\ [],
        for_module \\ nil
      ) do
    to_boundaries =
      e(opts_or_attrs, :attrs, :to_boundaries, nil) || e(opts_or_attrs, :to_boundaries, nil)

    if to_boundaries == "private" do
      # do it here to skip the rest of the logic
      with {num, nil} <- Bonfire.Boundaries.Controlleds.remove_all_acls(thing) do
        {:ok, num}
      end
    else
      # debug(thing, "reset boundary of")
      set_opts =
        [
          remove_previous_preset: previous_preset,
          to_boundaries: to_boundaries,
          to_circles:
            e(opts_or_attrs, :attrs, :to_circles, nil) || e(opts_or_attrs, :to_circles, nil),
          context_id:
            e(thing, :context_id, nil) || e(opts_or_attrs, :attrs, :context_id, nil) ||
              e(opts_or_attrs, :context_id, nil)
        ]
        |> debug("opts")
        |> set_boundaries(creator, thing, ..., for_module || object_type(thing) || __MODULE__)

      set_opts[:boundaries_as_set] || error("Boundaries not enabled")
    end
  end

  @doc """
  Casts the object sensitivity on a changeset.

  ## Examples

      iex> cast_sensitivity(%Changeset{}, true)
      %Changeset{}

  """
  def cast_sensitivity(changeset, skip) when skip in [nil, false] do
    changeset
  end

  def cast_sensitivity(changeset, sensitive?) do
    changeset
    |> Changesets.put_assoc!(:sensitive, %{
      is_sensitive: if(sensitive?, do: true)
    })
  end

  @doc """
  Sets the sensitivity of an existing object.

  ## Examples

      iex> set_sensitivity(%Object{sensitive: %{}}, true)
      {:ok, %Object{}}

  """
  def set_sensitivity(pointer, nil), do: set_sensitivity(pointer, false)

  def set_sensitivity(%{sensitive: _} = pointer, new_sensitive) do
    pointer =
      pointer
      |> repo().preload([:sensitive])

    # Check if sensitivity has actually changed to avoid unnecessary updates
    current_sensitive = e(pointer, :sensitive, :is_sensitive, false)

    if new_sensitive != current_sensitive do
      do_set_sensitivity(pointer, new_sensitive)
    else
      {:ok, pointer}
    end
  end

  # TODO: also support setting with an ID, or with an object that doesn't have a `sensitive` assoc?
  # def set_sensitivity(pointer, new_sensitive) do
  #   pointer
  #   |> set_sensitivity(new_sensitive)
  # end

  defp do_set_sensitivity(pointer, true) do
    pointer
    |> Changesets.put_assoc(:sensitive, %{
      is_sensitive: true
    })
    |> debug()
    |> repo().update()
  end

  defp do_set_sensitivity(pointer, _) do
    # delete mixin
    pointer
    |> Map.get(:sensitive)
    |> debug()
    |> repo().delete()

    {:ok, pointer |> Map.put(:sensitive, nil)}
  end

  def ap_receive_activity(creator, _activity, %{pointer: %{id: _} = pointer} = _object) do
    ap_maybe_delete(creator, pointer)
  end

  def ap_receive_activity(creator, _activity, %{pointer_id: pointer} = _object)
      when is_binary(pointer) do
    ap_maybe_delete(creator, pointer)
  end

  def ap_receive_activity(creator, _activity, %struct{id: id} = object)
      when struct not in [ActivityPub.Actor, ActivityPub.Object] do
    ap_maybe_delete(creator, object)
  end

  def ap_receive_activity(_creator, _activity, object) do
    error(object, "Could not find the object to delete")
  end

  def ap_maybe_delete(_creator, nil) do
    {:ok, :none}
  end

  def ap_maybe_delete(creator, object) do
    debug(creator, "creator")
    debug(object, "object")

    delete(object, creator)
    |> debug("ap_maybe_deleted")
  end

  @doc """
  Gets the permalink for an object.

  ## Examples

      iex> permalink(%{canonical_uri: "https://example.com/object/123"})
      "https://example.com/object/123"

  """
  def permalink(%{canonical_uri: permalink}) do
    permalink
  end

  def permalink(%{peered: %{canonical_uri: permalink}}) do
    permalink
  end

  def permalink(%{peered: _} = object) do
    warn("FIXME: Peered should already come preloaded in object")

    object
    # |> repo().maybe_preload(:peered)
    |> e(:peered, :canonical_uri, nil)
  end

  def permalink(object) when is_map(object) or is_binary(object) do
    warn(object, "FIXME: object does not have a :peered assoc, query it instead")

    Utils.maybe_apply(
      Bonfire.Federate.ActivityPub.Peered,
      :get_canonical_uri,
      [object]
    )
  end

  def permalink(other) do
    debug(other, "seems to be a local object")
    nil
  end
end
