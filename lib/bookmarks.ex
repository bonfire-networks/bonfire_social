defmodule Bonfire.Social.Bookmarks do
  # alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Bookmark
  # alias Bonfire.Data.Social.LikeCount
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Integration
  alias Bonfire.Social.Objects

  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  # import Ecto.Query
  # import Bonfire.Social.Integration
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Bookmark
  def query_module, do: __MODULE__

  def bookmarked?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  def by_bookmarker(subject, opts \\ []) when is_map(subject) or is_binary(subject),
    do:
      (opts ++ [subject: subject])
      |> query([current_user: subject] ++ List.wrap(opts))
      |> repo().many()

  def by_bookmarked(object, opts \\ []) when is_map(object) or is_binary(object),
    do: (opts ++ [object: object]) |> query(opts) |> repo().many()

  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(%{} = object, _), do: Edges.count(:bookmark, object, skip_boundary_check: true)

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

  def unbookmark(bookmarker, object, opts \\ [])

  def unbookmark(%{} = bookmarker, %{} = bookmarked, _opts) do
    # delete the Bookmark
    Edges.delete_by_both(bookmarker, Bookmark, bookmarked)

    # delete the bookmark activity & feed entries (NOTE: does not apply since Bookmark is not a declared verb or added to Feeds)
    # Activities.delete_by_subject_verb_object(bookmarker, :bookmark, bookmarked)

    # Note: the bookmark count is automatically decremented by DB triggers
  end

  def unbookmark(%{} = bookmarker, bookmarked, opts) when is_binary(bookmarked) do
    with {:ok, bookmarked} <- Bonfire.Common.Needle.get(bookmarked, current_user: bookmarker) do
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
    do: query([subject: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp list_paginated(filters, opts) do
    query(filters, opts)
    # |> Activities.query_object_preload_activity(:bookmark, :bookmarked_id, opts)
    # |> Activities.as_permitted_for(opts, [:see])
    # |> debug()
    |> Integration.many(opts[:paginate], opts)
  end

  @doc "List the current user's bookmarks"
  def list_my(opts) do
    list_by(current_user_required!(opts), opts ++ [preload: :object_with_creator])
  end

  @doc "List bookmarks by a user"
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts) |> Map.put(:subject, by_user),
      opts ++ [preload: :object, subject_user: by_user]
    )
  end

  @doc "List bookmarkers of something(s)"
  def list_of(object, opts \\ [])
      when is_binary(object) or is_list(object) or is_map(object) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts) |> Map.put(:object, object),
      Keyword.put_new(opts, :preload, :subject)
    )
  end

  defp create(bookmarker, bookmarked, opts) do
    insert(bookmarker, bookmarked, opts)
  end

  def insert(subject, object, options) do
    Edges.changeset_base(Bookmark, subject, object, options)
    |> Edges.insert()
  end
end
