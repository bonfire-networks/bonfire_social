defmodule Bonfire.Social.API.UserInteractionsDataloader do
  @moduledoc """
  Dataloader.KV source for batch-loading user interaction states (liked, boosted, bookmarked).
  Prevents N+1 queries when loading feed activities in GraphQL.

  This batches interaction checks per activity, only querying for the specific activities
  in the current feed, rather than loading ALL of a user's interactions.
  """

  alias Bonfire.Data.Social.{Like, Boost, Bookmark}
  alias Bonfire.Data.Edges.Edge
  import Ecto.Query
  use Bonfire.Common.Repo

  @doc """
  Creates a new Dataloader.KV source for user interactions.
  """
  def data do
    Dataloader.KV.new(&fetch/2)
  end

  @doc """
  Fetch function for Dataloader.KV.
  Receives a batch name and a list of argument maps.
  Returns a map of args => boolean result.

  ## Examples

      # Dataloader batches requests like:
      fetch(:liked, [
        %{user_id: "user123", activity_id: "act1"},
        %{user_id: "user123", activity_id: "act2"}
      ])
      # => %{
      #   %{user_id: "user123", activity_id: "act1"} => true,
      #   %{user_id: "user123", activity_id: "act2"} => false
      # }
  """
  def fetch(:liked, args) do
    args
    |> MapSet.to_list()
    |> batch_check_interaction(Like)
  end

  def fetch(:boosted, args) do
    args
    |> MapSet.to_list()
    |> batch_check_interaction(Boost)
  end

  def fetch(:bookmarked, args) do
    args
    |> MapSet.to_list()
    |> batch_check_interaction(Bookmark)
  end

  # Fallback for unknown batches
  def fetch(_batch, args) do
    args
    |> MapSet.to_list()
    |> Enum.reduce(%{}, fn arg, acc ->
      Map.put(acc, arg, nil)
    end)
  end

  @doc """
  Batch check if user has performed a specific interaction on multiple activities.
  Uses a single query to check all user+activity pairs for the given interaction type.

  ## Examples

      batch_check_interaction(
        [%{user_id: "user1", activity_id: "act1"}],
        Bonfire.Data.Social.Like
      )
      # => %{%{user_id: "user1", activity_id: "act1"} => true}
  """
  def batch_check_interaction(args, interaction_module) do
    # Extract unique user_ids and activity_ids
    user_ids = args |> Enum.map(& &1.user_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)
    activity_ids = args |> Enum.map(& &1.activity_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)

    # If no valid IDs, return all false
    if Enum.empty?(user_ids) || Enum.empty?(activity_ids) do
      args
      |> Enum.reduce(%{}, fn arg, acc ->
        Map.put(acc, arg, false)
      end)
    else
      # Get the table_id for this interaction type
      table_id = interaction_module.__pointers__(:table_id)

      # Single query to get all matching edges
      existing_edges =
        from(e in Edge,
          where: e.subject_id in ^user_ids,
          where: e.object_id in ^activity_ids,
          where: e.table_id == ^table_id,
          select: {e.subject_id, e.object_id}
        )
        |> repo().all()
        |> MapSet.new()

      # Build result map
      args
      |> Enum.reduce(%{}, fn %{user_id: uid, activity_id: aid} = arg, acc ->
        exists = MapSet.member?(existing_edges, {uid, aid})
        Map.put(acc, arg, exists)
      end)
    end
  end
end
