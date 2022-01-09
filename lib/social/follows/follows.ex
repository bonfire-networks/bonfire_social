defmodule Bonfire.Social.Follows do
  alias Bonfire.Data.Social.Follow
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Activities
  alias Bonfire.Social.APActivities
  alias Bonfire.Data.Identity.User
  alias Bonfire.Social.Integration
  import Bonfire.Boundaries.Queries
  import Bonfire.Common.Utils

  use Bonfire.Repo,
    schema: Follow,
    searchable_fields: [:id, :follower_id, :followed_id],
    sortable_fields: [:id]

  def queries_module, do: Follow
  def context_module, do: Follow
  def federation_module, do: ["Follow", {"Create", "Follow"}, {"Undo", "Follow"}, {"Delete", "Follow"}]

  def following?(user, followed), do: not is_nil(get!(user, followed))

  def get(user, followed), do: [follower: user, followed: followed] |> query(current_user: user) |> repo().single()
  def get!(%{}=user, followed) when is_list(followed), do: [follower: user, followed: followed] |> query(current_user: user) |> repo().all()
  def get!(user, followed), do: [follower: user, followed: followed] |> query(current_user: user) |> repo().one()

  def by_follower(user), do: query([follower: user], user) |> repo().many()
  # def by_follower(user), do: repo().many(by_follower_q(user))
  def by_followed(user), do: query([follower: user], user) |> repo().many()

  # def follower_by_followed(user), do: query([follower: user], user) |> repo().many(follower_by_followed_q(user))

  # def by_any(user), do: repo().many(by_any_q(user))

  defp query_base(filters, opts) do
    vis = filter_invisible(current_user(opts))
    from(f in Follow, join: v in subquery(vis), on: f.id == v.object_id)
    |> proload(:edge)
    |> query_filter(filters)
  end

  def query([my: :followed], opts) do
    [followed: current_user(opts)] |> query(opts)
  end

  def query([my: :followers], opts) do
    [followers: current_user(opts)] |> query(opts)
  end

  def query([follower: follower, followed: followed], opts) when not is_list(follower), do: [follower: [follower], followed: followed] |> query(opts)

  def query([follower: follower, followed: followed], opts) when not is_list(followed), do: [follower: follower, followed: [followed]] |> query(opts)

  def query([follower: follower, followed: followed], opts) when is_list(follower) and is_list(followed) do
    query_base([], opts)
    |> proload(edge: [subject: {"follower_", [:profile, :character]}])
    |> where([edge: edge],
      edge.subject_id in ^ulid(followed)
      and edge.object_id in ^ulid(follower)
    )
  end

  def query([followers: user], opts), do: query([follower: user], opts)
  def query([follower: user], opts) do
    user = ulid(user)
    query_base([], opts)
    |> proload(edge: [subject: {"follower_", [:profile, :character]}])
    |> where([edge: edge], edge.object_id == ^user)
  end

  def query([followed: user], opts) do
    user = ulid(user)
    query_base([], opts)
    |> proload(edge: [object: {"followed_", [:profile, :character]}])
    |> where([edge: edge], edge.subject_id == ^user)
  end

  def query(filters, opts) do
    query_base(filters, opts)
  end

  def list_my_followed(current_user, paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true),
    do: list_followed(current_user, current_user, with_profile_only)

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
    if is_ulid?(object) do
      with {:ok, object} <- Bonfire.Common.Pointers.get(object, skip_boundary_check: true, current_user: subject) do
        do_follow(subject, object)
      end
    else
      # try by username
      with {:ok, object} <- maybe_apply(Bonfire.Me.Characters, :by_username, object) do
        do_follow(subject, object)
      end
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

      {:ok, activity} = FeedActivities.notify_object(follower, :follow, followed)

      with_activity = Activities.activity_under_object(activity, follow) #|> IO.inspect()
      {:ok, with_activity}
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
  defp delete_by_follower(user), do: query([follower: user], skip_boundary_check: true) |> do_delete()

  #doc "Delete Follows where i am the followed"
  defp delete_by_followed(user), do: query([followed: user], skip_boundary_check: true) |> do_delete()

  #doc "Delete Follows where i am the follower or the followed."
  # defp delete_by_any(me), do: do_delete(by_any_q(me))

  #doc "Delete Follows where i am the follower and someone else is the followed."
  defp delete_by_both(me, followed), do: query([follower: me, followed: followed], skip_boundary_check: true) |> do_delete()

  defp do_delete(q), do: elem(repo().delete_all(q), 1)


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
