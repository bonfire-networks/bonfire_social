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
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Tags
  alias Bonfire.Social.Threads
  alias Bonfire.Boundaries.Verbs

  alias Needle.Changesets
  # alias Needle.Pointer

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

    # |> cast_activity(attrs, creator, opts)
    # |> debug()
  end

  @doc """
  Casts basic attributes for an object changeset.

  Handles casting:
  - Creator
  - Caretaker
  - ACLs

  ## Examples

      iex> cast_basic(changeset, %{}, user, [])
      %Ecto.Changeset{}

  """
  def cast_basic(changeset, _attrs, creator, opts) do
    changeset
    |> cast_creator_caretaker(creator)
    |> cast_acl(creator, opts)

    # |> debug()
  end

  @doc """
  Casts minimal attributes for an object changeset.

  Handles casting:
  - ACLs

  ## Examples

      iex> cast_mini(changeset, %{}, user, [])
      %Ecto.Changeset{}

  """
  def cast_mini(changeset, _attrs, creator, opts) do
    # apply boundaries on all objects, uses data preloaded by `Threads` and `PostContents`
    cast_acl(changeset, creator, opts)

    # |> debug()
  end

  @doc """
  Casts attributes for publishing an object.

  Handles casting:
  - ACLs
  - Activity
  - Feed Publishes

  ## Examples

      iex> cast_publish(changeset, %{}, user, [])
      %Ecto.Changeset{}

  """
  def cast_publish(changeset, attrs, creator, opts) do
    # debug(creator, "creator")
    changeset
    |> cast_mini(attrs, creator, opts)
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
    opts = Keyword.merge(to_options(opts), skip_opts_check: true, verbs: [:read])

    Common.Needles.pointer_query([id: object_id], opts)
    # |> debug()
    # why skipping here? is Needles.pointer_query checking the boundary?
    |> Activities.read(skip_boundary_check: true)
    # |> debug("object with activity")
    ~> maybe_preload_activity_object(opts)
    ~> Activities.activity_under_object(...)
    ~> to_ok()
    |> debug("final object")
  end

  def read(%Ecto.Query{} = query, opts \\ []) do
    opts = Keyword.merge(to_options(opts), verbs: [:read])

    with {:ok, object} <-
           query
           |> Activities.read_query(opts)
           |> as_permitted_for(opts)
           |> repo().single() do
      {:ok, Activities.activity_under_object(object)}
    end
  end

  def maybe_preload_activity_object(
        %{activity: %{object: _}} = pointer,
        opts
      ) do
    Common.Needles.Preload.maybe_preload_nested_pointers(
      pointer,
      [activity: [:object]],
      opts
    )
  end

  def maybe_preload_activity_object(pointer, _current_user), do: pointer

  @doc """
  Preloads the reply creator for an object.

  ## Examples

      iex> preload_reply_creator(%Object{})
      %Object{replied: %{reply_to: ...}}

  """
  def preload_reply_creator(object) do
    object
    # |> IO.inspect
    |> repo().maybe_preload(replied: [reply_to: [created: [creator: [:character]]]])
    # |> repo().maybe_preload([replied: [:reply_to]]) #|> IO.inspect
    # |> IO.inspect
    #  FIXME: is this loaded the same creator twice?
    |> repo().maybe_preload(replied: [reply_to: [creator: [:character]]])
  end

  @doc """
  Preloads the creator for an object.

  ## Examples

      iex> preload_creator(%Object{})
      %Object{}

  """
  # TODO: does not take permissions into consideration
  def preload_creator(object),
    do:
      object
      |> repo().maybe_preload(created: [creator: [:character]])
      |> repo().maybe_preload(creator: [:character])

  @doc """
  Gets the creator of an object (if preloaded)

  ## Examples

      iex> object_creator(%Object{})
      %User{}

  """
  def object_creator(object) do
    e(object, :created, :creator, nil) || e(object, :creator, nil)
  end

  def query_maybe_time_limit(query, 0), do: query

  def query_maybe_time_limit(query, x_days) when is_integer(x_days) do
    limit_pointer =
      DatesTimes.past(x_days, :day)
      |> debug("from date")
      |> Needle.UID.generate()
      |> debug("UID")

    where(query, [activity: activity], activity.id > ^limit_pointer)
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

  def list_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    # debug(opts)
    filters
    # |> debug("filters")
    # |> query_paginated(opts)
    |> FeedActivities.feed_many_paginated(opts)
  end

  def list_query(type_or_query \\ nil, opts)

  def list_query(%Ecto.Query{} = query, opts) do
    debug(query)
    FeedActivities.query_object_extras_boundarised(query, opts)
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

  # doc "List objects created by a user and which are in their outbox, which are not replies"
  def filter(:by, user, query) do
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

  @doc """
  Returns a basic query over undeleted pointable objects in the system,
  optionally limited to one or more types.
  """
  def query_base(type \\ nil), do: Needle.Pointers.query_base(type)

  # @doc """
  # Modifies the query to exclude records of the provided type or types,
  # which may be ULID table IDs or schema module names.

  # Note: expects you to be querying against `Pointer`, i.e. to not have limited the types already.
  # """
  # def exclude_object_types(query, types) do
  #   types = Enum.map(List.wrap(types), &get_table_id!/1)
  #   from(q in query, where: q.table_id not in ^types)
  # end

  def prepare_exclude_object_types(extras \\ [], defaults \\ []) do
    # eg. private messages should never appear in feeds

    (defaults ++ extras)
    |> List.wrap()
    |> Enum.map(&maybe_apply(&1, :__pointers__, :table_id))
    |> Enum.uniq()

    # |> debug("exxclude_tables")
  end

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
    opts = to_options(opts)

    # load & check permission
    # TODO: don't load if being passed an obj
    with %{__struct__: _type} = object <-
           Bonfire.Common.Needles.get(
             object,
             opts ++ [verbs: [:delete], skip_boundary_check: :admins]
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

  def do_delete(%{__struct__: type} = object, opts) do
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

    id = uid!(object)

    Activities.delete_by_object(id)
    |> debug("Delete it from feeds first and foremost")

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

      other ->
        error(other)
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
      delete_caretaken(object)
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
      e(opts_or_attrs, :attrs, :to_boundaries, nil) || e(opts_or_attrs, :to_boundaries, nil) ||
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

      iex> reset_preset_boundary(%User{}, %Object{}, "public", [], __MODULE__)
      {:ok, %Boundary{}}

  """
  def reset_preset_boundary(
        creator,
        thing,
        previous_preset,
        opts_or_attrs \\ [],
        for_module \\ nil
      ) do
    # debug(thing, "reset boundary of")
    set_opts =
      [
        remove_previous_preset: previous_preset,
        to_boundaries:
          e(opts_or_attrs, :attrs, :to_boundaries, nil) || e(opts_or_attrs, :to_boundaries, nil),
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

  @doc """
  Casts the object sensitivity on a changeset.

  ## Examples

      iex> cast_sensitivity(%Changeset{}, true)
      %Changeset{}

  """
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
  # TODO: also support setting with an ID, or with an object that doesn't have a `sensitive` assoc
  def set_sensitivity(%{sensitive: _} = pointer, true) do
    pointer
    |> repo().preload([:sensitive])
    |> Changesets.put_assoc(:sensitive, %{
      is_sensitive: true
    })
    |> debug()
    |> repo().update()
  end

  def set_sensitivity(%{sensitive: _} = pointer, _) do
    # delete mixin
    pointer
    |> repo().preload([:sensitive])
    |> Map.get(:sensitive)
    |> debug()
    |> repo().delete()
  end

  def ap_receive_activity(creator, _activity, %{pointer: %{id: _} = pointer} = _object) do
    ap_maybe_delete(creator, pointer)
  end

  def ap_receive_activity(creator, _activity, %{pointer_id: pointer} = _object)
      when is_binary(pointer) do
    ap_maybe_delete(creator, pointer)
  end

  def ap_receive_activity(_creator, _activity, object) do
    error(object, "dunno how to delete object")
  end

  def ap_maybe_delete(_creator, nil) do
    {:ok, :none}
  end

  def ap_maybe_delete(creator, object) do
    debug(creator)
    debug(object)

    delete(object, creator)
    |> debug("ap_maybe_deleted")
  end

  def maybe_unindex(object) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_delete_object(object)
    else
      :ok
    end
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
