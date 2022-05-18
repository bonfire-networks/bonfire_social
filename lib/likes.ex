defmodule Bonfire.Social.Likes do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Like
  # alias Bonfire.Data.Social.LikeCount
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Social.{Activities, Edges, Feeds, FeedActivities, Integration, Objects}
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  # import Ecto.Query
  # import Bonfire.Social.Integration
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  def queries_module, do: Like
  def context_module, do: Like
  def federation_module, do: ["Like", {"Create", "Like"}, {"Undo", "Like"}, {"Delete", "Like"}]

  def liked?(%{}=user, object), do: not is_nil(get!(user, object, skip_boundary_check: true))

  def get(subject, object, opts \\ []), do: Edges.get(__MODULE__, subject, object, opts)
  def get!(subject, object, opts \\ []), do: Edges.get!(__MODULE__, subject, object, opts)

  def by_liker(%{}=subject), do: [subject: subject] |> query(current_user: subject) |> repo().many()
  # def by_liker(%{}=subject, type), do: [subject: subject] |> query(current_user: subject) |>  by_type_q(type) |> repo().many()
  def by_liked(%{}=subject), do: [subject: subject] |> query(current_user: subject) |> repo().many()

  def like(%User{} = liker, %{} = liked) do
    liked = Objects.preload_creator(liked)
    liked_creator = Objects.object_creator(liked)
    opts = [
      boundary: "mentions", # TODO: make configurable
      to_circles: [ulid(liked_creator)],
      to_feeds: Feeds.maybe_creator_notification(liker, liked_creator),
    ]
    case create(liker, liked, opts) do
      {:ok, like} ->
        Integration.ap_push_activity(liker.id, like)
        {:ok, like}
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

  def like(%User{} = liker, liked) when is_binary(liked) do
    with {:ok, liked} <- Bonfire.Common.Pointers.get(liked, current_user: liker) do
      #debug(liked)
      like(liker, liked)
    end
  end

  def unlike(%User{}=liker, %{}=liked) do
    Edges.delete_by_both(liker, Like, liked) # delete the Like
    Activities.delete_by_subject_verb_object(liker, :like, liked) # delete the like activity & feed entries
    # Note: the like count is automatically decremented by DB triggers
  end

  def unlike(%User{} = liker, liked) when is_binary(liked) do
    with {:ok, liked} <- Bonfire.Common.Pointers.get(liked, current_user: liker) do
      unlike(liker, liked)
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

  def query([my: :likes], opts), do: [subject: current_user(opts)] |> query(opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp list_paginated(filters, opts \\ []) do
    query(filters, opts)
    # |> Activities.query_object_preload_activity(:like, :liked_id, opts)
    # |> Activities.as_permitted_for(opts, [:see])
    # |> debug()
    |> Bonfire.Common.Repo.many_paginated(opts)
  end

  @doc "List the current user's likes"
  def list_my(opts) when is_list(opts) do
    list_by(current_user(opts), opts)
  end

  @doc "List likes by a user"
  def list_by(by_user, opts \\ []) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    opts = to_options(opts)
    list_paginated([subject: by_user], opts ++ [preload: :object])
  end

  @doc "List likers of something(s)"
  def list_of(object, opts \\ []) when is_binary(object) or is_list(object) or is_map(object) do
    opts = to_options(opts)
    list_paginated([object: object], opts ++ [preload: :subject])
  end

  defp create(liker, liked, opts) do
    Edges.changeset(Like, liker, :like, liked, opts)
    |> repo().insert()
    # |> repo().maybe_preload(edge: [:object])
  end

  # defp by_type_q(q, type) do
  #   q
  #   |> join(:inner, [l], ot in ^type, as: :liked, on: ot.id == l.liked_id)
  #   |> join_preload([:liked])
  # end

  def ap_publish_activity("create", like) do
    info(like)
    with {:ok, liker} <- ActivityPub.Actor.get_cached_by_local_id(like.edge.subject_id),
         object when not is_nil(object) <- Bonfire.Federate.ActivityPub.Utils.get_object(like.edge.object) do
            ActivityPub.like(liker, object)
    end
  end

  def ap_publish_activity("delete", like) do
    with {:ok, liker} <- ActivityPub.Actor.get_cached_by_local_id(like.edge.subject_id),
         object when not is_nil(object) <- Bonfire.Federate.ActivityPub.Utils.get_object(like.edge.object) do
            ActivityPub.unlike(liker, object)
    end
  end

  def ap_receive_activity(creator, %{data: %{"type" => "Like"}} = _activity, object) do
    with {:ok, liked} <- Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator) do
           like(creator, liked)
    end
  end

  def ap_receive_activity(creator, %{data: %{"type" => "Undo"}} = _activity, %{data: %{"object" => liked_object}} = _object) do
    with object when not is_nil(object) <- ActivityPub.Object.get_cached_by_ap_id(liked_object),
         {:ok, liked} <- Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator),
         [id] <- unlike(creator, liked) do
          {:ok, id}
    end
  end
end