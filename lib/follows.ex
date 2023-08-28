defmodule Bonfire.Social.Follows do
  alias Bonfire.Data.Social.Follow
  alias Bonfire.Data.Social.Request

  # alias Bonfire.Me.Boundaries
  alias Bonfire.Me.Characters
  alias Bonfire.Me.Users

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social.Integration
  alias Bonfire.Social.Requests

  alias Bonfire.Social.LivePush
  # alias Bonfire.Data.Identity.User
  # alias Ecto.Changeset
  # alias Pointers.Changesets
  import Bonfire.Boundaries.Queries
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Follow
  def query_module, do: Follow

  def federation_module,
    do: [
      "Follow",
      {"Create", "Follow"},
      {"Undo", "Follow"},
      {"Delete", "Follow"},
      {"Accept", "Follow"},
      {"Reject", "Follow"}
    ]

  # TODO: privacy
  def following?(subject, object),
    # current_user: subject)
    do: Edges.exists?(__MODULE__, subject, object, verbs: [:follow], skip_boundary_check: true)

  def requested?(subject, object),
    do: Requests.requested?(subject, Follow, object)

  @doc """
  Follow someone/something. In case of success, publishes to feeds and federates.

  If the user is not permitted to follow the object, or the object is
  a remote actor, will instead request to follow.
  """
  def follow(user, object, opts \\ [])

  def follow(%{} = follower, object, opts) do
    with {:ok, result} <- maybe_follow_or_request(follower, object, opts) do
      # debug(result, "follow or request result")
      {:ok, result}
    end
  end

  defp maybe_follow_or_request(follower, object, opts) do
    opts = Keyword.put_new(to_options(opts), :current_user, follower)
    follower = repo().preload(follower, :peered)

    case check_follow(follower, object, opts) do
      {:local, object} ->
        info("following local, do the follow")
        do_follow(follower, object, opts)

      # Note: we now rely on Boundaries instead of making an arbitrary difference here
      # if Integration.is_local?(follower) do
      # info("remote following local, attempting a request")
      # Requests.request(follower, Follow, object, opts)
      # else
      #   info("local following local, attempting follow")
      #   do_follow(follower, object, opts)
      # end

      {:remote, object} ->
        if Integration.is_local?(follower) do
          info("local following remote, attempting a request instead of follow")
          Requests.request(follower, Follow, object, opts)
        else
          warn("remote following remote, should not be possible!")
          {:error, :not_permitted}
        end

      :not_permitted ->
        info("not permitted to follow, attempting a request instead")
        Requests.request(follower, Follow, object, opts)
    end
  end

  # Notes for future refactor:
  # * Make it pay attention to options passed in
  # * When we start allowing to follow things that aren't users, we might need to adjust the circles.
  # * Figure out how to avoid the advance lookup and ensuing race condition.
  defp do_follow(%{} = user, %{} = object, opts) do
    # character is needed for boxes & graphDB
    user =
      user
      |> repo().maybe_preload(:character)

    object =
      object
      |> repo().maybe_preload(:character)

    to = [
      # we include follows in feeds, since user has control over whether or not they want to see them in settings
      outbox: [user],
      notifications: [object]
    ]

    opts =
      Keyword.merge(
        [
          # TODO: make configurable (currently public is required so follows can be listed by AP adapter)
          boundary: "public",
          # also allow the followed user to see it
          to_circles: [id(object)],
          # put it in our outbox and their notifications
          to_feeds: to
        ],
        opts
      )

    repo().transact_with(fn ->
      case create(user, object, opts) do
        {:ok, follow} ->
          invalidate_followed_outboxes_cache(id(user))

          # FIXME: should not compute feed ids twice
          LivePush.push_activity_object(
            FeedActivities.get_feed_ids(opts[:to_feeds]),
            follow,
            object,
            push_to_thread: false,
            notify: true
          )

          follower_type = Types.object_type(user)
          object_type = Types.object_type(object)

          if follower_type == Bonfire.Data.Identity.User,
            do:
              Bonfire.Boundaries.Circles.add_to_circles(
                object,
                Bonfire.Boundaries.Circles.get_stereotype_circles(user, :followed)
              )

          if object_type == Bonfire.Data.Identity.User,
            do:
              Bonfire.Boundaries.Circles.add_to_circles(
                user,
                Bonfire.Boundaries.Circles.get_stereotype_circles(
                  object,
                  :followers
                )
              )

          if follower_type == Bonfire.Data.Identity.User and
               object_type == Bonfire.Data.Identity.User,
             do: Bonfire.Social.Graph.graph_add(user, object, Follow)

          if info(opts[:incoming] != true, "Maybe outgoing follow?"),
            do: Integration.maybe_federate_and_gift_wrap_activity(user, follow),
            else: {:ok, follow}

        e ->
          error(e)
          maybe_already_followed(user, object)
      end
    end)
  rescue
    e in Ecto.ConstraintError ->
      error(e)
      maybe_already_followed(user, object)
  end

  defp check_follow(follower, object, opts) do
    # debug(opts)
    # debug(id(follower))
    # debug(id(object))
    skip? = skip_boundary_check?(opts, object)
    # debug(skip?)
    skip? =
      skip? == true ||
        (skip? == :admins and maybe_apply(Bonfire.Me.Accounts, :is_admin?, follower) == true)

    opts =
      opts
      |> Keyword.put_new(:verbs, [:follow])
      |> Keyword.put_new(:current_user, follower)

    if skip? do
      info(skip?, "skip boundary check")
      local_or_remote_object(object)
    else
      case ulid(object) do
        id when is_binary(id) ->
          case Bonfire.Boundaries.load_pointer(id, opts) do
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

  @doc """
  Accepts a follow request, publishes to feeds and federates.
  Parameters are the requester plus the subject as current_user
  """
  def accept_from(subject, opts) do
    Requests.get(subject, Follow, current_user_required!(opts), opts)
    |> debug()
    ~> accept(opts)
  end

  @doc """
  Accepts a follow request, publishes to feeds and federates.
  Parameter are a Request (or its ID) plus the subject as current_user
  """
  def accept(request, opts) do
    debug(opts, "opts")

    repo().transact_with(fn ->
      with {:ok, %{edge: %{object: object, subject: subject}} = request} <-
             Requests.accept(request, opts)
             |> repo().maybe_preload(edge: [:subject, :object])
             |> debug("accepted"),
           # remove the Edge so we can recreate one linked to the Follow, because of the unique key on subject/object/table_id
           _ <- Edges.delete_by_both(subject, Follow, object),
           # remove the Request Activity from notifications
           _ <-
             Activities.delete_by_subject_verb_object(subject, :request, object),
           {:ok, follow} <- do_follow(subject, object, opts) |> debug("accept_do_follow"),
           :ok <-
             if(debug(opts[:incoming] != true, "Maybe outgoing accept?"),
               do: Requests.ap_publish_activity(subject, {:accept, request}, follow),
               else: :ok
             ) do
        {:ok, follow}
      else
        e ->
          error(e, l("An error occurred while accepting the follow request"))
      end
    end)
  end

  def unfollow(user, %{} = object) do
    if following?(user, object) do
      Edges.delete_by_both(user, Follow, object)
      # with [_id] <- Edges.delete_by_both(user, Follow, object) do

      # delete the like activity & feed entries
      Activities.delete_by_subject_verb_object(user, :follow, object)

      invalidate_followed_outboxes_cache(id(user))

      Bonfire.Boundaries.Circles.get_stereotype_circles(user, :followed)
      ~> Bonfire.Boundaries.Circles.remove_from_circles(object, ...)

      Bonfire.Boundaries.Circles.get_stereotype_circles(object, :followers)
      ~> Bonfire.Boundaries.Circles.remove_from_circles(user, ...)

      Bonfire.Social.Graph.graph_remove(user, object, Follow)

      # Integration.maybe_federate(user, :unfollow, object)
      ap_publish_activity(user, :delete, object)

      # end
    else
      if requested?(user, object) do
        Requests.unrequest(user, Follow, object)
      else
        error("Not following")
      end
    end
  end

  def unfollow(%{} = user, object) when is_binary(object) do
    with {:ok, object} <-
           Bonfire.Common.Pointers.get(object,
             current_user: user,
             skip_boundary_check: true
           ) do
      unfollow(user, object)
    end
  end

  def ignore(request, opts) do
    Requests.ignore(request, opts)
  end

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

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
    |> Enum.map(&e(&1, :edge, :object, nil))
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
    |> Enum.map(&e(&1, :edge, :subject, nil))
  end

  def all_followed_outboxes(user, opts \\ []) do
    include_followed_categories = opts[:include_followed_categories]

    Cache.maybe_apply_cached(
      &fetch_all_followed_outboxes/3,
      [user, include_followed_categories, opts],
      opts ++ [cache_key: "my_followed:#{include_followed_categories == true}:#{id(user)}"]
    )
  end

  def invalidate_followed_outboxes_cache(user) do
    Cache.remove("my_followed:true:#{id(user)}")
    Cache.remove("my_followed:false:#{id(user)}")
  end

  defp fetch_all_followed_outboxes(user, include_categories, opts) do
    if(include_categories != true,
      do: opts ++ [filters: [exclude_object_type: Bonfire.Classify.Category]],
      else: opts
    )
    |> all_objects_by_subject(user, ...)
    |> debug()
    |> Enum.map(&e(&1, :character, :outbox_id, nil))
  end

  # defp query_base(filters, opts) do
  #   vis = filter_invisible(current_user(opts))
  #   from(f in Follow, join: v in subquery(vis), on: f.id == v.object_id)
  #   |> proload(:edge)
  #   |> query_filter(filters)
  # end

  defp query_base(filters, opts) do
    filters = e(opts, :filters, []) ++ filters

    Edges.query_parent(Follow, filters, opts)
    |> query_filter(Keyword.drop(filters, [:object, :subject]))

    # |> debug("follows query")
  end

  def query([my: :object], opts),
    do: query([subject: current_user_required!(opts)], opts)

  def query([my: :followers], opts),
    do: query([object: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  def list_my_followed(current_user, opts \\ []),
    do:
      list_followed(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  def list_followed(user, opts \\ []) do
    # TODO: configurable boundaries for follows
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :object]

    [subject: ulid(user), object_type: opts[:type]]
    |> query(opts)
    |> where([object: object], object.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_followed_profile_only(opts)
    |> Integration.many(opts[:paginate], opts)
  end

  def list_my_followers(current_user, opts \\ []),
    do:
      list_followers(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  def list_followers(user, opts \\ []) do
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :subject]

    [object: ulid(user), subject_type: opts[:type]]
    |> query(opts)
    |> where([subject: subject], subject.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_follower_profile_only(opts)
    |> Integration.many(opts[:paginate], opts)
  end

  # defp maybe_with_follower_profile_only(q, true),
  #   do: where(q, [follower_profile: p], not is_nil(p.id))

  # defp maybe_with_follower_profile_only(q, _), do: q

  # def changeset(:create, subject, object, boundary) do
  #   Changesets.cast(%Follow{}, %{}, [])
  #   |> Edges.put_assoc(subject, object, :follow, boundary)
  # end

  defp local_or_remote_object(id) when is_binary(id) do
    Bonfire.Common.Pointers.get(id, skip_boundary_check: true)
    ~> local_or_remote_object()
  end

  defp local_or_remote_object(object) do
    object = repo().maybe_preload(object, [:peered, created: [creator: :peered]])
    # |> info()

    if Integration.is_local?(object) do
      {:local, object}
    else
      {:remote, object}
    end
  end

  defp maybe_already_followed(user, object) do
    case get(user, object, skip_boundary_check: true) do
      {:ok, follow} ->
        debug("the user already follows this object")
        {:ok, follow}

      e ->
        error(e)
    end
  end

  defp create(%{} = follower, object, opts) do
    Edges.insert(Follow, follower, :follow, object, opts)
  end

  ### ActivityPub integration

  def ap_publish_activity(subject, :delete, %Follow{edge: edge}) do
    ap_publish_activity(
      subject || e(edge, :subject, nil) || edge.subject_id,
      :delete,
      e(edge, :object, nil) || edge.object_id
    )
  end

  def ap_publish_activity(subject, :delete, object) do
    with {:ok, follower} <-
           ActivityPub.Actor.get_cached(pointer: subject),
         {:ok, ap_object} <-
           ActivityPub.Actor.get_cached(pointer: object) do
      ActivityPub.unfollow(%{actor: follower, object: ap_object, local: true})
    end
  end

  def ap_publish_activity(subject, verb, follow) do
    error_msg = l("Could not federate the follow")

    follow = repo().maybe_preload(follow, :edge)

    with {:ok, follower} <-
           ActivityPub.Actor.get_cached(
             pointer:
               subject || e(follow, :edge, :subject, nil) || e(follow, :edge, :subject_id, nil)
           )
           |> info("follower actor"),
         {:ok, object} <-
           ActivityPub.Actor.get_cached(
             pointer: e(follow.edge, :object, nil) || e(follow, :edge, :object_id, nil)
           )
           |> info("followed actor"),
         {:ok, activity} <-
           ActivityPub.follow(%{
             actor: follower,
             object: object,
             local: true,
             pointer: ulid(follow)
           }) do
      {:ok, activity}
    else
      {:error, :not_found} ->
        error("Actor not found", error_msg)
        {:ok, :ignore}

      e ->
        error(e, error_msg)
        raise error_msg
    end
  end

  def ap_receive_activity(
        follower,
        %{data: %{"type" => "Follow"} = data} = _activity,
        object
      )
      when is_binary(follower) or is_struct(follower) do
    info(data, "Follows: attempt to record an incoming follow...")

    with {:ok, followed} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.fetch_character_by_ap_id(object),
         # check if not already following
         false <- following?(follower, followed),
         {:ok, %Follow{} = follow} <-
           follow(follower, followed, current_user: follower) do
      with {:ok, _accept_activity, _adapter_object, accepted_activity} <-
             ActivityPub.accept_activity(%{
               actor: object,
               to: [data["actor"]],
               object: data,
               local: true
             }) do
        debug("Follow was auto-accepted")

        {:ok, follow}
      else
        e ->
          error(e, "Unable to auto-accept the follow")
          {:ok, follow}
      end
    else
      true ->
        warn("Federated follow already exists")
        # reaffirm that the follow has gone through when following? was already == true

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

  def ap_receive_activity(
        followed,
        %{data: %{"type" => "Accept"} = _data} = _activity,
        %{data: %{"actor" => follower}} = _object
      ) do
    info("Accept incoming request")

    with {:ok, follower} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.fetch_character_by_ap_id(follower),
         {:ok, request} <-
           Requests.get(follower, Follow, followed, skip_boundary_check: true),
         {:ok, accepted} <- accept(request, current_user: followed, incoming: true) do
      debug(accepted, "acccccepted")
      {:ok, accepted}
    else
      {:error, :not_found} ->
        case following?(follower, followed) do
          false ->
            error("No such Follow")

          true ->
            # already followed
            {:ok, nil}
        end

      e ->
        error(e)
    end
  end

  def ap_receive_activity(
        followed,
        %{data: %{"type" => "Reject"} = _data} = _activity,
        %{data: %{"actor" => follower}} = _object
      ) do
    with {:ok, follower} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.fetch_character_by_ap_id(follower) do
      case following?(follower, followed) do
        false ->
          reject(follower, followed)

        true ->
          request =
            with {:ok, request} <- reject(follower, followed) do
              request
              |> debug("rejected previously accepted request")
            end

          unfollow(follower, followed)
          |> debug("unfollow rejected follow")

          {:ok, request}
      end
    end
  end

  def ap_receive_activity(
        follower,
        %{data: %{"type" => "Undo"} = _data} = _activity,
        %{data: %{"object" => followed_ap_id}} = _object
      ) do
    with {:ok, object} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.fetch_character_by_ap_id(followed_ap_id),
         [id] <- unfollow(follower, object) do
      {:ok, id}
    end
  end

  defp reject(follower, followed) do
    with {:ok, request} <-
           Requests.get(follower, Follow, followed, skip_boundary_check: true),
         {:ok, request} <- ignore(request, current_user: followed) do
      {:ok, request}
    end
  end
end
