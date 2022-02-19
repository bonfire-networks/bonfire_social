defmodule Bonfire.Social.Edges do
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo
  import Bonfire.Boundaries.Queries
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.Objects

  def changeset(schema, subject, verb, object, preset_or_custom_boundary) do
    %{edge: %{subject_id: ulid(subject), object_id: ulid(object)}}
    |> schema.changeset()
    |> Changeset.cast_assoc(:edge, [:required, with: &Edge.changeset/2])
    |> Objects.cast_basic(%{verb: verb}, subject, preset_or_custom_boundary)
    # |> Changeset.cast_assoc(:controlled)
  end

  def get(schema, subject, object, opts \\ []) do
    do_query(schema, subject, object, opts)
    |> repo().single()
  end

  def get!(schema, subject, objects, opts \\ [])
  def get!(schema, subject, [], opts) do
    []
  end
  def get!(schema, subject, objects, opts) when is_list(objects) do
    do_query(schema, subject, objects, opts)
    |> repo().all()
  end
  def get!(schema, subject, object, opts) do
    do_query(schema, subject, object, opts)
    |> repo().one()
  end

  defp do_query(schema, subject, object, opts \\ []) do
    [subject: subject, object: object]
    |> schema.query(Keyword.put_new(opts, :current_user, subject))
    # |> debug()
  end

  def query(filters, opts) do
    from(root in Edge, as: :edge)
    |> boundarise(root.id, opts)
    |> filter(filters, opts)
  end

  def query_parent(schema, filters, opts) do
    # debug(opts)
    from(root in schema, as: :root)
    |> proload(:edge)
    |> boundarise(root.id, opts)
    |> filter(filters, opts)
    |> maybe_proload(!is_list(opts) || opts[:preload])
  end

  defp maybe_proload(query, _skip_preload? = false), do: query

  defp maybe_proload(query, :subject) do
    query
    |> proload([edge: [
      subject: {"subject_", [:profile, :character]}
      ]])
  end

  defp maybe_proload(query, :object) do
    query
    |> proload([edge: [
      object: {"object_", [:profile, :character]}
      ]])
  end

  defp maybe_proload(query, _) do
    query
    |> maybe_proload(:object)
    |> maybe_proload(:subject)
  end

  defp filter(query, filters, opts) when is_list(filters),
    do: Enum.reduce(filters, query, &filter(&2, &1, opts))

  defp filter(query, {:subject, subject}, opts) do
    case subject do
      :visible -> boundarise(query, edge.subject_id, opts)
      _ when is_list(subject) ->
        where(query, [edge: edge], edge.subject_id in ^ulid(subject))
      _ when is_map(subject) or is_binary(subject) ->
        where(query, [edge: edge], edge.subject_id == ^ulid(subject))
    end
  end

  defp filter(query, {:object, object}, opts) do
    case object do
      :visible -> boundarise(query, edge.object_id, opts)
      _ when is_list(object) ->
        where(query, [edge: edge], edge.object_id in ^ulid(object))
      _ when is_map(object) or is_binary(object) ->
        where(query, [edge: edge], edge.object_id == ^ulid(object))
    end
  end

  defp filter(query, filters, _opts) do
    warn("Edges: unrecognised filters: #{inspect filters} so just returning query as-is")
    query
  end

  #doc "Delete Follows where i am the subject"
  def delete_by_subject(user), do: query([subject: user], skip_boundary_check: true) |> do_delete()

  #doc "Delete Follows where i am the object"
  def delete_by_object(user), do: query([object: user], skip_boundary_check: true) |> do_delete()

  #doc "Delete Follows where i am the subject or the object."
  # defp delete_by_any(me), do: do_delete(by_any_q(me))

  #doc "Delete Follows where i am the subject and someone else is the object."
  def delete_by_both(me, object), do: [subject: me, object: object] |> query(skip_boundary_check: true) |> do_delete()

  defp do_delete(q), do: Ecto.Query.exclude(q, :preload) |> repo().delete_all() |> elem(1)

end
