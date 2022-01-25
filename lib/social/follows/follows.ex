defmodule Bonfire.Social.Follows do

  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo,
    schema: Follow,
    searchable_fields: [:id, :follower_id, :followed_id],
    sortable_fields: [:id]
  import Bonfire.Boundaries.Queries

  alias Bonfire.Data.Social.Follow
  alias Bonfire.Me.{Boundaries, Characters, Users}
  alias Bonfire.Social.{Activities, APActivities, Edges, FeedActivities, Feeds, Integration}
  alias Bonfire.Data.Identity.User
  alias Ecto.Changeset

  def queries_module, do: Follow
  def context_module, do: Follow
  def federation_module, do: ["Follow", {"Create", "Follow"}, {"Undo", "Follow"}, {"Delete", "Follow"}]

  def following?(subject, object), do: not is_nil(get!(subject, object, skip_boundary_check: true))

  def get(subject, object, opts \\ []), do: Edges.get(__MODULE__, subject, object, opts)
  def get!(subject, object, opts \\ []), do: Edges.get!(__MODULE__, subject, object, opts)

  def list_follows_by_subject(user, opts \\ []) do
    opts
    |> Keyword.put_new(:current_user, user)
    |> query_base([subject: user], ...)
    |> repo().many()
  end

  # defp query_base(filters, opts) do
  #   vis = filter_invisible(current_user(opts))
  #   from(f in Follow, join: v in subquery(vis), on: f.id == v.object_id)
  #   |> proload(:edge)
  #   |> query_filter(filters)
  # end

  defp query_base(filters, opts) do
    Edges.query_parent(Follow, filters, opts)
    |> query_filter(Keyword.drop(filters, [:object, :subject]))
    # |> debug("follows query")
  end

  def query([my: :followed], opts), do: [subject: current_user(opts)] |> query(opts)

  def query([my: :followers], opts), do: [object: current_user(opts)] |> query(opts)

  def query(filters, opts) do
    query_base(filters, opts)
    |> maybe_proload(!is_list(opts) || opts[:skip_preload])
  end

  defp maybe_proload(query, _skip_preload? = true), do: query

  defp maybe_proload(query, _) do
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

  def list_my_followers(opts, paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true),
    do: list_followers(current_user(opts), opts, with_profile_only)

  def list_followers(%{id: user_id} = _user, opts \\ [], paginate? \\ true, cursor_after \\ nil, with_profile_only \\ true) when is_binary(user_id) do
    query([object: user_id], opts)
    # |> maybe_with_follower_profile_only(with_profile_only)
    |> many(paginate?, cursor_after)
  end

  defp many(query, paginate?, cursor_after \\ nil)

  defp many(query, true, cursor_after),
    do: Repo.many_paginated(query, before: cursor_after)

  defp many(query, _, _), do: repo().many(query)

  defp maybe_with_follower_profile_only(q, true), do: q |> where([follower_profile: p], not is_nil(p.id))
  defp maybe_with_follower_profile_only(q, _), do: q
  defp maybe_with_followed_profile_only(q, true), do: q |> where([followed_profile: p], not is_nil(p.id))
  defp maybe_with_followed_profile_only(q, _), do: q

  defp get_for_follow(id) do

  end

  @doc """
  Follow someone/something, and federate it
  """
  def follow(user, object, opts \\ [])
  def follow(%{}=follower, followed, opts) do
    opts = Keyword.put_new(opts, :current_user, follower)

    check_follow(follower, followed, opts)
    ~> do_follow(follower, ..., opts)
  end

  defp check_follow(follower, followed, opts) do
    skip? = (:admins == skip_boundary_check?(opts) && Users.is_admin(follower))
    opts = if skip?, do: Keyword.put(opts, :verbs, [:see, :follow]), else: opts

    case followed do
      %{id: id} ->
        if skip?, do: {:ok, followed},
        else: Common.Pointers.one(id, opts)

      _ when is_binary(followed) ->
        if is_ulid?(followed) do
          Common.Pointers.one(followed, opts)
        else
          # try by username
          maybe_apply(Characters, :by_username, [followed, opts])
        end
    end
  end

  defp do_follow(%{} = follower, %{} = followed, opts \\ []) do

    preset_or_custom_boundary = [
      preset: "local", # TODO: make configurable
      to_circles: [ulid(followed)],
      to_feeds: [Feeds.feed_id(:inbox, followed), Feeds.feed_id(:outbox, follower)]
    ]

    with {:ok, follow} <- create(follower, followed, preset_or_custom_boundary) do

      # debug(follow)

      # TEMPORARY: make my profile visible to people I follow
      # Boundaries.maybe_make_visible_for(follower, follower, followed)

      # TEMPORARY: make sure the profile of someone I follow is visible to me
      # Boundaries.maybe_make_visible_for(followed, followed, follower)

      # make the follow itself visible to both
      # Boundaries.maybe_make_visible_for(follower, follow, followed)

      {:ok, activity} = FeedActivities.notify_object(follower, :follow, followed)
      FeedActivities.publish(follower, activity, followed) # TODO: make configurable whether to publish the follow

      {:ok, Activities.activity_under_object(activity, follow)}
    else e ->
      msg = l "Could not follow (possibly already following?)"
      debug(e)
      {:error, msg}
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

  defp create(follower, followed, preset_or_custom_boundary) do
    Edges.changeset(Follow, follower, :follow, followed, preset_or_custom_boundary)
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
      # reaffirm that the follow has gone through
      {:ok, _} ->
        Logger.warn("Follows: federated follow already exists")
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
