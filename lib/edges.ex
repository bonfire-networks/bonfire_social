defmodule Bonfire.Social.Edges do
  @moduledoc """
  Shared helpers for modules that implemented Edges to mutate or query them, preload relevant associations, etc.

  This is a shared [context](https://hexdocs.pm/phoenix/contexts.html) for `Bonfire.Data.Edges.Edge`, which has these fields:
  - id: primary key which matches the related Activity 
  - subject: the who (eg. a user)
  - table: what kind of action (eg. references Like or Follow in `Needle.Table` ...)
  - object: the what (eg. a specific post)
  """

  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  import Bonfire.Boundaries.Queries
  import Untangle
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Objects

  alias Needle.Changesets
  # alias Needle.ULID

  @skip_warn_filters [
    :preload,
    :objects,
    :subjects,
    :activity_types,
    :preload_type,
    :object_types,
    :subject_types,
    :current_user,
    :current_account,
    :id,
    :table_id,
    :after,
    :before,
    :paginate,
    :paginate?
  ]

  @doc """
  Inserts a new edge with the given schema, subject, verb, and object.

  ## Examples

      > insert(MySchema, %User{id: 1}, :like, %Post{id: 2}, [])
      {:ok, %Edge{}}
  """
  def insert(schema, subject, verb, object, options) do
    changeset(schema, subject, verb, object, options)
    |> insert(subject, object)
  end

  @doc """
  Inserts a changeset with optional subject and object.

  ## Examples

      iex> insert(%Changeset{}, %User{id: 1}, %Post{id: 2})
      {:ok, %Edge{}}
  """
  def insert(changeset, subject \\ nil, object \\ nil) do
    changeset
    |> Changeset.unique_constraint([:subject_id, :object_id, :table_id])
    |> repo().insert()
    |> preload_inserted(subject, object)
  end

  defp preload_inserted(inserted, %{} = subject, %{} = object) do
    inserted
    |> repo().maybe_preload(
      edge: [
        subject: fn _ -> [subject] end,
        object: fn _ -> [object] end
      ],
      activity: [
        subject: fn _ -> [subject] end,
        object: fn _ -> [object] end
      ]
    )
  end

  defp preload_inserted(inserted, %{} = subject, _object) do
    inserted
    |> repo().maybe_preload(
      edge: [
        :object,
        subject: fn _ -> [subject] end
      ],
      activity: [
        :object,
        subject: fn _ -> [subject] end
      ]
    )
  end

  defp preload_inserted(inserted, _subject, _object) do
    inserted
    |> repo().maybe_preload(edge: [:subject, :object], activity: [:subject, :object])
  end

  @doc """
  Prepares a full changeset for the given schema, subject, verb, object, and options.

  ## Examples

      iex> changeset(MySchema, %User{id: 1}, :like, %Post{id: 2}, [])
      %Ecto.Changeset{}
  """
  def changeset(schema, subject, verb, object, options) do
    changeset_extra(schema, subject, verb, object, options)
    |> Objects.cast_creator_caretaker(current_user(options) || subject)
  end

  @doc """
   Prepares a changeset with creator but no caretaker, which avoids the edge being deleted when subject is deleted. Also includes Acls, Activities and FeedActivities.

  ## Examples

      iex> changeset_without_caretaker(MySchema, %User{id: 1}, :like, %Post{id: 2}, [])
      %Ecto.Changeset{}
  """
  def changeset_without_caretaker(schema, subject, verb, object, options) do
    changeset_extra(schema, subject, verb, object, options)
    |> Objects.cast_creator(current_user(options) || subject)
  end

  @doc """
   Prepares a changeset with creator but no caretaker, which avoids the edge being deleted when subject is deleted.

  ## Examples

      iex> changeset_base_with_creator(MySchema, %User{id: 1}, %Post{id: 2}, [])
      %Ecto.Changeset{}
  """
  def changeset_base_with_creator(schema, subject, object, options) do
    changeset_base(schema, subject, object, options)
    |> Objects.cast_creator(current_user(options) || subject)
  end

  @doc "Prepares a changeset with Acls, Activities and FeedActivities"
  def changeset_extra(schema, subject, verb, object, options) do
    changeset_base(schema, subject, object, options)
    |> Acls.cast(subject, options)
    |> Activities.put_assoc(verb, subject, object)
    |> FeedActivities.put_feed_publishes(Keyword.get(options, :to_feeds, []))
  end

  @doc """
  Prepares a basic schema, with the schema type as top-level and an Egde assoc

  iex> changeset_base(Like, %User{id: 1}, %Post{id: 2}, [])
      %Ecto.Changeset{}

  iex> changeset_base(Follow, %User{id: 1}, %User{id: 2}, [])
      %Ecto.Changeset{}

  iex> changeset_base({Request, Follow}, %User{id: 1}, %User{id: 2}, [])
      %Ecto.Changeset{}
  """
  def changeset_base(schema, subject, object, options) when is_atom(schema),
    do: changeset_base({schema, schema}, subject, object, options)

  def changeset_base({main_schema, type_of_edge_schema}, subject, object, _options) do
    Changesets.cast(struct(main_schema), %{}, [])
    |> put_edge_assoc(type_of_edge_schema, subject, object)
  end

  def put_edge_assoc(changeset, subject, object),
    do: put_edge_assoc(changeset, changeset.data.__struct__, subject, object)

  def put_edge_assoc(changeset, type_of_edge_schema, subject, object)
      when is_atom(type_of_edge_schema) do
    put_edge_assoc(changeset, Bonfire.Common.Types.table_id(type_of_edge_schema), subject, object)
    |> Ecto.Changeset.unique_constraint([:subject_id, :object_id, :table_id],
      name:
        String.to_atom(
          "bonfire_data_edges_edge_#{type_of_edge_schema.__schema__(:source)}_unique_index"
        )
    )
  end

  def put_edge_assoc(changeset, type_id, subject, object) when is_binary(type_id) do
    %{
      # subject: subject,
      subject_id: uid(subject),
      # object: object,
      object_id: uid(object),
      table_id: type_id
    }
    |> debug()
    # |> Changesets.put_assoc(changeset, :edge, ...)
    |> Ecto.Changeset.cast(changeset, %{edge: ...}, [])
    |> Ecto.Changeset.cast_assoc(:edge, with: &Edge.changeset/2)
    |> debug()
  end

  @doc """
  Retrieves the edge with either:
  - a schema/context, subject, and object(s)
  - a schema/context, filters, and options

  ## Examples

      > get(MySchema, %User{id: 1}, %Post{id: 2})

      > get(MySchema, [%{subject: %User{id: 1}}], [])
  """
  def get(schema_or_context, subject, object, opts \\ [])

  def get(schema_or_context, filters, opts, []) when is_list(filters) and is_list(opts) do
    edge_query(schema_or_context, filters, opts)
    # |> debug
    |> repo().single()
  end

  def get(schema_or_context, subject, object, opts) do
    edge_query(schema_or_context, subject, object, opts)
    |> repo().single()
  end

  def get!(schema_or_context, subject, objects, opts \\ [])
  def get!(_, _subject, [], _opts), do: []

  def get!(schema_or_context, subject, objects, opts) when is_list(objects) do
    edge_query(schema_or_context, subject, objects, opts)
    |> repo().all()
  end

  def get!(schema_or_context, subject, object, opts) do
    edge_query(schema_or_context, subject, object, opts)
    |> limit(1)
    |> repo().one()
  end

  @doc """
  Retrieves the last edge of a given type, subject, and object from the database.

  ## Examples

      iex> last(MySchema, %User{id: 1}, %Post{id: 2}, [])
  """
  def last(schema_or_context, subject, object, opts) do
    edge_query(schema_or_context, subject, object, opts)
    |> limit(1)
    |> repo().one()
  end

  @doc """
  Retrieves the date of the last edge of a given type, subject, and object from the database.

  ## Examples

      > last_date(:like, %User{id: 1}, %Post{id: 2}, [])
      ~N[2023-07-25 12:34:56]
  """
  def last_date(type, subject, object, opts) do
    last(type, subject, object, Keyword.put(opts, :preload, false))
    |> DatesTimes.date_from_pointer()
  end

  @doc """
  Checks if an edge exists with the given schema/context, subject, and object.

  ## Examples

      > exists?(MySchema, %User{id: 1}, %Post{id: 2}, [])
      true
  """
  def exists?(schema_or_context, subject, object, opts) do
    edge_query(schema_or_context, subject, object, Keyword.put(opts, :preload, false))
    # |> info()
    |> repo().exists?()
  end

  @doc """
  Counts the edges for the given type, filters or object, and options.

  ## Examples

      > count(:like, %Post{id: 2}, [])
      42
  """
  def count(type, filters_or_object, opts \\ [])

  def count(type, object, _opts) when is_struct(object) do
    field_name = maybe_to_atom("#{type}_count")

    object
    |> repo().maybe_preload(field_name, follow_pointers: false)
    |> e(field_name, :object_count, nil)
  end

  def count(type, filters, opts) when is_list(filters) and is_list(opts) do
    edge_query(type, filters, Keyword.put(opts, :preload, :skip))
    |> Ecto.Query.exclude(:select)
    # |> Ecto.Query.exclude(:distinct)
    |> Ecto.Query.exclude(:preload)
    |> Ecto.Query.exclude(:order_by)
    |> select([type, edge], count(edge))
    |> repo().one()
  end

  @doc """
  Counts the edges for the given type, subject, object, and options.

  ## Examples

      > count_for_subject(:like, %User{id: 1}, %Post{id: 2}, [])
      42
  """
  def count_for_subject(type, subject, object, opts) do
    edge_query(type, subject, object, Keyword.put(opts, :preload, :skip))
    |> Ecto.Query.exclude(:select)
    # |> Ecto.Query.exclude(:distinct)
    |> Ecto.Query.exclude(:preload)
    |> Ecto.Query.exclude(:order_by)
    |> select([type, edge], count(edge))
    |> repo().one()
  end

  def edge_query(schema_or_context, filters, opts)
      when is_list(filters) and is_list(opts) do
    edge_module_query(schema_or_context, [filters, opts])
  end

  def edge_query({schema_or_context, type}, subject, object, opts) do
    edge_module_query(schema_or_context, [
      [subjects: subject, objects: object],
      type,
      Keyword.put_new(opts, :current_user, subject)
    ])
  end

  def edge_query(schema_or_context, subject, object, opts) do
    edge_module_query(
      schema_or_context,
      [
        [subjects: subject, objects: object],
        Keyword.put_new(opts, :current_user, subject)
      ]
    )
  end

  defp edge_module_query(schema_or_context, args) do
    if function_exported?(schema_or_context, :query, length(args)) do
      apply(schema_or_context, :query, args)
    else
      Bonfire.Common.QueryModule.maybe_query(schema_or_context, args)
    end
  end

  @doc "TODOC"
  def query(filters, opts) do
    from(root in Edge, as: :edge)
    |> boundarise(root.object_id, opts)
    |> filter(filters, opts)
  end

  @doc "TODOC"
  def query_parent(query_schema, filters, opts) do
    debug(opts, "Edge query opts")

    from(root in query_schema)
    |> reusable_join([root], edge in assoc(root, :edge), as: :edge)
    |> boundarise(edge.object_id, opts)
    |> maybe_proload(debug(opts[:preload]), filters[:object_types])
    |> filter(filters, opts)
  end

  defp maybe_proload(query, _preload?, object_type \\ nil)
  defp maybe_proload(query, _preload? = :skip, _object_type), do: query
  defp maybe_proload(query, _preload? = false, _object_type), do: query |> proload(:edge)

  defp maybe_proload(query, :subject, _object_type) do
    query
    |> proload(:edge)
    |> proload(edge: [subject: {"subject_", [:profile, :character]}])
  end

  defp maybe_proload(query, :object, object_type)
       #  TODO: autogenerate list of pointables with these assocs?, or find a way to check if it has these assocs in runtime
       when object_type in [Bonfire.Data.Social.Post, Bonfire.Data.Social.Message] do
    maybe_join_type(query, :object, object_type)
    |> maybe_proload(:object_post_content, nil)
  end

  defp maybe_proload(query, :object_post_content, _object_type) do
    query
    |> proload(edge: [object: {"object_", [:post_content]}])
  end

  defp maybe_proload(query, :object, object_type)
       when object_type in [Bonfire.Data.Identity.User, Bonfire.Classify.Category] do
    maybe_proload(query, :object_profile, object_type)
  end

  defp maybe_proload(query, :object_character, object_type) do
    maybe_join_type(query, :object, object_type)
    |> proload(edge: [object: {"object_", [:character]}])
  end

  defp maybe_proload(query, :object_profile, object_type) do
    maybe_join_type(query, :object, object_type)
    |> proload(edge: [object: {"object_", [:profile, :character]}])
  end

  defp maybe_proload(query, :object, nil) do
    maybe_join_type(query, :object, nil)
    |> maybe_proload(:object_post_content, nil)
  end

  defp maybe_proload(query, :object, object_type) do
    maybe_join_type(query, :object, object_type)
  end

  defp maybe_proload(query, :object_with_creator, object_type) do
    query
    |> maybe_proload(:object, object_type)
    |> proload(
      edge: [
        object:
          {"object_",
           [
             created: [creator: {"creator_", [:profile, :character]}]
           ]}
      ]
    )
  end

  defp maybe_proload(query, preloads, _object_type) when is_list(preloads) do
    Enum.reduce(preloads, query, fn preload, query ->
      maybe_proload(query, preload)
    end)
  end

  # default
  defp maybe_proload(query, _, object_type) do
    query
    |> maybe_proload(:object, object_type)
    |> maybe_proload(:subject)
  end

  defp maybe_join_type(query, :object, object_type)
       when is_atom(object_type) and not is_nil(object_type) do
    query
    |> proload(:edge)
    |> reusable_join(:left, [edge: edge], object in ^object_type,
      as: :object,
      on: edge.object_id == object.id
    )
  end

  defp maybe_join_type(query, :object, _object_type) do
    query
    |> proload(:edge)
    |> proload(edge: [:object])
  end

  @doc "TODOC"
  def filters_from_opts(%{assigns: assigns}) do
    input_to_atoms(
      e(assigns, :feed_filters, nil) || e(assigns, :__context__, :current_params, nil) || %{}
    )
    |> Map.new()
  end

  def filters_from_opts(%{__context__: _} = assigns) do
    filters_from_opts(%{assigns: assigns})
  end

  def filters_from_opts(opts) when is_list(opts) do
    Map.new(opts)
    |> filters_from_opts()
  end

  def filters_from_opts(opts) do
    Map.new(opts)
  end

  defp filter(query, filters, opts) when is_list(filters) or is_map(filters) do
    filters = Keyword.new(filters)
    # |> debug("filters")

    Enum.reduce(filters, query, &filter(&2, &1, opts))
    |> query_filter(Keyword.drop(filters, @skip_warn_filters))
    |> debug()
  end

  defp filter(query, {:subjects, subject}, opts) do
    case subject do
      :visible ->
        boundarise(query, edge.subject_id, opts)

      _ when is_map(subject) or is_binary(subject) or is_list(subject) ->
        where(query, [edge: edge], edge.subject_id in ^uids(subject))

      _ ->
        warn(subject, "unrecognised subject")
        query
    end
  end

  defp filter(query, {:objects, object}, opts) do
    case object do
      :visible ->
        boundarise(query, edge.object_id, opts)

      _ when is_map(object) or is_binary(object) or is_list(object) ->
        where(query, [edge: edge], edge.object_id in ^uids(object))

      _ ->
        warn(object, "unrecognised object")
        query
    end
  end

  defp filter(query, {:activity_types, types}, _opts) do
    debug(types, "filter by activity_types")

    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [edge: edge], edge.table_id in ^table_ids)

      _ ->
        query
    end
  end

  defp filter(query, {:in_thread, thread_ids}, _opts) do
    query
    |> proload(edge: [:replied])
    |> Bonfire.Social.Threads.filter(:in_thread, thread_ids, ...)
  end

  defp filter(query, {:tree_parent, parents}, _opts) do
    query
    |> proload(edge: [:tree])
    |> where([tree: tree], tree.parent_id in ^uids(parents))
  end

  defp filter(query, {common, _}, _opts)
       when common in @skip_warn_filters do
    query
  end

  defp filter(query, filters, _opts) do
    warn(filters, "Filter params not recognised")
    query
  end

  @doc """
  Deletes edges where the given user is the subject.

  ## Examples

      iex> delete_by_subject(%User{id: 1})
      :ok
  """
  def delete_by_subject(user),
    do: query([subjects: user], skip_boundary_check: true) |> do_delete()

  @doc """
  Deletes edges where the given user is the object.

  ## Examples

      iex> delete_by_object(%User{id: 1})
      :ok
  """
  def delete_by_object(user),
    do: query([objects: user], skip_boundary_check: true) |> do_delete()

  # doc "Delete edges where i am the subject and/or the object."
  # defp delete_by_any(me), do: do_delete(by_any_q(me))

  @doc """
  Deletes edges by subject, type, and object

  ## Examples

      iex> delete_by_both(%User{id: 1}, MySchema, %User{id: 2})
      :ok
  """
  def delete_by_both(me, schema, object),
    do:
      [subjects: me, objects: object, table_id: Bonfire.Common.Types.table_id(schema)]
      |> query(skip_boundary_check: true)
      |> do_delete()

  defp do_delete(q),
    do:
      q
      |> Ecto.Query.exclude(:preload)
      |> Ecto.Query.exclude(:order_by)
      |> repo().delete_many()
      |> elem(1)
end
