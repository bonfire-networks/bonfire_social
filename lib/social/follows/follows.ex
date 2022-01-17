defmodule Bonfire.Social.Follows do
  alias Bonfire.Data.Social.Follow
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Activities
  alias Bonfire.Social.APActivities
  alias Bonfire.Data.Identity.User
  alias Bonfire.Social.Integration
  alias Bonfire.Social.Edges
  alias Ecto.Changeset

  import Bonfire.Boundaries.Queries
  import Bonfire.Common.Utils

  use Bonfire.Repo,
    schema: Follow,
    searchable_fields: [:id, :follower_id, :followed_id],
    sortable_fields: [:id]

  @follow_table "70110WTHE1EADER1EADER1EADE"

  def queries_module, do: Follow
  def context_module, do: Follow
  def federation_module, do: ["Follow", {"Create", "Follow"}, {"Undo", "Follow"}, {"Delete", "Follow"}]

  def following?(subject, object), do: not is_nil(get!(subject, object))

  def get(subject, object), do: [subject: subject, object: object] |> query(current_user: subject) |> repo().single()
  def get!(subject, objects) when is_list(objects), do: [subject: subject, object: objects] |> query(current_user: subject) |> repo().all()
  def get!(subject, object), do: [subject: subject, object: object] |> query(current_user: subject) |> repo().one()

  def list_follows_by_subject(user), do: query_base([subject: user], user) |> repo().many()

  # defp query_base(filters, opts) do
  #   vis = filter_invisible(current_user(opts))
  #   from(f in Follow, join: v in subquery(vis), on: f.id == v.object_id)
  #   |> proload(:edge)
  #   |> query_filter(filters)
  # end

  defp query_base(filters, opts) do
    Edges.query_parent(Follow, filters, opts)
    |> query_filter(Keyword.drop(filters, [:object, :subject]))
  end

  def query([my: :followed], opts), do: [subject: current_user(opts)] |> query(opts)

  def query([my: :followers], opts), do: [object: current_user(opts)] |> query(opts)

  def query(filters, opts) do
    query_base(filters, opts)
    |> maybe_preload(!is_list(opts) || opts[:skip_preload])
  end

  defp maybe_preload(query, _skip_preload? = true), do: query

  defp maybe_preload(query, _) do
    query
    |> proload([edge: [
      subject: {"follower_", [:profile, :character]},
      object: {"followed_", [:profile, :character]}
      ]])
  end

  def list_my_followed(opts, paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true),
    do: list_followed(current_user(opts), opts, with_profile_only)

  def list_followed(%{id: user_id} = _user, opts \\ [], paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true) when is_binary(user_id) do
    query([subject: user_id], opts)
    # |> maybe_with_followed_profile_only(with_profile_only)
    |> many(paginate?, cursor_after)
  end

  def list_my_followers(opts, paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true), do: list_followers(current_user(opts), opts, with_profile_only)

  def list_followers(%{id: user_id} = _user, opts \\ [], paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true) when is_binary(user_id) do
    query([object: user_id], opts)
    # |> maybe_with_follower_profile_only(with_profile_only)
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
    else _ ->
      Logger.error("Follows - could not follow (possibly already following?)")
      nil
    end
  end

  def unfollow(follower, %{} = followed) do
    with [_id] <- Edges.delete_by_both(follower, followed) do
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
    Edges.changeset(Follow, follower, followed, @follow_table)
    |> repo().upsert()
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
         {:ok, follow} <- follow(follower, followed) do
      ActivityPub.accept(%{
        to: [data["actor"]],
        actor: object,
        object: data,
        local: true
      })
      {:ok, follow}
    else
      Logger.warn("Follows: federated follow already exists")
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
