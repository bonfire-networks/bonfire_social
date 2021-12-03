defmodule Bonfire.Social.Follows do
  alias Bonfire.Data.Social.Follow
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Activities
  alias Bonfire.Social.APActivities
  alias Bonfire.Data.Identity.User
  alias Bonfire.Social.Integration
  import Bonfire.Common.Utils

  use Bonfire.Repo.Query,
    schema: Follow,
    searchable_fields: [:id, :follower_id, :followed_id],
    sortable_fields: [:id]

  def queries_module, do: Follow
  def context_module, do: Follow
  def federation_module, do: ["Follow", {"Create", "Follow"}, {"Undo", "Follow"}, {"Delete", "Follow"}]

  def following?(user, followed), do: not is_nil(get!(user, followed))

  def get(user, followed), do: repo().single(by_both_q(user, followed))
  def get!(%{}=user, followed) when is_list(followed), do: repo().all(by_both_q(user, followed))
  def get!(user, followed), do: repo().one(by_both_q(user, followed))

  def by_follower(user), do: repo().many(followed_by_follower_q(user))
  # def by_follower(user), do: repo().many(by_follower_q(user))
  def by_followed(user), do: repo().many(by_followed_q(user))

  def follower_by_followed(user), do: repo().many(follower_by_followed_q(user))

  def by_any(user), do: repo().many(by_any_q(user))

  defp query_base(filters, _current_user) do
    # TODO: check see/read permissions for current_user
    Follow
    |> EctoShorts.filter(filters)
    |> IO.inspect(label: "Follows: query_base")
  end

  def query([my: :followed], opts) do
    current_user = current_user(opts)
    query([followed: current_user], opts)
  end

  def query([my: :followers], opts) do
    current_user = current_user(opts)
    query([followers: current_user], opts)
  end

  def query([followers: user], opts) do
    query_base([followed_id: ulid(user)], opts)
    |> join_preload([:follower_profile])
    |> join_preload([:follower_character])
  end

  def query([followed: user], opts) do
    query_base([follower_id: ulid(user)], opts)
    |> join_preload([:followed_profile])
    |> join_preload([:followed_character])
  end

  def query(filter, opts) do
    query_base(filter, opts)
  end


  def list_my_followed(current_user, paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true), do: list_followed(current_user, current_user, with_profile_only)

  def list_followed(%{id: user_id} = _user, current_user \\ nil, paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true) when is_binary(user_id) do
    query([followed: user_id], current_user)
    |> maybe_with_followed_profile_only(with_profile_only)
    |> many(paginate?, cursor_after)
  end

  def list_my_followers(current_user, paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true), do: list_followers(current_user, current_user, with_profile_only)

  def list_followers(%{id: user_id} = _user, current_user \\ nil, paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true) when is_binary(user_id) do
    query([followers: user_id], current_user)
    |> maybe_with_follower_profile_only(with_profile_only)
    |> many(paginate?, cursor_after)
  end

  defp many(query, paginate?, cursor_after \\ nil)

  defp many(query, true, cursor_after) do
    query
    |> Bonfire.Repo.many_paginated(before: cursor_after)
  end

  defp many(query, _, _) do
    query
    |> repo().many
  end

  defp maybe_with_follower_profile_only(q, true), do: q |> where([follower_profile: p], not is_nil(p.id))
  defp maybe_with_follower_profile_only(q, _), do: q
  defp maybe_with_followed_profile_only(q, true), do: q |> where([followed_profile: p], not is_nil(p.id))
  defp maybe_with_followed_profile_only(q, _), do: q

  @doc """
  Follow someone/something, and federate it
  """
  def follow(follower, followed) do
    do_follow(follower, followed)
  end

  defp do_follow(subject, object) when is_binary(object) do
    # TODO: once we expose boundaries for profile visibility and follow-ability, enforce that here
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, skip_boundary_check: true, current_user: subject) do
      do_follow(subject, object)
    end
  end

  defp do_follow(subject, object) when is_binary(subject) do
    with {:ok, subject} <- Bonfire.Common.Pointers.get(subject, skip_boundary_check: true) do
      do_follow(subject, object)
    end
  end

  defp do_follow(%{} = follower, %{} = followed) do
    with {:ok, follow} <- create(follower, followed) do

      # FeedActivities.publish(follower, :follow, followed) # TODO: make configurable where the follow gets published

      # TEMPORARY: make my profile visible to people I follow
      Bonfire.Me.Users.Boundaries.maybe_make_visible_for(follower, follower, followed)
      # TEMPORARY: make sure the profile of someone I follow is visible to me
      Bonfire.Me.Users.Boundaries.maybe_make_visible_for(followed, followed, follower)

      # make the follow itself visible to both
      Bonfire.Me.Users.Boundaries.maybe_make_visible_for(follower, follow, followed)

      FeedActivities.notify_object(follower, :follow, followed)

      # Logger.warn("Follow: followed")
      {:ok, follow}
    end
  end

  def unfollow(follower, %{} = followed) do
    with [id] <- delete_by_both(follower, followed) do
      # delete the like activity & feed entries
    Activities.delete_by_subject_verb_object(follower, :follow, followed)
    end
  end

  def unfollow(%{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, current_user: user) do
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

  defp follower_by_followed_q(id) do
    from f in Follow,
      where: f.followed_id == ^ulid(id),
      select: f.follower_id
  end

  defp by_any_q(id) do
    from f in Follow,
      where: f.follower_id == ^ulid(id) or f.followed_id == ^ulid(id),
      select: f.id
  end

  defp by_both_q(follower, followed) when is_list(followed) do
    from f in Follow,
      where: f.follower_id == ^ulid(follower) or f.followed_id in ^ulid(followed),
      select: {f.followed_id, f}
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

  def ap_receive_activity(follower, %{data: %{"type" => "Follow"} = data} = _activity, %{pointer_id: followed} = object) when is_binary(follower) or is_struct(follower) do
    Logger.warn("Follows: recording an incoming follow")
    with {:error, _} <- get(follower, followed), # check if not already followed
         {:ok, follow} <- do_follow(follower, followed) do
      ActivityPub.accept(%{
        to: [data["actor"]],
        actor: object,
        object: data,
        local: true
      })
      {:ok, follow}
    else
      # reaffirm that the follow has gone through
      {:ok, _} ->
        ActivityPub.accept(%{
          to: [data["actor"]],
          actor: object,
          object: data,
          local: true
        })

      e -> e
    end
  end

  def ap_receive_activity(follower, %{data: %{"type" => "Undo"} = _data} = _activity, %{data: %{"object" => followed_ap_id}} = _object) do
    with {:ok, followed} <- Bonfire.Federate.ActivityPub.Utils.get_character_by_ap_id(followed_ap_id),
         [id] <- unfollow(follower, followed) do
          {:ok, id}
    end
  end
end
