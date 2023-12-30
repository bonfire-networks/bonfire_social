defmodule Bonfire.Social.Likes do
  # alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Like
  # alias Bonfire.Data.Social.LikeCount
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Integration
  alias Bonfire.Social.Objects

  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  # import Ecto.Query
  # import Bonfire.Social.Integration
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Like
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: ["Like", {"Create", "Like"}, {"Undo", "Like"}, {"Delete", "Like"}]

  def liked?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  def by_liker(subject, opts \\ []) when is_map(subject) or is_binary(subject),
    do:
      (opts ++ [subject: subject])
      |> query([current_user: subject] ++ List.wrap(opts))
      |> repo().many()

  def by_liked(object, opts \\ []) when is_map(object) or is_binary(object),
    do: (opts ++ [object: object]) |> query(opts) |> repo().many()

  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(%{} = object, _), do: Edges.count(:like, object, skip_boundary_check: true)

  def like(liker, object, opts \\ [])

  def like(%{} = liker, %{} = object, opts) do
    if Bonfire.Boundaries.can?(liker, :like, object) do
      do_like(liker, object, opts)
    else
      error(l("Sorry, you cannot react to this"))
    end
  end

  def like(%{} = liker, liked, opts) when is_binary(liked) do
    with {:ok, object} <-
           Bonfire.Common.Needle.get(
             liked,
             opts ++
               [
                 current_user: liker,
                 verbs: [:like]
               ]
           ) do
      # debug(liked)
      do_like(liker, object, opts)
    else
      _ ->
        error(l("Sorry, you cannot react to this"))
    end
  end

  def do_like(%{} = liker, %{} = liked, opts \\ []) do
    liked = Objects.preload_creator(liked)
    liked_object_creator = Objects.object_creator(liked)

    opts =
      [
        # TODO: make configurable
        boundary: "mentions",
        to_circles: [id(liked_object_creator)],
        to_feeds: Feeds.maybe_creator_notification(liker, liked_object_creator, opts)
      ] ++ List.wrap(opts)

    case create(liker, liked, opts) do
      {:ok, like} ->
        Integration.maybe_federate_and_gift_wrap_activity(liker, like)

      {:error, e} ->
        case get(liker, liked) do
          {:ok, like} ->
            debug(like, "the user already likes this object")
            {:ok, like}

          _ ->
            error(e)
            {:error, e}
        end
    end
  end

  def unlike(liker, object, opts \\ [])

  def unlike(%{} = liker, %{} = liked, _opts) do
    # delete the Like
    Edges.delete_by_both(liker, Like, liked)
    # delete the like activity & feed entries
    Activities.delete_by_subject_verb_object(liker, :like, liked)

    # Note: the like count is automatically decremented by DB triggers
  end

  def unlike(%{} = liker, liked, opts) when is_binary(liked) do
    with {:ok, liked} <- Bonfire.Common.Needle.get(liked, opts ++ [current_user: liker]) do
      unlike(liker, liked, opts)
    end
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Like, filters, opts)

    # |> proload(edge: [
    #   # subject: {"liker_", [:profile, :character]},
    #   # object: {"liked_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
  end

  def query([my: :likes], opts),
    do: query([subject: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  # FIXME: This was defp
  def list_paginated(filters, opts) do
    query(filters, opts)
    # |> Activities.query_object_preload_activity(:like, :liked_id, opts)
    # |> Activities.as_permitted_for(opts, [:see])
    # |> debug()
    |> Integration.many(opts[:paginate?], opts)
  end

  @doc "List the current user's likes"
  def list_my(opts) do
    list_by(current_user_required!(opts), opts ++ [preload: :object_with_creator])
  end

  @doc "List likes by a user"
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts) |> Map.put(:subject, by_user),
      opts ++ [preload: :object, subject_user: by_user]
    )
  end

  @doc "List likers of something(s)"
  def list_of(object, opts \\ [])
      when is_binary(object) or is_list(object) or is_map(object) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts) |> Map.put(:object, object),
      Keyword.put_new(opts, :preload, :subject)
    )
  end

  defp create(liker, liked, opts) do
    Edges.insert(Like, liker, :like, liked, opts)
  end

  def ap_publish_activity(subject, :delete, like) do
    with {:ok, liker} <-
           ActivityPub.Actor.get_cached(pointer: subject || like.edge.subject_id),
         {:ok, object} <-
           ActivityPub.Object.get_cached(
             pointer: e(like.edge, :object, nil) || like.edge.object_id
           ) do
      ActivityPub.unlike(%{actor: liker, object: object})
    end
  end

  def ap_publish_activity(subject, _verb, like) do
    like = repo().maybe_preload(like, :edge)

    with {:ok, liker} <-
           ActivityPub.Actor.get_cached(pointer: subject || like.edge.subject_id),
         {:ok, object} <-
           ActivityPub.Object.get_cached(
             pointer: e(like.edge, :object, nil) || like.edge.object_id
           ) do
      ActivityPub.like(%{actor: liker, object: object, pointer: ulid(like)})
    end
  end

  def ap_receive_activity(
        liker,
        %{data: %{"type" => "Like"}} = _activity,
        object
      ) do
    Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(object,
      current_user: liker,
      verbs: [:like]
    )
    ~> like(liker, ..., local: false)
  end

  def ap_receive_activity(
        liker,
        %{data: %{"type" => "Undo"}} = _activity,
        %{data: %{"object" => liked_object}} = _object
      ) do
    with {:ok, object} <-
           ActivityPub.Object.get_cached(ap_id: liked_object),
         {:ok, pointable} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(object,
             current_user: liker,
             verbs: [:like]
           ),
         [id] <- unlike(liker, pointable, skip_boundary_check: true) do
      {:ok, id}
    end
  end
end
