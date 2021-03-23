defmodule Bonfire.Social.Follows do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Follow
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Activities

  use Bonfire.Repo.Query,
    schema: Follow,
    searchable_fields: [:id, :follower_id, :followed_id],
    sortable_fields: [:id]

  def following?(%User{}=user, followed), do: not is_nil(get!(user, followed))
  def get(%User{}=user, followed), do: repo().single(by_both_q(user, followed))
  def get!(%User{}=user, followed), do: repo().one(by_both_q(user, followed))
  def by_follower(%User{}=user), do: repo().all(followed_by_follower_q(user))
  # def by_follower(%User{}=user), do: repo().all(by_follower_q(user))
  def by_followed(%User{}=user), do: repo().all(by_followed_q(user))
  def by_any(%User{}=user), do: repo().all(by_any_q(user))

  defp list(filters, current_user) do
    # TODO: check permissions
   build_query(filters)
  end

  def list_followed(%{id: user_id} = user, current_user \\ nil) when is_binary(user_id) do
    list([follower_id: user_id], current_user)
    |> preload_join(:followed_profile)
    |> preload_join(:followed_character)
    |> repo().all
  end

  def list_followers(%{id: user_id} = user, current_user \\ nil) when is_binary(user_id) do
    list([followed_id: user_id], current_user)
    |> preload_join(:follower_profile)
    |> preload_join(:follower_character)
    |> repo().all
  end

  def follow(%User{} = follower, %{} = followed) do
    with {:ok, follow} <- create(follower, followed) do
      # FeedActivities.publish(follower, :follow, followed)
      FeedActivities.maybe_notify_object(follower, :follow, followed)
      {:ok, follow}
    end
  end
  def follow(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object) do
      follow(user, object)
    end
  end

  def unfollow(%User{}=follower, %{}=followed) do
    delete_by_both(follower, followed)
    Activities.delete_by_subject_verb_object(follower, :follow, followed) # delete the like activity & feed entries
  end
  def unfollow(%User{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object) do
      unfollow(user, object)
    end
  end

  defp create(%{} = follower, %{} = followed) do
    changeset(follower, followed) |> repo().insert()
  end

  defp changeset(%{id: follower}, %{id: followed}) do
    Follow.changeset(%Follow{}, %{follower_id: follower, followed_id: followed})
  end

  @doc "Delete Follows where i am the follower"
  defp delete_by_follower(%User{}=me), do: do_delete(by_follower_q(me))

  @doc "Delete Follows where i am the followed"
  defp delete_by_followed(%User{}=me), do: do_delete(by_followed_q(me))

  @doc "Delete Follows where i am the follower or the followed."
  defp delete_by_any(%User{}=me), do: do_delete(by_any_q(me))

  @doc "Delete Follows where i am the follower and someone else is the followed."
  defp delete_by_both(%User{}=me, %{}=followed), do: do_delete(by_both_q(me, followed))

  defp do_delete(q), do: elem(repo().delete_all(q), 1)

  def by_follower_q(%User{id: id}) do
    from f in Follow,
      where: f.follower_id == ^id,
      select: f.id
  end

  def followed_by_follower_q(%User{id: id}) do
    from f in Follow,
      where: f.follower_id == ^id,
      select: f.followed_id
  end

  def by_followed_q(%User{id: id}) do
    from f in Follow,
      where: f.followed_id == ^id,
      select: f.id
  end

  def by_any_q(%User{id: id}) do
    from f in Follow,
      where: f.follower_id == ^id or f.followed_id == ^id,
      select: f.id
  end

  def by_both_q(%User{id: follower}, %{id: followed}), do: by_both_q(follower, followed)

  def by_both_q(follower, followed) when is_binary(follower) and is_binary(followed) do
    from f in Follow,
      where: f.follower_id == ^follower and f.followed_id == ^followed,
      select: f.id
  end

end
