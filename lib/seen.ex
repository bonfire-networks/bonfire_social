defmodule Bonfire.Social.Seen do
  @moduledoc """
  Track seen/unseen (similar to read/unread, but only indicates that it was displayed in a feed or other listing for the user, not that they actually read it) status of things (usually `Activities`)
  """
  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Seen
  # alias Bonfire.Data.Social.SeenCount
  alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Integration
  alias Bonfire.Social.Objects

  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  # import Ecto.Query
  # import Bonfire.Social.Integration
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  def queries_module, do: Seen
  def context_module, do: Seen

  def seen?(%{} = user, object),
    do: not is_nil(get!(user, object, skip_boundary_check: true))

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  # def by_subject(%{}=subject), do: [subject: subject] |> query(current_user: subject) |> repo().many()

  def mark_seen(%User{} = subject, %{id: _} = object) do
    case create(subject, object) do
      {:ok, seen} ->
        {:ok, seen}

      {:error, e} ->
        case get(subject, object) do
          {:ok, seen} ->
            debug(seen, "the user has already seen this object")
            {:ok, seen}

          _ ->
            error(e)
            {:error, e}
        end
    end
  rescue
    e in Ecto.ConstraintError ->
      debug(e, "the user has already seen this object")
      {:ok, nil}
  end

  def mark_seen(%User{} = subject, object) when is_binary(object) do
    with {:ok, seen} <-
           Bonfire.Common.Pointers.get(object, current_user: subject, verb: :see) do
      # debug(seen)
      mark_seen(subject, seen)
    end
  end

  def mark_seen(%User{} = subject, objects) do
    Enum.each(objects, &mark_seen(subject, &1))
    Enum.count(objects)
  end

  def mark_unseen(%User{} = subject, %{} = object) do
    # delete the Seen
    Edges.delete_by_both(subject, Seen, object)

    # Note: the seen count is automatically decremented by DB triggers
  end

  def mark_unseen(%User{} = subject, object) when is_binary(object) do
    with {:ok, seen} <-
           Bonfire.Common.Pointers.get(object, current_user: subject) do
      mark_unseen(subject, seen)
    end
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Seen, filters, opts)

    # |> proload(edge: [
    #   # subject: {"subject_", [:profile, :character]},
    #   # object: {"seen_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
    # def query([my: :seens], opts), do: [subject: current_user(opts)] |> query(opts)
  end

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(subject, seen, opts \\ []) do
    Edges.changeset_base(Seen, subject, seen, opts)
    |> repo().insert()

    # |> repo().maybe_preload(edge: [:object])
  end
end
