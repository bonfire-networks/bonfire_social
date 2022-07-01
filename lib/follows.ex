defmodule Bonfire.Social.Follows do

  alias Bonfire.Data.Social.{Follow, Request}
  alias Bonfire.Me.{Boundaries, Characters, Users}
  alias Bonfire.Social.{Activities, APActivities, Edges, FeedActivities, Feeds, Integration, Requests}
  alias Bonfire.Social.LivePush
  alias Bonfire.Data.Identity.User
  alias Ecto.Changeset
  alias Pointers.Changesets
  import Bonfire.Boundaries.Queries
  import Where
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  def queries_module, do: Follow
  def context_module, do: Follow
  def federation_module, do: ["Follow", {"Create", "Follow"}, {"Undo", "Follow"}, {"Delete", "Follow"}, {"Accept", "Follow"}, {"Reject", "Follow"}]

  def following?(subject, object), do: not is_nil(get!(subject, object, skip_boundary_check: true)) # TODO: privacy
  def requested?(subject, object), do: Requests.requested?(subject, Follow, object)

  @doc """
  Follow someone/something. In case of success, publishes to feeds and federates.

  If the user is not permitted to follow the object, or the object is
  a remote actor, will instead request to follow.
  """
  def follow(user, object, opts \\ [])
  def follow(%{}=follower, object, opts) do
    with {:ok, result} <- maybe_follow_or_request(follower, object, opts) do
      # debug(result, "follow or request result")
      {:ok, result}
    end
  end

  defp maybe_follow_or_request(follower, object, opts) do
    opts = Keyword.put_new(opts, :current_user, follower)
    follower = repo().preload(follower, :peered)
    case check_follow(follower, object, opts) do
      {:local, object} ->
        if Integration.is_local?(follower) do
          info(object, "local following local, attempting follow")
          do_follow(follower, object, opts)
        else
          info(object, "remote following local, attempting a request")
          Requests.request(follower, Follow, object, opts)
        end
      {:remote, object} ->
        if Integration.is_local?(follower) do
          info(object, "local following remote, attempting a request")
          Requests.request(follower, Follow, object, opts)
        else
          info(object, "remote following remote, should not be possible!")
          {:error, :not_permitted}
        end
      :not_permitted ->
        info(object, "not permitted to follow, attempting a request instead")
        Requests.request(follower, Follow, object, opts)
    end
  end

  @doc """
  Accepts a follow request, poblishes to feeds and federates.
  """
  def accept(request, opts) do
    with {:ok, %{edge: %{object: object, subject: subject}} = request} <- Requests.accept(request, opts) |> repo().maybe_preload(edge: [:subject, :object]),
         _ <- Edges.delete_by_both(subject, Follow, object), # remove the Edge so we can recreate one linked to the Follow, because of the unique key on subject/object/table_id
         _ <- Activities.delete_by_subject_verb_object(subject, :request, object), # remove the Request Activity from notifications
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
    Cache.maybe_apply_cached(&fetch_all_followed_outboxes/2, [user, opts], opts ++ [cache_key: "my_followed:#{ulid(user)}"])
  end

  defp fetch_all_followed_outboxes(user, opts \\ []) do
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

  def list_my_followed(current_user, opts \\ []),
    do: list_followed(current_user, [current_user: current_user] ++ opts)

  def list_followed(%{id: user_id} = _user, opts \\ []) when is_binary(user_id) do
    query([subject: user_id], opts)
    |> where([object: object], object.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_followed_profile_only(opts)
    |> many(opts[:paginate], opts[:pagination])
  end

  def list_my_followers(current_user, opts \\ []),
    do: list_followers(current_user, [current_user: current_user] ++ opts)

  def list_followers(%{id: user_id} = _user, opts \\ []) when is_binary(user_id) do
    query([object: user_id], opts)
    |> where([subject: subject], subject.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_follower_profile_only(opts)
    |> many(opts[:paginate], opts[:pagination])
  end

  defp many(query, paginate?, pagination \\ nil)
  defp many(query, true, pagination), do: Repo.many_paginated(query, pagination)
  defp many(query, _, _), do: repo().many(query)

  defp maybe_with_follower_profile_only(q, true), do: q |> where([follower_profile: p], not is_nil(p.id))
  defp maybe_with_follower_profile_only(q, _), do: q

  # def changeset(:create, subject, object, boundary) do
  #   Changesets.cast(%Follow{}, %{}, [])
  #   |> Edges.put_assoc(subject, object, :follow, boundary)
  # end

  defp check_follow(follower, object, opts) do
    skip? = skip_boundary_check?(opts, object)
    skip? = (:admins == skip? && Users.is_admin?(follower)) || (skip? == true)
    opts =
      opts
      |> Keyword.put_new(:verbs, [:follow])
      |> Keyword.put_new(:current_user, follower)
    if skip? do
      info("skip boundary check")
      local_or_remote_object(object)
    else
      case ulid(object) do
        id when is_binary(id) ->
          case Bonfire.Boundaries.load_pointers(id, current_user: follower, verbs: :follow) do
            object when is_struct(object) ->
              local_or_remote_object(object)
            _ ->
              :not_permitted
          end
        _ ->
          error(object, "no object ID, attempting with username")
          case maybe_apply(Characters, :by_username, [object, opts]) do
            object when is_struct(object) ->
              local_or_remote_object(object)
            _ ->
              :not_permitted
          end
      end
    end
  end

  defp local_or_remote_object(id) when is_binary(id) do
    Bonfire.Common.Pointers.get(id)
    ~> local_or_remote_object()
  end
  defp local_or_remote_object(object) do
    object = repo().maybe_preload(object, [:peered, created: [creator: :peered]])
    |> info()

    if Integration.is_local?(object) do
      {:local, object}
    else
      {:remote, object}
    end
  end

  # Notes for future refactor:
  # * Make it pay attention to options passed in
  # * When we start allowing to follow things that aren't users, we might need to adjust the circles.
  # * Figure out how to avoid the advance lookup and ensuing race condition.
  defp do_follow(user, object, _opts) do
    to = [
      outbox: [user], # we include follows in feeds, since user has control over whether or not they want to see them in settings
      notifications: [object]
    ]
    opts = [
      boundary: "public", # TODO: make configurable (currently public is required so follows can be listed by AP adapter)
      to_circles: [ulid(object)], # also allow the followed user to see it
      to_feeds: to, # put it in our outbox and their notifications
    ]
    case create(user, object, opts) do
      {:ok, follow} ->
        Cache.remove("my_followed:#{ulid(user)}")

        LivePush.push_activity_object(FeedActivities.get_feed_ids(opts[:to_feeds]), follow, object, push_to_thread: false, notify: true) # FIXME: should not compute feed ids twice

        Bonfire.Boundaries.Circles.add_to_circles(object, Bonfire.Boundaries.Circles.get_stereotype_circles(user, :followed))
        Bonfire.Boundaries.Circles.add_to_circles(user, Bonfire.Boundaries.Circles.get_stereotype_circles(object, :followers))

        Integration.ap_push_activity(user.id, follow)

        {:ok, follow}
      {:error, e} ->
        error(e)
        maybe_already_followed(user, object)
    end
  rescue e in Ecto.ConstraintError ->
    error(e)
    maybe_already_followed(user, object)
  end

  defp maybe_already_followed(user, object) do
    case get(user, object) do
      {:ok, follow} ->
        debug("the user already follows this object")
        {:ok, follow}
      e ->
        error(e)
    end
  end

  def unfollow(user, %{} = object) do
    un = Edges.delete_by_both(user, Follow, object)
    # with [_id] <- un do
      # delete the like activity & feed entries
      Activities.delete_by_subject_verb_object(user, :follow, object)

      Cache.remove("my_followed:#{ulid(user)}")

      Bonfire.Boundaries.Circles.get_stereotype_circles(user, :followed) ~> Bonfire.Boundaries.Circles.remove_from_circles(object, ...)
      Bonfire.Boundaries.Circles.get_stereotype_circles(object, :followers) ~> Bonfire.Boundaries.Circles.remove_from_circles(user, ...)

    # end
  end

  def unfollow(%{} = user, object) when is_binary(object) do
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, current_user: user) do
      unfollow(user, object)
    end
  end

  defp create(follower, object, opts) do
    Edges.changeset(Follow, follower, :follow, object, opts)
    |> repo().insert()
  end

  ### ActivityPub integration


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
    warn("Follows: recording an incoming follow...")
    with {:ok, followed} <- Bonfire.Federate.ActivityPub.Utils.get_character_by_ap_id(object),
         false <- following?(follower, followed), # check if not already following
         {:ok, %Follow{} = follow} <- follow(follower, followed, current_user: follower) do
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
        info("Follow was requested and remains pending")
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
