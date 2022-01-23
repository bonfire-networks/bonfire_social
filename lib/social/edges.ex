defmodule Bonfire.Social.Edges do

  alias Bonfire.Data.Edges.Edge

  import Bonfire.Boundaries.Queries
  use Bonfire.Common.Utils

  use Bonfire.Repo,
      schema: Edge

  def query(filters, opts) do
    from(root in Edge, as: :edge)
    |> boundarise(root.id, opts)
    |> filter(filters, opts)
  end

  def query_parent(schema, filters, opts) do
    from(root in schema, as: :root)
    |> proload(:edge)
    |> boundarise(root.id, opts)
    |> filter(filters, opts)
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
    Logger.warn("Edges: unrecognised filters: #{inspect filters} so just returning query as-is")
    query
  end

  def changeset(schema, subject, object) do
    # TODO get table_id based on schema
    schema.changeset(%{edge: %{
      subject_id: ulid(subject),
      object_id: ulid(object)
      }})
    |> Changeset.cast_assoc(:edge, [:required, with: &Edge.changeset/2])
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
