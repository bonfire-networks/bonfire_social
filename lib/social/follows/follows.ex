defmodule Bonfire.Social.Follows do

  alias Bonfire.Data.Social.{Follow, Request}
  alias Bonfire.Me.{Boundaries, Characters, Users}
  alias Bonfire.Social.{Activities, APActivities, Edges, FeedActivities, Feeds, Integration, Requests}
  alias Bonfire.Data.Identity.User
  alias Ecto.Changeset
  alias Pointers.Changesets
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
  Follow someone/something. In case of success, publishes to feeds and federates.

  If the user is not permitted to follow the object, or the object is
  a remote actor, will instead request to follow.
  """
  def follow(user, object, opts \\ [])
  def follow(%{}=follower, object, opts) do
    opts = Keyword.put_new(opts, :current_user, follower)
    follower = repo().preload(follower, :peered)
    case check_follow(follower, object, opts) do
      {:local, object} ->
        if Integration.is_local?(follower) do
          debug(object, "local following local, attempting follow")
          do_follow(follower, object, opts)
        else
          debug(object, "remote following local, attempting a request")
          Requests.request(follower, Follow, object, opts)
        end
      {:remote, object} ->
        if Integration.is_local?(follower) do
          debug(object, "local following remote, attempting a request")
          Requests.request(follower, Follow, object, opts)
        else
          debug(object, "remote following remote, should not be here")
          {:error, :not_permitted}
        end
      :not_permitted ->
        debug(object, "not permitted to follow, attempting a request instead")
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
      debug("skip boundary check")
      {:local, object}
    else
      case ulid(object) do
        id when is_binary(id) ->
          case Bonfire.Boundaries.load_pointers(id, current_user: follower, verbs: :follow) do
            nil -> :not_permitted
            loaded ->
              object = repo().maybe_preload(loaded, [:peered, created: [creator: :peered]])
              #|> debug()
              if Integration.is_local?(object), do: {:local, object}, else: {:remote, object}
          end
        _ ->
          error(object, "no object ID, attempting with username")
          case maybe_apply(Characters, :by_username, [object, opts]) do
            nil -> :not_permitted
            _ ->
              object = repo().maybe_preload(object, [:peered])
              if Integration.is_local?(object), do: {:local, object}, else: {:remote, object}
          end
      end
    end
  end

  # Notes for future refactor:
  # * Make it pay attention to options passed in
  # * When we start allowing to follow things that aren't users, we might need to adjust the circles.
  # * Figure out how to avoid the advance lookup and ensuing race condition.
  defp do_follow(user, object, _opts) do
    opts = [
      boundary: "public", # TODO: make configurable (currently public is required so follows can be listed by AP adapter)
      to_circles: [ulid(object)], # also allow the followed user to see it
      to_feeds: [outbox: [user], notifications: [object]], # put it in our outbox and their notifications
    ]
    case create(user, object, opts) do
      {:ok, follow} ->
        Integration.ap_push_activity(user.id, follow)
        {:ok, follow}
      {:error, e} ->
        case get(user, object) do
          {:ok, follow} ->
            debug("the user already follows this object")
            {:ok, follow}
          _ ->
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
