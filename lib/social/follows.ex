defmodule Bonfire.Social.Follows do
  alias Bonfire.Data.Social.Follow
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Activities
  alias Bonfire.Social.APActivities
  import Bonfire.Common.Utils

  use Bonfire.Repo.Query,
    schema: Follow,
    searchable_fields: [:id, :follower_id, :followed_id],
    sortable_fields: [:id]

  def following?(user, followed), do: not is_nil(get!(user, followed))
  def get(user, followed), do: repo().single(by_both_q(user, followed))
  def get!(user, followed), do: repo().one(by_both_q(user, followed))
  def by_follower(user), do: repo().all(followed_by_follower_q(user))
  # def by_follower(user), do: repo().all(by_follower_q(user))
  def by_followed(user), do: repo().all(by_followed_q(user))
  def by_any(user), do: repo().all(by_any_q(user))

  defp list(filters, _current_user) do
    # TODO: check permissions for current_user
    build_query(filters)
  end

  def list_my_followed(current_user, with_profile_only \\ true), do: list_followed(current_user, current_user, with_profile_only)

  def list_followed(%{id: user_id} = _user, current_user \\ nil, with_profile_only \\ true) when is_binary(user_id) do
    list([follower_id: user_id], current_user)
    |> join_preload([:followed_profile])
    |> join_preload([:followed_character])
    |> maybe_with_followed_profile_only(with_profile_only)
    |> repo().all
  end

  def list_my_followers(current_user, with_profile_only \\ true), do: list_followers(current_user, current_user, with_profile_only)

  def list_followers(%{id: user_id} = _user, current_user \\ nil, with_profile_only \\ true) when is_binary(user_id) do
    list([followed_id: user_id], current_user)
    |> join_preload([:follower_profile])
    |> join_preload([:follower_character])
    |> maybe_with_follower_profile_only(with_profile_only)
    |> repo().all
  end

  defp maybe_with_follower_profile_only(q, true), do: q |> where([follower_profile: p], not is_nil(p.id))
  defp maybe_with_follower_profile_only(q, _), do: q
  defp maybe_with_followed_profile_only(q, true), do: q |> where([followed_profile: p], not is_nil(p.id))
  defp maybe_with_followed_profile_only(q, _), do: q

  def follow(%{} = follower, %{} = followed) do
    with {:ok, follow} <- create(follower, followed) do
      # FeedActivities.publish(follower, :follow, followed)
      FeedActivities.maybe_notify_object(follower, :follow, followed)
      APActivities.publish(follower, "create", follow)

      {:ok, follow}
    end
  end

  def follow(user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object) do
      follow(user, object)
    end
  end

  def unfollow(follower, %{} = followed) do
    [id] = delete_by_both(follower, followed)
    # FIXME: this might not publish properly due to the follow being deleted while ap publish is in queue
    APActivities.publish(follower, "delete", id)
    # delete the like activity & feed entries
    Activities.delete_by_subject_verb_object(follower, :follow, followed)
  end

  def unfollow(%{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object) do
      unfollow(user, object)
    end
  end

  defp create(follower, followed) do
    changeset(follower, followed) |> repo().insert()
  end

  defp changeset(follower, followed) do
    Follow.changeset(%Follow{}, %{follower_id: ulid(follower), followed_id: ulid(followed)})
  end

  #doc "Delete Follows where i am the follower"
  defp delete_by_follower(me), do: do_delete(by_follower_q(me))

  #doc "Delete Follows where i am the followed"
  defp delete_by_followed(me), do: do_delete(by_followed_q(me))

  #doc "Delete Follows where i am the follower or the followed."
  defp delete_by_any(me), do: do_delete(by_any_q(me))

  #doc "Delete Follows where i am the follower and someone else is the followed."
  defp delete_by_both(me, followed), do: do_delete(by_both_q(me, followed))

  defp do_delete(q), do: elem(repo().delete_all(q), 1)

  defp by_follower_q(id) do
    from f in Follow,
      where: f.follower_id == ^ulid(id),
      select: f.id
  end

  defp followed_by_follower_q(id) do
    from f in Follow,
      where: f.follower_id == ^ulid(id),
      select: f.followed_id
  end

  defp by_followed_q(id) do
    from f in Follow,
      where: f.followed_id == ^ulid(id),
      select: f.id
  end

  defp by_any_q(id) do
    from f in Follow,
      where: f.follower_id == ^ulid(id) or f.followed_id == ^ulid(id),
      select: f.id
  end

  defp by_both_q(follower, followed) do
    from f in Follow,
      where: f.follower_id == ^ulid(follower) and f.followed_id == ^ulid(followed),
      select: f.id
  end

  ###

  def ap_publish_activity("create", follow) do
    with {:ok, follower} <- ActivityPub.Adapter.get_actor_by_id(follow.follower_id),
         {:ok, followed} <- ActivityPub.Adapter.get_actor_by_id(follow.followed_id) do
      ActivityPub.follow(follower, followed, nil, true)
    end
  end

  def ap_publish_activity("delete", follow) do
    with {:ok, follower} <- ActivityPub.Adapter.get_actor_by_id(follow.follower_id),
         {:ok, followed} <- ActivityPub.Adapter.get_actor_by_id(follow.followed_id) do
      ActivityPub.unfollow(follower, followed, nil, true)
    end
  end

  def ap_receive_activity(activity, object) do
    with {:ok, follower} <- Bonfire.Me.Users.ActivityPub.by_ap_id(activity.data["actor"]),
         {:ok, followed} <- Bonfire.Me.Users.ActivityPub.by_username(object.username),
         {:ok, _} <- follow(follower, followed) do
      ActivityPub.accept(%{
        to: [activity.data["actor"]],
        actor: object,
        object: activity.data,
        local: true
      })
    end
  end
end
