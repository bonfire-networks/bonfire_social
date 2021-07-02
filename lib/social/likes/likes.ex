defmodule Bonfire.Social.Likes do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Like
  # alias Bonfire.Data.Social.LikeCount
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Social.{Activities, FeedActivities}
  # import Ecto.Query
  # import Bonfire.Me.Integration
  import Bonfire.Common.Utils
  use Bonfire.Repo.Query

  # def queries_module, do: Like
  def context_module, do: Like
  def federation_module, do: ["Like", {"Create", "Like"}, {"Undo", "Like"}, {"Delete", "Like"}]

  def liked?(%User{}=user, liked), do: not is_nil(get!(user, liked))

  def get(%User{}=user, liked), do: repo().single(by_both_q(user, liked))
  def get!(%User{}=user, liked) when is_list(liked), do: repo().all(by_both_q(user, liked))
  def get!(%User{}=user, liked), do: repo().one(by_both_q(user, liked))

  def by_liker(%User{}=user), do: repo().many(by_liker_q(user))
  def by_liker(%User{}=user, type), do: repo().many(by_liker_q(user) |> by_type_q(type))
  def by_liked(%User{}=user), do: repo().many(by_liked_q(user))
  def by_any(%User{}=user), do: repo().many(by_any_q(user))

  def like(%User{} = liker, %{} = liked) do
    with {:ok, like} <- create(liker, liked) do
      # TODO: increment the like count
      FeedActivities.maybe_notify_creator(liker, :like, liked)
      {:ok, like}
    end
  end
  def like(%User{} = liker, liked) when is_binary(liked) do
    with {:ok, liked} <- Bonfire.Common.Pointers.get(liked) do
      #IO.inspect(liked)
      like(liker, liked)
    end
  end

  def unlike(%User{}=liker, %{}=liked) do
    delete_by_both(liker, liked) # delete the Like
    Activities.delete_by_subject_verb_object(liker, :like, liked) # delete the like activity & feed entries
    # TODO: decrement the like count
  end
  def unlike(%User{} = liker, liked) when is_binary(liked) do
    with {:ok, liked} <- Bonfire.Common.Pointers.get(liked) do
      unlike(liker, liked)
    end
  end

  defp list(filters, current_user, cursor_before \\ nil, preloads \\ nil) do
    # TODO: check the like's see/read permissions for current_user?
    Like
    |> Activities.object_preload_activity(:like, :liked_id, current_user, preloads)
    |> EctoShorts.filter(filters)
    |> Activities.as_permitted_for(current_user)
    |> Bonfire.Repo.many_paginated(before: cursor_before)
  end

  @doc "List current user's likes"
  def list_my(current_user, cursor_before \\ nil, preloads \\ nil) when is_binary(current_user) or is_map(current_user) do
    list_by(current_user, current_user, cursor_before, preloads)
  end

  @doc "List likes by the user"
  def list_by(by_user, current_user \\ nil, cursor_before \\ nil, preloads \\ nil) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do

    list([likes_by: {ulid(by_user), &filter/3}], current_user, cursor_before, preloads)
  end

  @doc "List likes of something"
  def list_of(id, current_user \\ nil, cursor_before \\ nil, preloads \\ nil) when is_binary(id) or is_list(id) or is_map(id) do

    list([likes_of: {ulid(id), &filter/3}], current_user, cursor_before, preloads)
  end

  defp create(%{} = liker, %{} = liked) do
    changeset(liker, liked) |> repo().insert()
  end

  defp changeset(%{id: liker}, %{id: liked}) do
    Like.changeset(%Like{}, %{liker_id: liker, liked_id: liked})
  end

  #doc "Delete likes where i am the liker"
  defp delete_by_liker(%User{}=me), do: elem(repo().delete_all(by_liker_q(me)), 1)

  #doc "Delete likes where i am the liked"
  defp delete_by_liked(%User{}=me), do: elem(repo().delete_all(by_liked_q(me)), 1)

  #doc "Delete likes where i am the liker or the liked."
  defp delete_by_any(%User{}=me), do: elem(repo().delete_all(by_any_q(me)), 1)

  #doc "Delete likes where i am the liker and someone else is the liked."
  defp delete_by_both(%User{}=me, %{}=liked), do: elem(repo().delete_all(by_both_q(me, liked)), 1)

  defp by_liker_q(%User{id: id}) do
    from f in Like,
      where: f.liker_id == ^id
  end

  defp by_liked_q(%User{id: id}) do
    from f in Like,
      where: f.liked_id == ^id
  end

  defp by_any_q(%User{id: id}) do
    from f in Like,
      where: f.liker_id == ^id or f.liked_id == ^id
  end

  defp by_both_q(liker, liked) when is_list(liked) do
    from f in Like,
      where: f.liker_id == ^ulid(liker) or f.liked_id in ^ulid(liked),
      select: {f.liked_id, f}
  end
  defp by_both_q(liker, liked) do
    from f in Like,
      where: f.liker_id == ^ulid(liker) or f.liked_id == ^ulid(liked)
  end

  defp by_type_q(q, type) do
    q
    |> join(:inner, [l], ot in ^type, as: :liked, on: ot.id == l.liked_id)
    |> join_preload([:liked])
  end

  #doc "List likes created by the user and which are in their outbox, which are not replies"
  def filter(:likes_by, user_id, query) do
    verb_id = Verbs.verbs()[:like]

      query
      |> join_preload([:activity, :subject_character])
      |> where(
        [activity: activity, subject_character: liker],
        activity.verb_id==^verb_id and liker.id == ^ulid(user_id)
      )

  end

  #doc "List likes created by the user and which are in their outbox, which are not replies"
  def filter(:likes_of, id, query) do
    verb_id = Verbs.verbs()[:like]

      query
      |> join_preload([:activity])
      |> where(
        [activity: activity],
        activity.verb_id==^verb_id and activity.object_id == ^ulid(id)
      )

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

  def ap_receive_activity(creator, activity, object) do
    with {:ok, pointer} <- Bonfire.Common.Pointers.one(object.pointer_id),
         liked = Bonfire.Common.Pointers.follow!(pointer) do
           like(creator, liked)
    end
  end
end
