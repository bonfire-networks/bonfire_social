defmodule Bonfire.Social.Seen do
  @moduledoc """
  Track seen/unseen status of things (usually `Activities`).

  This module implements functionality to manage the seen/unseen status of objects (similar to read/unread status in other apps, but only indicates that it was displayed in a feed or other listing for the user, not that they actually read it). 

  Seen is implemented on top of the `Bonfire.Data.Edges.Edge` schema (see `Bonfire.Social.Edges` for shared functions).
  """

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Seen
  # alias Bonfire.Data.Social.SeenCount
  # alias Bonfire.Boundaries.Verbs

  # alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  # alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social
  # alias Bonfire.Social.Objects

  alias Bonfire.Social.Edges
  # alias Bonfire.Social.Objects
  # alias Bonfire.Social.Feeds

  # import Ecto.Query
  # import Bonfire.Social
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Seen
  def query_module, do: __MODULE__

  @doc """
  Checks if a user has seen an object.

  ## Parameters

    - user: The user to check.
    - object: The object to check if seen.

  ## Examples

      iex> user = %User{id: "user123"}
      iex> object = %Post{id: "post456"}
      iex> Bonfire.Social.Seen.seen?(user, object)
      true

  """
  def seen?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  def last_date(subject, object) do
    Edges.last_date(__MODULE__, subject, object, skip_boundary_check: true)
  end

  @doc """
  Retrieves a Seen edge between a subject and an object.

  ## Parameters

    - subject: The subject (usually a user) of the Seen edge.
    - object: The object that was seen.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> subject = %User{id: "user123"}
      iex> object = %Post{id: "post456"}
      iex> Bonfire.Social.Seen.get(subject, object)
      {:ok, %Seen{}}

  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts ++ [skip_boundary_check: true])

  @doc """
    Similar to `get/3`, but raises an error if the Seen edge is not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts ++ [skip_boundary_check: true])

  # def by_subject(%{}=subject), do: [subjects: subject] |> query(current_user: subject) |> repo().many()

  @doc """
  Marks an object as seen by a user.

  ## Parameters

    - subject: The user marking the object as seen.
    - object: The object(s) or ID(s) being marked as seen.

  ## Examples

      iex> user = %User{id: "user123"}
      iex> object = %Post{id: "post456"}
      iex> Bonfire.Social.Seen.mark_seen(user, object)
      {:ok, %Seen{}}

      iex> Bonfire.Social.Seen.mark_seen(user, "456")
      {:ok, %Seen{}}

  """
  def mark_seen(subject, object, opts \\ [])

  def mark_seen(%{} = subject, %{id: _} = object, opts) do
    case create(subject, object, opts) do
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

  def mark_seen(%{} = subject, object, opts) when is_binary(object) do
    with {:ok, seen} <-
           Bonfire.Common.Needles.get(object, current_user: subject, verb: :see) do
      # debug(seen)
      mark_seen(subject, seen, opts)
    end
  end

  # TODO: bulk with insert_all 
  def mark_seen(%{} = subject, objects, opts) when is_list(objects) do
    Enum.each(objects, &mark_seen(subject, &1, opts))
    Enum.count(objects)
  end

  @doc """
  Marks an object as unseen by a user.

  ## Parameters

  - subject: The user marking the object as unseen.
  - object: The object or ID being marked as unseen.

  ## Examples

  iex> user = %User{id: "user123"}
  iex> object = %Post{id: "post456"}
  iex> Bonfire.Social.Seen.mark_unseen(user, object)
  {:ok, nil}

  iex> Bonfire.Social.Seen.mark_unseen(user, "456")

  """
  def mark_unseen(%User{} = subject, %{} = object) do
    # delete the Seen
    Edges.delete_by_both(subject, Seen, object)

    # Note: the seen count is automatically decremented by DB triggers
  end

  def mark_unseen(%User{} = subject, object) when is_binary(object) do
    with {:ok, seen} <-
           Bonfire.Common.Needles.get(object, current_user: subject) do
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
    # def query([my: :seens], opts), do: [subjects: current_user(opts)] |> query(opts)
  end

  @doc """
  Creates a query for Seen edges based on the given filters and options.

  ## Parameters

    - filters: A keyword list of filters to apply to the query.
    - opts: Additional options for the query.

  ## Examples

      iex> filters = [subjects: %User{id: "123"}]
      iex> opts = [limit: 10]
      iex> Bonfire.Social.Seen.query(filters, opts)
      #Ecto.Query<...>

  """
  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(subject, seen, opts \\ []) do
    if opts[:upsert] do
      Edges.changeset_base(Seen, subject, seen, opts)
      |> repo().upsert()
    else
      Edges.changeset_base(Seen, subject, seen, opts)
      |> repo().insert()
    end

    # |> repo().maybe_preload(edge: [:object])
  end
end
