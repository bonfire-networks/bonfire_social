defmodule Bonfire.Social.Objects do
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
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Tags
  alias Bonfire.Social.Threads

  alias Needle.Changesets
  # alias Needle.Pointer

  alias Bonfire.Epics.Epic

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module, do: ["Delete", {"Create", "Tombstone"}]


  @cannot_delete_msg "Object not found or you have no permission to delete it"

  @doc """
  Handles casting:
  * Creator
  * Caretaker
  * Threaded replies (when present)
  * Tags/Mentions (when present)
  * Acls
  * Activity
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
  Handles casting:
  * Creator
  * Caretaker
  * Acls
  """
  def cast_basic(changeset, _attrs, creator, opts) do
    changeset
    |> cast_creator_caretaker(creator)
    |> cast_acl(creator, opts)

    # |> debug()
  end

  @doc """
  Handles casting:
  * Acls
  """
  def cast_mini(changeset, _attrs, creator, opts) do
    # apply boundaries on all objects, uses data preloaded by `Threads` and `PostContents`
    cast_acl(changeset, creator, opts)

    # |> debug()
  end

  @doc """
  Handles casting:
  * Acls
  * Activity
  * Feed Publishes
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
    Map.put(attrs, :id, Needle.ULID.generate())
    |> cast_activity(changeset, ..., creator, opts)
  end

  def cast_creator(changeset, creator),
    do: cast_creator(changeset, creator, ulid(creator))

  defp cast_creator(changeset, _creator, nil), do: changeset

  defp cast_creator(changeset, _creator, creator_id) do
    Changesets.put_assoc(changeset, :created, %{creator_id: creator_id})
  end

  def cast_caretaker(changeset, caretaker),
    do: cast_caretaker(changeset, caretaker, ulid(caretaker))

  defp cast_caretaker(changeset, _caretaker, nil), do: changeset

  defp cast_caretaker(changeset, _caretaker, caretaker_id) do
    Changesets.put_assoc(changeset, :caretaker, %{caretaker_id: caretaker_id})
  end

  def cast_creator_caretaker(changeset, user) do
    changeset
    |> cast_creator(user)
    |> cast_caretaker(user)
  end

  def read(object_id, opts) when is_binary(object_id) do
    # |> debug
    opts = to_options(opts) ++ [skip_opts_check: true]

    Common.Needles.pointer_query([id: object_id], opts)
    # |> debug()
    |> Activities.read()
    # |> debug("object with activity")
    ~> maybe_preload_activity_object(opts)
    ~> Activities.activity_under_object(...)
    ~> to_ok()
    |> debug("final object")
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

  def preload_reply_creator(object) do
    object
    # |> IO.inspect
    |> repo().maybe_preload(replied: [reply_to: [created: [creator: [:character]]]])
    # |> repo().maybe_preload([replied: [:reply_to]]) #|> IO.inspect
    # |> IO.inspect
    |> repo().maybe_preload(replied: [reply_to: [creator: [:character]]])
  end

  # TODO: does not take permissions into consideration
  def preload_creator(object),
    do:
      object
      |> repo().maybe_preload(created: [creator: [:character]])
      |> repo().maybe_preload(creator: [:character])

  def object_creator(object) do
    e(object, :created, :creator, e(object, :creator, nil))
  end

  def list_query(type_or_query \\ nil, opts)

  def list_query(%Ecto.Query{} = query, opts) do
    debug(query)
    FeedActivities.query_extras_boundarised(query, opts)
  end

  def list_query(type, opts) when is_atom(type) do
    debug(type)

    query_base(type)
    |> list_query(opts)
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
  # def exclude_types(query, types) do
  #   types = Enum.map(List.wrap(types), &get_table_id!/1)
  #   from(q in query, where: q.table_id not in ^types)
  # end

  def set_name(id, name, opts) when is_binary(id) do
    Bonfire.Common.Needles.one(id, opts)
    ~> set_name(name, opts)
  end

  def set_name(%{} = object, name, _opts) do
    # TODO: check user's edit permissions
    object
    |> repo().maybe_preload(:named)
    |> changeset_named(%{named: %{id: ulid(object), name: name}})
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
        error(@cannot_delete_msg)
    end
  end

  # for internal use, please call `delete/2` which checks for permissiom
  def do_delete(objects, opts \\ [])

  def do_delete(objects, opts) when is_list(objects) do
    Enum.map(objects, &do_delete(&1, opts))
  end

  def do_delete(%{__struct__: type} = object, opts) do
    opts =
      opts
      |> to_options()
      |> Keyword.put(:action, :delete)
      # generic assocs to delete from all object types if they exist
      |> Keyword.put(:delete_associations, [
        :created,
        :caretaker,
        :activities,
        :peered,
        :controlled
      ])

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

    id = ulid!(object)

    Activities.delete_object(id)
    |> debug("Delete it from feeds first and foremost")

    with {:error, _} <-
           Bonfire.Common.ContextModule.maybe_apply(
             object,
             :delete,
             [object, opts],
             &delete_apply_error/2
           ),
         {:error, _} <-
           Bonfire.Common.ContextModule.maybe_apply(
             object,
             :soft_delete,
             [object, opts],
             &delete_apply_error/2
           ),
         {:error, _} <-
           Bonfire.Common.ContextModule.maybe_apply(
             object,
             :soft_delete,
             [object],
             &delete_apply_error/2
           ),
         {:error, e} <- try_generic_delete(type, object, opts) do
      error(e, "Unable to delete this")
    else
      {:ok, del} ->
        debug(del, "deleted!")
        if opts[:socket_connected], do: Activities.maybe_remove_for_deleters_feeds(id)
        {:ok, del}

      other ->
        error(other)
    end
  end

  defp try_generic_delete(type, object, options) do
    warn(
      type,
      "there's no delete function defined for this type, so try with generic deletion"
    )

    maybe_generic_delete(type, object, options)
  end

  def maybe_generic_delete(type, object, options \\ [])

  def maybe_generic_delete(type, object, options) do
    options =
      to_options(options)
      |> Keyword.put(:object, object)
      |> Keyword.put(:action, :delete)

    # cover our bases with some more common mixins
    delete_extras =
      Bonfire.Common.Repo.Preload.schema_mixins(object) ++
        [
          :post_content,
          :profile,
          :character,
          :named
        ]

    if options[:delete_caretaken] do
      delete_caretaken(object)
    end

    options
    |> Keyword.update(
      :delete_associations,
      delete_extras,
      &(&1 ++ delete_extras)
    )
    |> debug("deletion opts")
    |> run_epic(:delete, ..., :object)
    |> debug("fini")
  end

  # def maybe_generic_delete(type, _object, _options) do
  #   warn(type, "Deletion not implemented for")
  #   nil
  # end

  def delete_caretaken(main) do
    mains = List.wrap(main)
    main_ids = Enums.ids(mains)

    caretakers =
      (care_closures(main) ++ mains)
      |> Enums.uniq_by_id()
      |> debug(
        "First of all, we must collate a list of recursive caretakers, plus ID(s) provided"
      )

    caretaker_ids = Types.ulids(caretakers)

    care_taken(caretaker_ids)
    |> Enum.reject(&(Enums.id(&1) in caretaker_ids))
    |> debug("then delete list things they are caretaker of")
    |> do_delete(skip_boundary_check: true, skip_federation: true)
    |> debug("deleted care_taken")

    caretakers
    |> Enum.reject(&(Enums.id(&1) in main_ids))
    |> debug(
      "then delete the caretakers themselves (except the main one since that one should be handled by the caller)"
    )
    |> do_delete(skip_boundary_check: true, delete_caretaken: false)
    |> debug("deleted caretakers")

    # Bonfire.Ecto.Acts.Delete.maybe_delete(main, repo())
    # |> debug("double-check that main thing(s) is deleted too")
  end

  def care_closures(ids), do: repo().all(CareClosure.by_branch(Types.ulids(ids)))

  def care_taken(ids),
    do:
      repo().all(
        from(c in Caretaker, where: c.caretaker_id in ^Types.ulids(ids))
        |> proload(:pointer)
      )
      |> repo().maybe_preload(:pointer)
      |> Enum.map(&(Utils.e(&1, :pointer, nil) || Utils.id(&1)))

  def run_epic(type, options \\ [], on \\ :object) do
    options = Keyword.merge(options, crash: true, debug: true, verbose: true)

    epic =
      Epic.from_config!(__MODULE__, type)
      |> Epic.assign(:options, options)
      |> Epic.run()

    if epic.errors == [], do: {:ok, epic.assigns[on]}, else: {:error, epic}
  end

  def delete_apply_error(error, args) do
    debug(error, "no delete function match for #{inspect(args)}")

    {:error, error}
  end

  # used in Classify, Geolocate, etc
  def publish(creator, verb, thing, opts_or_attrs \\ nil, for_module \\ __MODULE__)

  def publish(
        %{id: _} = creator,
        verb,
        %{id: _} = thing,
        opts_or_attrs,
        for_module
      )
      when is_atom(verb) do
    # this sets permissions & returns recipients in opts to be used for publishing
    opts = set_boundaries(creator, thing, opts_or_attrs, for_module)

    # add to activity feed + maybe federate
    Bonfire.Social.FeedActivities.publish(creator, verb, thing, opts)
  end

  def publish(creator, _verb, %{id: _} = thing, opts_or_attrs, for_module) do
    debug("No creator for object so we can't publish it")

    # make visible but don't put in feeds
    set_boundaries(
      creator || e(thing, :creator, nil) || e(thing, :created, :creator, nil) ||
        e(thing, :created, :creator_id, nil) || e(thing, :provider, nil),
      thing,
      opts_or_attrs,
      for_module
    )

    {:ok, nil}
  end

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

  def cast_sensitivity(changeset, sensitive?) do
    changeset
    |> Changesets.put_assoc!(:sensitive, %{
      is_sensitive: if(sensitive?, do: true)
    })
  end

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

  def ap_receive_activity(creator, _activity, %{pointer: %{id: _} = pointer} = object) do
    ap_maybe_delete(creator, pointer)
  end
  def ap_receive_activity(creator, _activity, %{pointer_id: pointer} = object) when is_binary(pointer) do
    ap_maybe_delete(creator, pointer)
  end
  def ap_receive_activity(_creator, _activity, object) do
    error(object, "dunno how to delete object")
  end

  def ap_maybe_delete(creator, nil) do
    {:ok, :none}
  end

  def ap_maybe_delete(creator, object) do
    debug(creator)
    debug(object)

    delete(object, creator)
    |> debug("ap_maybe_deleted") 
   
  end
end
