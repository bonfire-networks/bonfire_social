defmodule Bonfire.Social.Objects do

  use Arrows
  use Bonfire.Common.Repo,
    schema: Pointers.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]
  use Bonfire.Common.Utils
  import Where

  alias Bonfire.Common
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Social.{Activities, FeedActivities, Tags, Threads}
  alias Pointers.{Changesets, Pointer}
  alias Bonfire.Epics.Epic

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
    |> Tags.cast(attrs, creator, opts)
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
  def cast_basic(changeset, attrs, creator, opts) do
    changeset
    |> cast_creator_caretaker(creator)
    |> cast_acl(creator, opts)
    # |> debug()
  end

  @doc """
  Handles casting:
  * Acls
  """
  def cast_mini(changeset, attrs, creator, opts) do
    changeset
    # apply boundaries on all objects, uses data preloaded by `Threads` and `PostContents`
    |> cast_acl(creator, opts)
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
    changeset
    |> Acls.cast(creator, opts)
  end

  defp cast_activity(changeset, %{id: id} = attrs, creator, opts) when is_binary(id) do
    changeset
    |> Changeset.cast(attrs, [:id]) # manually set the ULID of the object (which will be the same as the Activity ID)
    # create activity & put in feeds
    |> Activities.cast(Map.get(attrs, :verb, :create), creator, opts)
  end
  defp cast_activity(changeset, attrs, creator, opts) do
    Map.put(attrs, :id, Pointers.ULID.generate())
    |> cast_activity(changeset, ..., creator, opts)
  end

  def cast_creator(changeset, creator),
    do: cast_creator(changeset, creator, e(creator, :id, nil))

  def cast_creator(changeset, _creator, nil), do: changeset
  def cast_creator(changeset, _creator, creator_id) do
    changeset
    |> Changesets.put_assoc(:created, %{creator_id: creator_id})
  end

  def cast_creator_caretaker(changeset, creator),
    do: cast_creator_caretaker(changeset, creator, e(creator, :id, nil))

  defp cast_creator_caretaker(changeset, _creator, nil), do: changeset
  defp cast_creator_caretaker(changeset, _creator, creator_id) do
    changeset
    |> Changesets.put_assoc(:created,   %{creator_id: creator_id})
    |> Changesets.put_assoc(:caretaker, %{caretaker_id: creator_id})
  end

  def read(object_id, socket_or_current_user) when is_binary(object_id) do
    current_user = current_user(socket_or_current_user) #|> debug
    Common.Pointers.pointer_query([id: object_id], socket_or_current_user)
    |> Activities.read(socket: socket_or_current_user, skip_opts_check: true)
    # |> debug("object with activity")
    ~> maybe_preload_activity_object(current_user)
    ~> Activities.activity_under_object(...)
    ~> to_ok()
    # |> debug("final object")
  end

  def maybe_preload_activity_object(%{activity: %{object: _}} = pointer, current_user) do
    Common.Pointers.Preload.maybe_preload_nested_pointers(pointer, [activity: [:object]],
      current_user: current_user, skip_opts_check: true)
  end
  def maybe_preload_activity_object(pointer, _current_user), do: pointer

  def preload_reply_creator(object) do
    object
    |> Bonfire.Common.Repo.maybe_preload([replied: [reply_to: [created: [creator: [:character]]]]]) #|> IO.inspect
    # |> Bonfire.Common.Repo.maybe_preload([replied: [:reply_to]]) #|> IO.inspect
    |> Bonfire.Common.Repo.maybe_preload([replied: [reply_to: [creator: [:character]]]]) #|> IO.inspect
  end

  # TODO: does not take permissions into consideration
  def preload_creator(object),
    do: object
        |> Bonfire.Common.Repo.maybe_preload([created: [creator: [:character]]])
        |> Bonfire.Common.Repo.maybe_preload([creator: [:character]])

  def object_creator(object) do
    e(object, :created, :creator, e(object, :creator, nil))
  end

  defp tag_ids(tags), do: Enum.map(tags, &(&1.id))

  def list_query(type_or_query \\ nil, opts)

  def list_query(%Ecto.Query{}= query, opts) do
    query
    |> FeedActivities.query_extras(opts)
  end

  def list_query(type, opts) when is_atom(type) do
    query_base(type)
    |> list_query(opts)
  end

  @doc """
  Returns a basic query over undeleted pointable objects in the system,
  optionally limited to one or more types.
  """
  def query_base(type \\ nil), do: Pointers.query_base(type)

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
    Bonfire.Common.Pointers.one(id, opts)
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
    Pointers.Changesets.cast(object, attrs, [])
    |> Pointers.Changesets.cast_assoc(:named, [])
    |> debug("cs")
  end

  def delete(object, opts) do
    opts = to_options(opts)

    # load & check permission
    with %{} = object <- Bonfire.Common.Pointers.get(object, opts ++ [verbs: [:delete]])
            ~> debug("WIP: deletion") do
      opts =opts
      |> Keyword.put(:action, :delete)
      |> Keyword.put(:delete_associations, [ # generic things to delete from all object types
          :creator,
          :caretaker,
          :caretaker,
          :activities,
          :peered,
          :controlled
        ])

      with {:error, _} <- Bonfire.Common.ContextModules.maybe_apply(object, :delete, [object, opts]),
          {:error, _} <- Bonfire.Common.ContextModules.maybe_apply(object, :soft_delete, [current_user(opts), object]),
          {:error, _} <- Bonfire.Common.ContextModules.maybe_apply(object, :soft_delete, [object]) do
            warn("there's no per-type delete functions, try with generic_delete anyway")
            generic_delete(object, opts)
      end
    else
      _ ->
        error(l "No permission to delete this")
    end
  end

  def generic_delete(object, options \\ []) do
    options = to_options(options)
    |> Keyword.put(:object, object)

    options
    |> Keyword.put(:delete_associations,
      options[:delete_associations] ++ [ # cover our bases with common mixins
        :post_content,
        :profile,
        :character,
        :named
      ])
    |> run_epic(:delete, ..., :object)
  end

  def run_epic(type, options \\ [], on \\ :object) do
    options = Keyword.merge(options, crash: true, debug: true, verbose: false)
    epic =
      Epic.from_config!(__MODULE__, type)
      |> Epic.assign(:options, options)
      |> Epic.run()
    if epic.errors == [], do: {:ok, epic.assigns[on]}, else: {:error, epic}
  end

end
