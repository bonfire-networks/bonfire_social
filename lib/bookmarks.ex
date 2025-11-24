defmodule Bonfire.Social.Bookmarks do
  @moduledoc """
  Mutate or query bookmarks (similar to likes but only visible to the creator of the bookmark)

  Bookmarks are implemented on top of the `Bonfire.Data.Edges.Edge` schema (see `Bonfire.Social.Edges` for shared functions)
  """

  # alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Bookmark
  # alias Bonfire.Data.Social.LikeCount
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  # alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social
  # alias Bonfire.Social.Objects

  # alias Bonfire.Social.Objects
  # alias Bonfire.Social.Feeds

  # import Ecto.Query
  # import Bonfire.Social
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Bookmark
  def query_module, do: __MODULE__

  @doc """
  Checks if a user has bookmarked an object.

  ## Examples

      iex> Bonfire.Social.Bookmarks.bookmarked?(user, object)
      true

  """
  def bookmarked?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  @doc """
  Retrieves a bookmark by subject and object.

  ## Examples

      iex> Bonfire.Social.Bookmarks.get(user, object)
      {:ok, %Bonfire.Data.Social.Bookmark{}}

  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  @doc """
  Retrieves a bookmark edge, raising an error if not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  @doc """
  Retrieves bookmarked objects by a subject.

  ## Examples

      iex> Bonfire.Social.Bookmarks.by_bookmarker(user)
      [%Bonfire.Data.Social.Bookmark{}, ...]

  """
  def by_bookmarker(subject, opts \\ []) when is_map(subject) or is_binary(subject),
    do:
      (opts ++ [subjects: subject])
      |> query([current_user: subject] ++ List.wrap(opts))
      |> repo().many()

  @doc """
  Retrieves bookmark(er)s for an object.

  ## Examples

      iex> Bonfire.Social.Bookmarks.by_bookmarked(object)
      [%Bonfire.Data.Social.Bookmark{}, ...]

  """
  def by_bookmarked(object, opts \\ []) when is_map(object) or is_binary(object),
    do: (opts ++ [objects: object]) |> query(opts) |> repo().many()

  @doc """
  Counts bookmarks based on filters and options.

  ## Examples

      iex> Bonfire.Social.Bookmarks.count([subject: user_id], [])
      5

      iex> Bonfire.Social.Bookmarks.count(user, object)
      1

      iex> Bonfire.Social.Bookmarks.count(object, [])
      10

  """
  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(%{} = object, _), do: Edges.count(:bookmark, object, skip_boundary_check: true)

  @doc """
  Bookmarks an object for a user.

  ## Examples

      iex> Bonfire.Social.Bookmarks.bookmark(user, object)
      {:ok, %Bonfire.Data.Social.Bookmark{}}

  """
  def bookmark(%{} = bookmarker, bookmarked, opts \\ []) do
    opts =
      [
        # TODO: make configurable
        boundary: "mentions"
      ] ++ List.wrap(opts)

    case create(bookmarker, bookmarked, opts) do
      {:ok, bookmark} ->
        {:ok, bookmark}

      {:error, e} ->
        case get(bookmarker, bookmarked) do
          {:ok, bookmark} ->
            debug(bookmark, "the user already bookmarks this object")
            {:ok, bookmark}

          _ ->
            error(e)
            {:error, e}
        end
    end
  end

  @doc """
  Removes a bookmark from an object for a user, if one exists

  ## Examples

      iex> Bonfire.Social.Bookmarks.unbookmark(user, object)
      :ok

  """
  def unbookmark(bookmarker, object, opts \\ [])

  def unbookmark(%{} = bookmarker, %{} = bookmarked, _opts) do
    # delete the Bookmark
    Edges.delete_by_both(bookmarker, Bookmark, bookmarked)

    # delete the bookmark activity & feed entries (if any)
    result = Activities.delete_by_subject_verb_object(bookmarker, :bookmark, bookmarked)

    # Note: the bookmark count is automatically decremented by DB triggers
    {:ok, result}
  end

  def unbookmark(%{} = bookmarker, bookmarked, opts) when is_binary(bookmarked) do
    with {:ok, bookmarked} <- Bonfire.Common.Needles.get(bookmarked, current_user: bookmarker) do
      unbookmark(bookmarker, bookmarked, opts)
    end
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Bookmark, filters, opts)

    # |> proload(edge: [
    #   # subject: {"bookmarker_", [:profile, :character]},
    #   # object: {"bookmarked_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
  end

  def query([my: :bookmarks], opts),
    do: query([subjects: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp list_paginated(filters, opts) do
    query(filters, opts)
    # |> Activities.query_object_preload_activity(:bookmark, :bookmarked_id, opts)
    # |> Activities.as_permitted_for(opts, [:see])
    |> debug("qqqq")
    |> Social.many(opts[:paginate], opts)
  end

  @doc """
  Lists the current user's bookmarks.

  ## Examples

      iex> Bonfire.Social.Bookmarks.list_my(current_user: me)
      [%Bonfire.Data.Social.Bookmark{}, ...]

  """
  def list_my(opts) do
    list_by(current_user_required!(opts), to_options(opts) ++ [preload: :object_with_creator])
  end

  @doc """
  Lists bookmarks by a specific user.

  ## Examples

      iex> Bonfire.Social.Bookmarks.list_by(user_id, current_user: me)
      [%Bonfire.Data.Social.Bookmark{}, ...]

  """
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts) |> Map.put(:subjects, by_user),
      opts ++ [preload: :object, subject_user: by_user]
    )
  end

  @doc """
  Lists bookmark(er)s of a specific object or objects.

  ## Examples

      iex> Bonfire.Social.Bookmarks.list_of(object_id)
      [%Bonfire.Data.Social.Bookmark{}, ...]

  """
  def list_of(object, opts \\ [])
      when is_binary(object) or is_list(object) or is_map(object) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts) |> Map.put(:objects, object),
      Keyword.put_new(opts, :preload, :subject)
    )
  end

  def base_query(), do: from(p in Bookmark, as: :main_object)

  defp create(bookmarker, bookmarked, opts) do
    insert(bookmarker, bookmarked, opts)
  end

  defp insert(subject, object, opts) do
    # Edges.changeset_base(Bookmark, subject, object, options)
    # |> Edges.insert(subject, object)
    Edges.changeset(Bookmark, subject, :bookmark, object, opts)
    |> debug("cssss")
    |> Edges.insert(subject, object)
  end
end
