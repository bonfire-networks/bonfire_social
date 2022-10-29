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

  alias Pointers.Changesets
  alias Pointers.ULID

  def insert(schema, subject, verb, object, options) do
    changeset(schema, subject, verb, object, options)
    |> Changeset.unique_constraint([:subject_id, :object_id, :table_id])
    |> repo().insert()
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

    # |> repo().maybe_preload(edge: [:subject, :object])
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

  def changeset_base({insert_schema, type_schema}, subject, object, options) do
    Changesets.cast(struct(insert_schema), %{}, [])
    |> put_edge_assoc(type_schema, subject, object)
  end

  def put_edge_assoc(changeset, subject, object),
    do: put_edge_assoc(changeset, changeset.data.__struct__, subject, object)

  def put_edge_assoc(changeset, schema, subject, object) do
    %{
      # subject: subject,
      subject_id: ulid(subject),
      # object: object,
      object_id: ulid(object),
      table_id: Bonfire.Common.Types.table_id(schema)
    }
    |> info()
    # |> Changesets.put_assoc(changeset, :edge, ...)
    |> Ecto.Changeset.cast(changeset, %{edge: ...}, [])
    |> Ecto.Changeset.cast_assoc(:edge, with: &Edge.changeset/2)
  end

  def get(type, subject, object, opts \\ [])

  def get(type, filters, opts, []) when is_list(filters) and is_list(opts) do
    do_query(type, filters, opts)
    # |> debug
    |> repo().single()
  end

  def get(type, subject, object, opts) do
    do_query(type, subject, object, opts)
    |> repo().single()
  end

  def get!(type, subject, objects, opts \\ [])
  def get!(type, subject, [], opts), do: []

  def get!(type, subject, objects, opts) when is_list(objects) do
    do_query(type, subject, objects, opts)
    |> repo().all()
  end

  def get!(type, subject, object, opts) do
    do_query(type, subject, object, opts)
    |> limit(1)
    |> repo().one()
  end

  def exists?(type, subject, object, opts) do
    do_query(type, subject, object, opts)
    |> info()
    |> repo().exists?()
  end

  # defp do_query(type, subject, object, opts \\ [])

  defp do_query(type_context, filters, opts)
       when is_list(filters) and is_list(opts) do
    type_context.query(filters, opts)
  end

  defp do_query({type_context, type}, subject, object, opts) do
    type_context.query(
      [subject: subject, object: object],
      type,
      Keyword.put_new(opts, :current_user, subject)
    )
  end

  defp do_query(type_context, subject, object, opts) do
    type_context.query(
      [subject: subject, object: object],
      Keyword.put_new(opts, :current_user, subject)
    )
  end

  def query(filters, opts) do
    from(root in Edge, as: :edge)
    |> boundarise(root.id, opts)
    |> filter(filters, opts)
  end

  def query_parent(query_schema, filters, opts) do
    # debug(opts)
    from(root in query_schema)
    |> proload(:edge)
    |> boundarise(id, opts)
    |> maybe_proload(e(opts, :preload, nil))
    |> filter(filters, opts)
  end

  defp maybe_proload(query, _skip_preload? = false), do: query

  defp maybe_proload(query, :subject) do
    proload(query,
      edge: [subject: {"subject_", [:profile, :character]}]
    )
  end

  defp maybe_proload(query, :object) do
    proload(query,
      edge: [object: {"object_", [:profile, :character, :post_content]}]
    )
  end

  defp maybe_proload(query, _) do
    query
    |> maybe_proload(:object)
    |> maybe_proload(:subject)
  end

  defp filter(query, filters, opts) when is_list(filters) do
    # debug(filters, "filters")
    Enum.reduce(filters, query, &filter(&2, &1, opts))
    |> query_filter(
      Keyword.drop(filters, [
        :object,
        :subject,
        :type,
        :object_type,
        :current_user,
        :current_account
      ])
    )

    # |> info()
  end

  defp filter(query, {:subject, subject}, opts) do
    case subject do
      :visible ->
        boundarise(query, edge.subject_id, opts)

      _ when is_list(subject) ->
        where(query, [edge: edge], edge.subject_id in ^ulid(subject))

      _ when is_map(subject) or is_binary(subject) ->
        where(query, [edge: edge], edge.subject_id == ^ulid(subject))
    end
  end

  defp filter(query, {:object, object}, opts) do
    case object do
      :visible ->
        boundarise(query, edge.object_id, opts)

      _ when is_list(object) ->
        where(query, [edge: edge], edge.object_id in ^ulid(object))

      _ when is_map(object) or is_binary(object) ->
        where(query, [edge: edge], edge.object_id == ^ulid(object))
    end
  end

  defp filter(query, {:type, types}, opts) do
    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [edge: edge], edge.table_id in ^table_ids)

      _ ->
        query
    end
  end

  defp filter(query, {:subject_type, types}, opts) do
    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [subject: subject], subject.table_id in ^table_ids)

      _ ->
        query
    end
  end

  defp filter(query, {:object_type, types}, opts) do
    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [object: object], object.table_id in ^table_ids)

      _ ->
        query
    end
  end

  defp filter(query, {common, _}, _opts)
       when common in [:id, :current_user, :current_account, :table_id] do
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
