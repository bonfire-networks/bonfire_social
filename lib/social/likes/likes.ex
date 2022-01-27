defmodule Bonfire.Social.Likes do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Like
  # alias Bonfire.Data.Social.LikeCount
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  # import Ecto.Query
  # import Bonfire.Social.Integration
  use Bonfire.Common.Utils
  use Bonfire.Repo

  def queries_module, do: Like
  def context_module, do: Like
  def federation_module, do: ["Like", {"Create", "Like"}, {"Undo", "Like"}, {"Delete", "Like"}]

  def liked?(%{}=user, object), do: not is_nil(get!(user, object, skip_boundary_check: true))

  def get(subject, object, opts \\ []), do: Edges.get(__MODULE__, subject, object, opts)
  def get!(subject, object, opts \\ []), do: Edges.get!(__MODULE__, subject, object, opts)

  def by_liker(%{}=subject), do: [subject: subject] |> query(current_user: subject) |> repo().many()
  def by_liker(%{}=subject, type), do: [subject: subject] |> query(current_user: subject) |>  by_type_q(type) |> repo().many()
  def by_liked(%{}=subject), do: [subject: subject] |> query(current_user: subject) |> repo().many()

  def like(%User{} = liker, %{} = liked) do

    liked = Objects.preload_creator(liked)
    liked_creator = Objects.object_creator(liked)

    preset_or_custom_boundary = [
      preset: "mentions", # TODO: make configurable
      to_circles: [ulid(liked_creator)],
      to_feeds: [Feeds.feed_id(:notifications, liked_creator)]
    ]

    with {:ok, like} <- create(liker, liked, preset_or_custom_boundary) do
      # debug(like)

      # make the like itself visible to both
      # Bonfire.Me.Boundaries.maybe_make_visible_for(liker, like, e(liked, :created, :creator_id, nil))

      {:ok, activity} = FeedActivities.maybe_notify_creator(liker, :like, liked) #|> debug()
      {:ok, Activities.activity_under_object(activity, like)}
    end
  end

  def like(%User{} = liker, liked) when is_binary(liked) do
    with {:ok, liked} <- Bonfire.Common.Pointers.get(liked, current_user: liker) do
      #debug(liked)
      like(liker, liked)
    end
  end

  def unlike(%User{}=liker, %{}=liked) do
    Edges.delete_by_both(liker, liked) # delete the Like
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


  defp list(filters, opts, cursor_after \\ nil, preloads \\ nil) do
    query(filters, opts)
    # |> Activities.query_object_preload_activity(:like, :liked_id, opts, preloads)
    # |> Activities.as_permitted_for(opts)
    |> Bonfire.Repo.many_paginated(before: cursor_after)
  end

  @doc "List current user's likes"
  def list_my(current_user, cursor_after \\ nil, preloads \\ nil) when is_binary(current_user) or is_map(current_user) do
    list_by(current_user, current_user, cursor_after, preloads)
  end

  @doc "List likes by the user"
  def list_by(by_user, current_user \\ nil, cursor_after \\ nil, preloads \\ nil) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do

    list([subject: by_user], current_user, cursor_after, preloads)
  end

  @doc "List likes of something"
  def list_of(id, current_user \\ nil, cursor_after \\ nil, preloads \\ nil) when is_binary(id) or is_list(id) or is_map(id) do

    list([object: id], current_user, cursor_after, preloads)
  end

  defp create(liker, liked, preset_or_custom_boundary) do
    Edges.changeset(Like, liker, :like, liked, preset_or_custom_boundary)
    |> repo().insert()
  end


  defp by_type_q(q, type) do
    q
    |> join(:inner, [l], ot in ^type, as: :liked, on: ot.id == l.liked_id)
    |> join_preload([:liked])
  end


  def ap_publish_activity("create", like) do
    like = Bonfire.Repo.preload(like, :liked)

    with {:ok, liker} <- ActivityPub.Actor.get_cached_by_local_id(like.liker_id),
         liked when not is_nil(liked) <- Bonfire.Common.Pointers.follow!(like.liked),
         object when not is_nil(liked) <- Bonfire.Federate.ActivityPub.Utils.get_object(liked) do
            ActivityPub.like(liker, object)
    end
  end

  def ap_publish_activity("delete", like) do
    like = Bonfire.Repo.preload(like, :liked)

    with {:ok, liker} <- ActivityPub.Actor.get_cached_by_local_id(like.liker_id),
         liked when not is_nil(liked) <- Bonfire.Common.Pointers.follow!(like.liked),
         object when not is_nil(liked) <- Bonfire.Federate.ActivityPub.Utils.get_object(liked) do
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
