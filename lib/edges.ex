defmodule Bonfire.Social.Edges do
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
    :object,
    :subject,
    :type,
    :object_type,
    :subject_type,
    :current_user,
    :current_account,
    :id,
    :table_id,
    :after,
    :before,
    :paginate,
    :paginate?
  ]

  def insert(schema, subject, verb, object, options) do
    changeset(schema, subject, verb, object, options)
    |> insert()
    |> preload_inserted(subject, object)
  end

  def insert(changeset, subject \\ nil, object \\ nil) do
    changeset
    |> Changeset.unique_constraint([:subject_id, :object_id, :table_id])
    |> repo().insert()
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

  def changeset(schema, subject, verb, object, options) do
    changeset_base(schema, subject, object, options)
    |> Objects.cast_creator_caretaker(subject)
    |> Acls.cast(subject, options)
    |> Activities.put_assoc(verb, subject, object)
    |> FeedActivities.put_feed_publishes(Keyword.get(options, :to_feeds, []))
  end

  def changeset_base(schema, subject, object, options) when is_atom(schema),
    do: changeset_base({schema, schema}, subject, object, options)

  def changeset_base({insert_schema, type_schema}, subject, object, _options) do
    Changesets.cast(struct(insert_schema), %{}, [])
    |> put_edge_assoc(type_schema, subject, object)
  end

  def put_edge_assoc(changeset, subject, object),
    do: put_edge_assoc(changeset, changeset.data.__struct__, subject, object)

  def put_edge_assoc(changeset, schema, subject, object) do
    table_name = schema.__schema__(:source)

    %{
      # subject: subject,
      subject_id: ulid(subject),
      # object: object,
      object_id: ulid(object),
      table_id: Bonfire.Common.Types.table_id(schema)
    }
    |> debug()
    # |> Changesets.put_assoc(changeset, :edge, ...)
    |> Ecto.Changeset.cast(changeset, %{edge: ...}, [])
    |> Ecto.Changeset.cast_assoc(:edge, with: &Edge.changeset/2)
    |> Ecto.Changeset.unique_constraint([:subject_id, :object_id, :table_id],
      name: String.to_atom("bonfire_data_edges_edge_#{table_name}_unique_index")
    )
    |> debug()
  end

  def get(schema_or_context, subject, object, opts \\ [])

  def get(schema_or_context, filters, opts, []) when is_list(filters) and is_list(opts) do
    do_query(schema_or_context, filters, opts)
    # |> debug
    |> repo().single()
  end

  def get(schema_or_context, subject, object, opts) do
    do_query(schema_or_context, subject, object, opts)
    |> repo().single()
  end

  def get!(schema_or_context, subject, objects, opts \\ [])
  def get!(_, _subject, [], _opts), do: []

  def get!(schema_or_context, subject, objects, opts) when is_list(objects) do
    do_query(schema_or_context, subject, objects, opts)
    |> repo().all()
  end

  def get!(schema_or_context, subject, object, opts) do
    do_query(schema_or_context, subject, object, opts)
    |> limit(1)
    |> repo().one()
  end

  @doc "retrieves the last edge of a given type, subject, and object from the database"
  def last(schema_or_context, subject, object, opts) do
    do_query(schema_or_context, subject, object, opts)
    |> limit(1)
    |> repo().one()
  end

  @doc "retrieves the date of the last edge of a given type, subject, and object from the database"
  def last_date(type, subject, object, opts) do
    last(type, subject, object, Keyword.put(opts, :preload, false))
    |> DatesTimes.date_from_pointer()
  end

  def exists?(schema_or_context, subject, object, opts) do
    do_query(schema_or_context, subject, object, Keyword.put(opts, :preload, false))
    # |> info()
    |> repo().exists?()
  end

  def count(type, filters_or_object, opts \\ [])

  def count(type, object, _opts) when is_struct(object) do
    field_name = maybe_to_atom("#{type}_count")

    object
    |> repo().maybe_preload(field_name, follow_pointers: false)
    |> e(field_name, :object_count, nil)
  end

  def count(type, filters, opts) when is_list(filters) and is_list(opts) do
    do_query(type, filters, Keyword.put(opts, :preload, :skip))
    |> Ecto.Query.exclude(:select)
    # |> Ecto.Query.exclude(:distinct)
    |> Ecto.Query.exclude(:preload)
    |> Ecto.Query.exclude(:order_by)
    |> select([type, edge], count(edge))
    |> repo().one()
  end

  def count_for_subject(type, subject, object, opts) do
    do_query(type, subject, object, Keyword.put(opts, :preload, :skip))
    |> Ecto.Query.exclude(:select)
    # |> Ecto.Query.exclude(:distinct)
    |> Ecto.Query.exclude(:preload)
    |> Ecto.Query.exclude(:order_by)
    |> select([type, edge], count(edge))
    |> repo().one()
  end

  # defp do_query(type, subject, object, opts \\ [])

  defp do_query(schema_or_context, filters, opts)
       when is_list(filters) and is_list(opts) do
    edge_module_query(schema_or_context, [filters, opts])
  end

  defp do_query({schema_or_context, type}, subject, object, opts) do
    edge_module_query(schema_or_context, [
      [subject: subject, object: object],
      type,
      Keyword.put_new(opts, :current_user, subject)
    ])
  end

  defp do_query(schema_or_context, subject, object, opts) do
    edge_module_query(
      schema_or_context,
      [
        [subject: subject, object: object],
        Keyword.put_new(opts, :current_user, subject)
      ]
    )
  end

  def edge_module_query(schema_or_context, args) do
    if function_exported?(schema_or_context, :query, length(args)) do
      apply(schema_or_context, :query, args)
    else
      Bonfire.Common.QueryModule.maybe_query(schema_or_context, args)
    end
  end

  def query(filters, opts) do
    from(root in Edge, as: :edge)
    |> boundarise(root.object_id, opts)
    |> filter(filters, opts)
  end

  def query_parent(query_schema, filters, opts) do
    # debug(opts)
    from(root in query_schema)
    |> reusable_join([root], edge in assoc(root, :edge), as: :edge)
    |> boundarise(edge.object_id, opts)
    |> maybe_proload(opts[:preload], filters[:object_type] |> debug)
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
    |> proload(edge: [object: {"object_", [:post_content]}])
  end

  defp maybe_proload(query, :object, object_type)
       when object_type in [Bonfire.Data.Identity.User, Bonfire.Classify.Category] do
    maybe_join_type(query, :object, object_type)
    |> proload(edge: [object: {"object_", [:profile, :character]}])
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

  # defp maybe_proload(query, preloads, _object_type) when is_list(preloads) do
  #   Enum.reduce(preloads, query, fn preload, query ->
  #     maybe_proload(query, preload)
  #   end)
  # end

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
    |> join(:left, [edge: edge], object in ^object_type,
      as: :object,
      on: edge.object_id == object.id
    )
  end

  defp maybe_join_type(query, :object, _object_type) do
    query
    |> proload(:edge)
    |> proload(edge: [:object])
  end

  def filters_from_opts(%{assigns: assigns}) do
    input_to_atoms(
      e(assigns, :feed_filters, nil) || e(assigns, :__context__, :current_params, nil) || %{}
    )
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

  defp filter(query, {:subject, subject}, opts) do
    case subject do
      :visible ->
        boundarise(query, edge.subject_id, opts)

      _ when is_list(subject) ->
        where(query, [edge: edge], edge.subject_id in ^ulids(subject))

      _ when is_map(subject) or is_binary(subject) ->
        where(query, [edge: edge], edge.subject_id == ^ulid(subject))
    end
  end

  defp filter(query, {:object, object}, opts) do
    case object do
      :visible ->
        boundarise(query, edge.object_id, opts)

      _ when is_list(object) ->
        where(query, [edge: edge], edge.object_id in ^ulids(object))

      _ when is_map(object) or is_binary(object) ->
        where(query, [edge: edge], edge.object_id == ^ulid(object))

      _ ->
        warn(object, "unrecognised object")
        query
    end
  end

  defp filter(query, {:type, types}, _opts) do
    debug(types, "filter by types")

    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [edge: edge], edge.table_id in ^table_ids)

      _ ->
        query
    end
  end

  defp filter(query, {:subject_type, types}, _opts) do
    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [subject: subject], subject.table_id in ^table_ids)

      _ ->
        query
    end
  end

  defp filter(query, {:exclude_subject_type, types}, _opts) do
    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [subject: subject], subject.table_id not in ^table_ids)

      _ ->
        query
    end
  end

  defp filter(query, {:object_type, types}, _opts) when is_list(types) do
    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [object: object], object.table_id in ^table_ids)

      _ ->
        query
    end
  end

  defp filter(query, {:exclude_object_type, types}, _opts) do
    case Bonfire.Common.Types.table_types(types) |> debug("exclude_object_type") do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [object: object], object.table_id not in ^table_ids)

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
    |> where([tree: tree], tree.parent_id in ^ulids(parents))
  end

  defp filter(query, {common, _}, _opts)
       when common in @skip_warn_filters do
    query
  end

  defp filter(query, filters, _opts) do
    warn(filters, "Filter params not recognised")
    query
  end

  # doc "Delete Follows where i am the subject"
  def delete_by_subject(user),
    do: query([subject: user], skip_boundary_check: true) |> do_delete()

  # doc "Delete Follows where i am the object"
  def delete_by_object(user),
    do: query([object: user], skip_boundary_check: true) |> do_delete()

  # doc "Delete Follows where i am the subject or the object."
  # defp delete_by_any(me), do: do_delete(by_any_q(me))

  # doc "Delete Follows where i am the subject and someone else is the object."
  def delete_by_both(me, schema, object),
    do:
      [subject: me, object: object, table_id: Bonfire.Common.Types.table_id(schema)]
      |> query(skip_boundary_check: true)
      |> do_delete()

  defp do_delete(q),
    do:
      q
      |> Ecto.Query.exclude(:preload)
      |> Ecto.Query.exclude(:order_by)
      |> repo().delete_all()
      |> elem(1)
end
