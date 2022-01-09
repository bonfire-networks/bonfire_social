defmodule Bonfire.Social.Edges do

  import Bonfire.Boundaries.Queries
  import Bonfire.Common.Utils
  import Ecto.Query
  import EctoSparkles
  require Logger

  def query(schema, filters, opts) do
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
end
