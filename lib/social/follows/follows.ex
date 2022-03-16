defmodule Bonfire.Social.Follows do

  alias Bonfire.Data.Social.{Follow, Request}
  alias Bonfire.Me.{Boundaries, Characters, Users}
  alias Bonfire.Social.{Activities, APActivities, Edges, FeedActivities, Feeds, Integration, Requests}
  alias Bonfire.Data.Identity.User
  alias Ecto.Changeset
  import Bonfire.Boundaries.Queries
  import Where
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo

  def queries_module, do: Follow
  def context_module, do: Follow
  def federation_module, do: ["Follow", {"Create", "Follow"}, {"Undo", "Follow"}, {"Delete", "Follow"}, {"Accept", "Follow"}, {"Reject", "Follow"}]

  def following?(subject, object), do: not is_nil(get!(subject, object, skip_boundary_check: true)) # TODO: privacy
  def requested?(subject, object), do: Requests.requested?(subject, Follow, object)

  @doc """
  Follow someone/something, and federate it
  """
  def follow(user, object, opts \\ [])
  def follow(%{}=follower, object, opts) do
    opts = Keyword.put_new(opts, :current_user, follower)

    with {:ok, object} <- check_follow(follower, object, opts),
         true <- Integration.is_local?(object) do
      do_follow(follower, object, opts)
    else _ ->
      error("remote actor OR not allowed to follow, let's make a request instead")
      Requests.request(follower, Follow, object, opts)
    end
  end

  def accept(request, opts) do
    with {:ok, %{edge: %{object: object, subject: subject}} = request} <- Requests.accept(request, opts) |> repo().maybe_preload(edge: [:subject, :object]),
         _ <- Edges.delete_by_both(subject, Follow, object), # remove the Edge so we can recreate one linked to the Follow, because of the unique key on subject/object/table_id
         _ <- Activities.delete_by_subject_verb_object(subject, :verb, object), # remove the Request Activity from notifications
         {:ok, follow} <- do_follow(subject, object, opts) do

      maybe_publish_accept(request, follow)

      {:ok, follow}
    end
  end

  def maybe_publish_accept(request, follow) do
    with true <- Integration.is_local?(follow.edge.subject),
    {:ok, object_actor} <- ActivityPub.Adapter.get_actor_by_id(follow.edge.object_id) ,
         {:ok, subject_actor} <- ActivityPub.Adapter.get_actor_by_id(follow.edge.subject_id),
        %ActivityPub.Object{} = follow_ap_object <- ActivityPub.Object.get_by_pointer_id(request.id),
         {:ok, _} <- ActivityPub.accept(%{
            actor: object_actor,
            to: [subject_actor.data],
            object: follow_ap_object.data,
            local: true
          } ) do
      :ok
    end
  end

  def ignore(request, opts) do
    Requests.ignore(request, opts)
  end

  def get(subject, object, opts \\ []), do: Edges.get(__MODULE__, subject, object, opts)
  def get!(subject, object, opts \\ []), do: Edges.get!(__MODULE__, subject, object, opts)

  # TODO: abstract the next few functions into Edges
  def all_by_subject(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :object)
    |> query([subject: user], ...)
    |> repo().many()
  end

  def all_objects_by_subject(user, opts \\ []) do
    all_by_subject(user, opts)
    |> Enum.map(& e(&1, :edge, :object, nil))
  end

  def all_by_object(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :subject)
    |> query([object: user], ...)
    |> repo().many()
  end

  def all_subjects_by_object(user, opts \\ []) do
    all_by_object(user, opts)
    |> Enum.map(& e(&1, :edge, :subject, nil))
  end

  def all_followed_outboxes(user, opts \\ []) do
    all_objects_by_subject(user, opts)
    |> Enum.map(& e(&1, :character, :outbox_id, nil))
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

  def query([my: :object], opts), do: [subject: current_user(opts)] |> query(opts)

  def query([my: :followers], opts), do: [object: current_user(opts)] |> query(opts)

  def query(filters, opts) do
    query_base(filters, opts)
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
  defp many(query, true, cursor_after), do: Repo.many_paginated(query, before: cursor_after)
  defp many(query, _, _), do: repo().many(query)

  defp maybe_with_follower_profile_only(q, true), do: q |> where([follower_profile: p], not is_nil(p.id))
  defp maybe_with_follower_profile_only(q, _), do: q


  defp check_follow(follower, object, opts) do
    skip? = skip_boundary_check?(opts)
    skip? = (:admins == skip? && Users.is_admin?(follower)) || (skip? == true)
    opts = Keyword.put_new(opts, :verbs, [:follow])

    if skip? do
      debug("skip boundary check")
      {:ok, object}
    else
      case ulid(object) do
        id when is_binary(id) ->
          Common.Pointers.one(id, opts ++ [log_query: true])
          |> dump("allowed to follow ?")
        _ ->
          error(object, "no object ID, try with username")
          maybe_apply(Characters, :by_username, [object, opts])
      end
    end
    |> repo().maybe_preload([:peered, character: [:peered], created: [:peered]])
  end

  defp do_follow(follower, object, opts) do
    preset_or_custom_boundary = [
      boundary: "local", # TODO: make configurable
      to_circles: [ulid(object)],
      to_feeds: [Feeds.feed_id(:notifications, object), Feeds.feed_id(:outbox, follower)]
    ]

    with {:ok, follow} <- create(follower, object, preset_or_custom_boundary) do

      # debug(follow)

      # make the follow itself visible to both?
      # Boundaries.maybe_make_visible_for(follower, follow, object)

      {:ok, activity} = FeedActivities.notify_object(follower, :follow, {object, follow})

      FeedActivities.publish(follower, activity, object, "public") # TODO: make configurable whether to publish the follow

      {:ok, Activities.activity_under_object(activity, follow)}
    else e ->
      with {ok, follow} <- get(follower, object) do
        debug("was already following")
        {:ok, follow}
      else _ ->
        error(e)
        {:error, e}
      end
    end
  end

  def unfollow(follower, %{} = object) do
    with [_id] <- Edges.delete_by_both(follower, Follow, object) do
      # delete the like activity & feed entries
      Activities.delete_by_subject_verb_object(follower, :follow, object)
    end
  end

  def unfollow(%{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, current_user: user) do
      unfollow(user, object)
    end
  end

  defp create(follower, object, preset_or_custom_boundary) do
    Edges.changeset(Follow, follower, :follow, object, preset_or_custom_boundary)
    |> repo().upsert()
  end

  ###

  def ap_publish_activity("create", follow) do
    with {:ok, follower} <- ActivityPub.Adapter.get_actor_by_id(follow.edge.subject_id),
         {:ok, object} <- ActivityPub.Adapter.get_actor_by_id(follow.edge.object_id) do
      ActivityPub.follow(follower, object, nil, true)
    end
  end

  def ap_publish_activity("delete", follow) do
    with {:ok, follower} <- ActivityPub.Adapter.get_actor_by_id(follow.edge.subject.id),
         {:ok, object} <- ActivityPub.Adapter.get_actor_by_id(follow.edge.object_id) do
      ActivityPub.unfollow(follower, object, nil, true)
    end
  end

  def ap_receive_activity(follower, %{data: %{"type" => "Follow"} = data} = _activity, %{pointer_id: _followed_id} = object) when is_binary(follower) or is_struct(follower) do
    warn("Follows: recording an incoming follow")
    with false <- following?(follower, object), # check if not already following
         {:ok, %Follow{} = follow} <- follow(follower, object, current_user: follower) do
      ActivityPub.accept(%{
        actor: object,
        to: [data["actor"]],
        object: data,
        local: true
      })
      {:ok, follow}
    else
      true ->
      # reaffirm that the follow has gone through when following? was already == true
        warn("Follows: federated follow already exists")
        ActivityPub.accept(%{
          actor: object,
          to: [data["actor"]],
          object: data,
          local: true
        })

      {:ok, %Request{} = request} ->
        dump("Follow was requested and remains pending")
        {:ok, request}
      e ->
        error(e, "Could not follow")
        {:ignore, "Could not follow"}
    end
  end

  def ap_receive_activity(followed, %{data: %{"type" => "Accept"} = _data} = _activity, %{data: %{"actor" => follower}} = _object) do
    with {:ok, follower} <- Bonfire.Federate.ActivityPub.Utils.get_character_by_ap_id(follower),
         {:ok, request} <- Requests.get(follower, Follow, followed, skip_boundary_check: true),
         {:ok, request} <- accept(request, current_user: followed) do
          {:ok, request}
    end
  end

  def ap_receive_activity(followed, %{data: %{"type" => "Reject"} = _data} = _activity, %{data: %{"actor" => follower}} = _object) do
    with {:ok, follower} <- Bonfire.Federate.ActivityPub.Utils.get_character_by_ap_id(follower),
         {:ok, request} <- Requests.get(follower, Follow, followed, skip_boundary_check: true),
         {:ok, request} <- ignore(request, current_user: followed) do
          {:ok, request}
    end
  end

  def ap_receive_activity(follower, %{data: %{"type" => "Undo"} = _data} = _activity, %{data: %{"object" => followed_ap_id}} = _object) do
    with {:ok, object} <- Bonfire.Federate.ActivityPub.Utils.get_character_by_ap_id(followed_ap_id),
         [id] <- unfollow(follower, object) do
          {:ok, id}
    end
  end
end
