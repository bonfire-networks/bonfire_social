defmodule Bonfire.Social.Likes do
  @moduledoc """
  Mutate, query, and federate likes (indicating appreciation for an activity or object).

  This module provides functionality to manage and query likes, including creating, deleting, and listing likes.
  It also handles federation of likes using ActivityPub.

  Likes are implemented on top of the `Bonfire.Data.Edges.Edge` schema (see `Bonfire.Social.Edges` for shared functions)
  """

  # alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Like
  # alias Bonfire.Data.Social.LikeCount
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social
  alias Bonfire.Social.Objects

  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  # import Ecto.Query
  # import Bonfire.Social
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Like
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: ["Like", {"Create", "Like"}, {"Undo", "Like"}, {"Delete", "Like"}]

  @doc """
  Checks if a user has liked an object.

  ## Parameters

    - user: The user to check.
    - object: The object to check for likes.

  ## Examples

      iex> Bonfire.Social.Likes.liked?(%User{id: "user123"}, %Post{id: "post456"})
      true
  """
  def liked?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  @doc """
  Retrieves a Like edge between a subject and an object.

  ## Parameters

    - subject: The subject (usually a user) of the Like edge.
    - object: The object that was liked.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Likes.get(%User{id: "user123"}, %Post{id: "post456"})
      {:ok, %Like{}}

  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  @doc """
    Similar to `get/3`, but raises an error if the Like edge is not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  @doc """
  Lists likes created by a specific subject.

  ## Parameters

    - subject: The subject (usually a user) who created the likes.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Likes.by_liker(%User{id: "user123"})
      [%Like{}, ...]

  """
  def by_liker(subject, opts \\ []) when is_map(subject) or is_binary(subject),
    do:
      (opts ++ [subject: subject])
      |> query([current_user: subject] ++ List.wrap(opts))
      |> repo().many()

  @doc """
  Lists likes for a specific object.

  ## Parameters

    - object: The object that was liked.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Likes.by_liked(%Post{id: "post456"})
      [%Like{}, ...]

  """
  def by_liked(object, opts \\ []) when is_map(object) or is_binary(object),
    do: (opts ++ [object: object]) |> query(opts) |> repo().many()

  @doc """
  Counts likes based on filters or for a specific user-object pair.

  ## Parameters

    - filters: A list of filters to apply when counting likes.
    - opts: Additional options for the query.

  ## Examples

      iex> Bonfire.Social.Likes.count([object: %Post{id: "post456"}])
      5

      iex> Bonfire.Social.Likes.count(%User{id: "user123"}, %Post{id: "post456"})
      1

  """
  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(%{} = object, _), do: Edges.count(:like, object, skip_boundary_check: true)

  @doc """
  Records a like for an object.

  ## Parameters

    - liker: The user creating the like.
    - object: The object to be liked.
    - opts: Additional options for creating the like (optional).

  ## Examples

      iex> Bonfire.Social.Likes.like(%User{id: "user123"}, %Post{id: "post456"})
      {:ok, %Like{}}

  """
  def like(liker, object, opts \\ [])

  def like(%{} = liker, %{} = object, opts) do
    if Bonfire.Boundaries.can?(liker, :like, object) do
      do_like(liker, object, opts)
    else
      error(l("Sorry, you cannot react to this"))
    end
  end

  def like(%{} = liker, liked, opts) when is_binary(liked) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(
             liked,
             opts ++
               [
                 current_user: liker,
                 verbs: [:like]
               ]
           ) do
      # debug(liked)
      do_like(liker, object, opts)
    else
      _ ->
        error(l("Sorry, you cannot react to this"))
    end
  end

  def do_like(%{} = liker, %{} = liked, opts \\ []) do
    liked = Objects.preload_creator(liked)
    liked_object_creator = Objects.object_creator(liked)

    opts =
      [
        # TODO: make configurable
        boundary: "mentions",
        to_circles: [id(liked_object_creator)],
        to_feeds: Feeds.maybe_creator_notification(liker, liked_object_creator, opts)
      ] ++ List.wrap(opts)

    case create(liker, liked, opts) do
      {:ok, like} ->
        Social.maybe_federate_and_gift_wrap_activity(liker, like)

      {:error, e} ->
        case get(liker, liked) do
          {:ok, like} ->
            debug(like, "the user already likes this object")
            {:ok, like}

          _ ->
            error(e)
            {:error, e}
        end
    end
  end

  @doc """
  Removes a like for an object.

  ## Parameters

    - liker: The user removing the like.
    - object: The object to be unliked.
    - opts: Additional options (optional).

  ## Examples

      iex> Bonfire.Social.Likes.unlike(%User{id: "user123"}, %Post{id: "post456"})
      {:ok, nil}

  """
  def unlike(liker, object, opts \\ [])

  def unlike(%{} = liker, %{} = liked, _opts) do
    # delete the Like
    Edges.delete_by_both(liker, Like, liked)
    # delete the like activity & feed entries
    Activities.delete_by_subject_verb_object(liker, :like, liked)

    # Note: the like count is automatically decremented by DB triggers
  end

  def unlike(%{} = liker, liked, opts) when is_binary(liked) do
    with {:ok, liked} <- Bonfire.Common.Needles.get(liked, opts ++ [current_user: liker]) do
      unlike(liker, liked, opts)
    end
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Like, filters, opts)

    # |> proload(edge: [
    #   # subject: {"liker_", [:profile, :character]},
    #   # object: {"liked_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
  end

  @doc """
  Creates a query for Like edges based on the given filters and options.

  ## Parameters

    - filters: A keyword list of filters to apply to the query.
    - opts: Additional options for the query.

  ## Examples

      iex> filters = [subject: %User{id: "user123"}]
      iex> opts = [limit: 10]
      iex> Bonfire.Social.Likes.query(filters, opts)
      #Ecto.Query<...>

  """
  def query([my: :likes], opts),
    do: query([subject: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  # FIXME: This was defp
  def list_paginated(filters, opts) do
    query(filters, opts)
    # |> Activities.query_object_preload_activity(:like, :liked_id, opts)
    # |> Activities.as_permitted_for(opts, [:see])
    # |> debug()
    |> Social.many(opts[:paginate?], opts)

    # |> Activities.activity_preloads(opts)
  end

  @doc """
  List the current user's likes.

  ## Parameters

    - opts: Additional options for the query.

  ## Examples

      iex> Bonfire.Social.Likes.list_my(current_user: %User{id: "user123"})
      %{edges: [%Like{}, ...], page_info: %{}}

  """
  def list_my(opts) do
    opts = to_options(opts)
    list_by(current_user_required!(opts), Keyword.put(opts, :preload, :object_with_creator))
  end

  @doc """
  Lists likes created by a specific user.

  ## Parameters

    - by_user: The user whose likes to list.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Likes.list_by(%User{id: "user123"})
      %{edges: [%Like{}, ...], page_info: %{}}

  """
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts)
      |> Map.put(:subject, by_user),
      opts
      |> Keyword.put_new(:preload, :object)
      |> Keyword.put(:subject_user, :by_user)
    )
  end

  @doc """
  Lists likers of a specific object or objects.

  ## Parameters

    - object: The object or objects to find likers for.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Likes.list_of(%Post{id: "post456"})
      %{edges: [%Like{}, ...], page_info: %{}}

  """
  def list_of(object, opts \\ [])
      when is_binary(object) or is_list(object) or is_map(object) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts) |> Map.put(:object, object),
      Keyword.put_new(opts, :preload, :subject)
    )
  end

  defp create(subject, object, opts) do
    do_create(subject, object, opts[:reaction_emoji], opts[:reaction_media], opts)
  end

  # defp do_create(subject, object, emoji, _, opts) when is_binary(emoji) do
  #   # TODO: emoji_id = get_or_create(emoji)
  #   Edges.changeset({Like, emoji_id}, subject, :like, object, opts)
  #   |> debug("cssss")
  #   |> Edges.insert(subject, object)
  # end

  defp do_create(subject, object, _, media_id, opts) when is_binary(media_id) do
    Edges.insert({Like, media_id}, subject, :like, object, opts)
  end

  defp do_create(subject, object, _, _, opts) do
    Edges.insert(Like, subject, :like, object, opts)
  end

  @doc """
  Publishes an ActivityPub activity for a like.

  ## Parameters

    - subject: The subject of the like activity.
    - verb: The verb of the activity (:delete or other).
    - like: The like object.

  ## Examples

      iex> Bonfire.Social.Likes.ap_publish_activity(%User{id: "user123"}, :create, %Like{})
      {:ok, %ActivityPub.Object{}}

  """
  def ap_publish_activity(subject, :delete, like) do
    with {:ok, liker} <-
           ActivityPub.Actor.get_cached(pointer: subject || like.edge.subject_id),
         {:ok, object} <-
           ActivityPub.Object.get_cached(
             pointer: e(like.edge, :object, nil) || like.edge.object_id
           ) do
      ActivityPub.unlike(%{actor: liker, object: object})
    else
      {:error, :not_found} ->
        :ignore

      e ->
        error(e)
    end
  end

  def ap_publish_activity(subject, _verb, like) do
    like = repo().maybe_preload(like, :edge)

    with {:ok, liker} <-
           ActivityPub.Actor.get_cached(pointer: subject || like.edge.subject_id),
         {:ok, object} <-
           ActivityPub.Object.get_cached(
             pointer: e(like.edge, :object, nil) || like.edge.object_id
           ) do
      ActivityPub.like(%{actor: liker, object: object, pointer: ulid(like)})
    else
      {:error, :not_found} ->
        :ignore

      e ->
        error(e)
    end
  end

  @doc """
  Receives and processes an ActivityPub like activity.

  ## Parameters

    - liker: The user performing the like action.
    - activity: The ActivityPub activity data.
    - object: The object being liked.

  ## Examples

      iex> activity = %{data: %{"type" => "Like"}}
      iex> object = %ActivityPub.Object{}
      iex> Bonfire.Social.Likes.ap_receive_activity(%User{id: "user123"}, activity, object)
      {:ok, %Like{}}

  """
  def ap_receive_activity(
        liker,
        %{data: %{"type" => "Like"}} = _activity,
        object
      ) do
    Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(object,
      current_user: liker,
      verbs: [:like]
    )
    ~> like(liker, ..., local: false)
  end

  def ap_receive_activity(
        liker,
        %{data: %{"type" => "Undo"}} = _activity,
        %{data: %{"object" => liked_object}} = _object
      ) do
    with {:ok, object} <-
           ActivityPub.Object.get_cached(ap_id: liked_object),
         {:ok, pointable} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(object,
             current_user: liker,
             verbs: [:like]
           ),
         [id] <- unlike(liker, pointable, skip_boundary_check: true) do
      {:ok, id}
    end
  end
end
