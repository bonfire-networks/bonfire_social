defmodule Bonfire.Social.Boosts do
  @moduledoc """
  Mutate, query, and federate boosts (re-sharing an activity or object).

  Boosts are implemented on top of the `Bonfire.Data.Edges.Edge` schema (see `Bonfire.Social.Edges` for shared functions)
  """

  # alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Data.Social.Activity
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social

  alias Bonfire.Social.Objects

  # alias Bonfire.Data.Edges.Edge

  use Bonfire.Common.Repo,
    searchable_fields: [:booster_id, :boosted_id]

  # import Bonfire.Social
  use Bonfire.Common.Utils

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Boost
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Announce",
      {"Create", "Announce"},
      {"Undo", "Announce"},
      {"Delete", "Announce"}
    ]

  @doc """
  Checks if a user has boosted an object.

  ## Examples

      iex> Bonfire.Social.Boosts.boosted?(user, object)
      true

  """
  def boosted?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  @doc """
  Counts boosts based on filters and options.

  ## Examples

      iex> Bonfire.Social.Boosts.count([subjects: user_id], [])
      5 # user made 5 boosts, across all objects

      iex> Bonfire.Social.Boosts.count(user, object)
      3 # user boosted object 3 times

      iex> Bonfire.Social.Boosts.count(object, [])
      10 # object was boosted 5 times, across all users

  """
  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(object, _) when is_struct(object),
    do: Edges.count(:boost, object, skip_boundary_check: true)

  @doc """
  Gets the date of the latest boost by a user for an object.

  ## Examples

      iex> Bonfire.Social.Boosts.date_last_boosted(user, object)
      ~U[2023-07-29 12:34:56Z]

  """
  def date_last_boosted(%{} = user, object),
    do: Edges.last_date(__MODULE__, user, object, skip_boundary_check: true)

  @doc """
  Retrieves a boost edge by subject and object.

  ## Examples

      iex> Bonfire.Social.Boosts.get(subject, object)
      {:ok, %Bonfire.Data.Social.Boost{}}

  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  @doc """
    Retrieves a boost edge, raising an error if not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  @doc """
  Boosts an object for a user.

  ## Examples

      iex> Bonfire.Social.Boosts.boost(user, object)
      {:ok, %Bonfire.Data.Social.Boost{}}

  """
  def boost(booster, boosted, opts \\ [])

  def boost(%{} = booster, %{} = object, opts) do
    if Bonfire.Boundaries.can?(booster, :boost, object) do
      maybe_boost(booster, object, opts)
    else
      error(l("Sorry, you cannot boost this"))
    end
  end

  def boost(%{} = booster, boosted, opts) when is_binary(boosted) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(
             boosted,
             opts ++
               [
                 current_user: booster,
                 verbs: [:boost]
               ]
           ) do
      # debug(liked)
      maybe_boost(booster, object, opts)
    else
      _ ->
        error(l("Sorry, you cannot boost this"))
    end
  end

  def maybe_boost(%{} = booster, %{} = boosted, opts \\ []) do
    case Config.get([Bonfire.Social.Boosts, :can_reboost_after], false)
         |> debug("can_reboost_after?") do
      seconds when is_integer(seconds) ->
        # max 1 re-boost every X seconds
        case date_last_boosted(booster, boosted) do
          nil ->
            do_boost(booster, boosted, opts)

          date_last_boosted ->
            if DateTime.diff(DateTime.now!("Etc/UTC"), date_last_boosted, :second)
               |> debug("last boosted X seconds ago") >
                 seconds,
               do: do_boost(booster, boosted, opts),
               else: {:error, l("You already boosted this recently.")}
        end

      true ->
        # unlimited re-boosts
        do_boost(booster, boosted, opts)

      _ ->
        # do not allow re-boosts
        if !boosted?(booster, boosted),
          do: do_boost(booster, boosted, opts),
          else: {:error, l("You already boosted this.")}
    end
  end

  defp do_boost(%{} = booster, %{} = boosted, opts \\ []) do
    object_creator =
      (opts[:object_creator] ||
         (
           boosted =
             Objects.preload_creator(boosted)
             |> flood("boosted object")

           Objects.object_creator(boosted)
         ))
      |> flood("the creator")

    # Use "public_remote" boundary for federated boosts
    boundary =
      if e(opts, :local, true) != false,
        do: "public",
        else:
          "public_remote"
          |> flood("boundary")

    opts =
      opts
      |> Keyword.merge(
        # TODO: get the preset for boosting from config and/or user's settings
        boundary: boundary,
        to_circles: [id(object_creator)],
        to_feeds:
          ([outbox: booster] ++
             if(e(opts, :notify_creator, true),
               do: Feeds.maybe_creator_notification(booster, object_creator, opts),
               else: []
             ))
          |> flood("boost_to_feeds")
      )

    with {:ok, boost} <- create(booster, boosted, opts) do
      # livepush will need a list of feed IDs we published to
      feed_ids =
        for fp <- e(boost, :feed_publishes, []),
            do:
              e(fp, :feed_id, nil)
              |> flood("published feed_ids")

      maybe_apply(Bonfire.Social.LivePush, :push_activity_object, [
        feed_ids,
        boost,
        boosted,
        [push_to_thread: false, notify: true]
      ])

      Social.maybe_federate_and_gift_wrap_activity(booster, boost)
      |> debug("maybe_federated the boost")
    end
  end

  @doc """
  Removes a boost from an object for a user, if one exists

  ## Examples

      iex> Bonfire.Social.Boosts.unboost(user, object)
      {:ok, _}

  """
  def unboost(booster, boosted, opts \\ [])

  def unboost(booster, %{} = boosted, _opts) do
    # delete the Boost
    Edges.delete_by_both(booster, Boost, boosted)
    # delete the boost activity & feed entries
    {:ok, Activities.delete_by_subject_verb_object(booster, :boost, boosted)}
  end

  def unboost(booster, boosted, opts) when is_binary(boosted) do
    with {:ok, boosted} <-
           Bonfire.Common.Needles.get(boosted, opts ++ [current_user: booster]) do
      # debug(liked)
      unboost(booster, boosted)
    end
  end

  @doc """
  Lists boosts by the current user.

  ## Examples

      iex> Bonfire.Social.Boosts.list_my(current_user: me)
      [%Bonfire.Data.Social.Boost{}, ...]

  """
  def list_my(opts) do
    list_by(current_user_required!(opts), opts)
  end

  @doc """
  Lists boosts by a specific user.

  ## Examples

      iex> Bonfire.Social.Boosts.list_by(user_id)
      [%Bonfire.Data.Social.Boost{}, ...]

  """
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    # query FeedPublish
    # [preload: [object: [created: [:creator]]]])
    list_paginated(
      [subjects: by_user],
      to_options(opts) ++ [preload: :object_with_creator, subject_user: by_user]
    )
  end

  @doc """
  Lists boosts of a specific object.

  ## Examples

      iex> Bonfire.Social.Boosts.list_of(object_id)
      [%Bonfire.Data.Social.Boost{}, ...]

  """
  def list_of(id, opts \\ []) when is_binary(id) or is_list(id) or is_map(id) do
    opts = to_options(opts)
    # query FeedPublish
    list_paginated([objects: id], opts ++ [preload: :subject])
  end

  @doc """
  Lists boosts with pagination.

  ## Examples

      iex> Bonfire.Social.Boosts.list_paginated([subjects: user_id], [limit: 10])
      %{edges: [%Bonfire.Data.Social.Boost{}, ...], page_info: %{...}}

  """
  def list_paginated(filters, opts \\ []) do
    filters
    |> query(opts)
    # |> debug()
    |> repo().many_paginated(opts)

    # TODO: activity preloads
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Boost, filters, opts)

    # |> proload(edge: [
    #   # subject: {"booster_", [:profile, :character]},
    #   # object: {"boosted_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
  end

  def query([my: :boosts], opts),
    do: query([subjects: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(booster, boosted, opts) do
    Edges.insert(Boost, booster, :boost, boosted, opts)
  end

  @doc """
  Publishes a federated activity for a boost action.

  ## Examples

      iex> Bonfire.Social.Boosts.ap_publish_activity(subject, :create, boost)
      {:ok, _activity}

  """
  def ap_publish_activity(subject, :delete, boost) do
    with {:ok, booster} <-
           ActivityPub.Actor.get_cached(
             pointer: subject || e(boost.edge, :subject, nil) || e(boost.edge, :subject_id, nil)
           ),
         {:ok, object} <-
           ActivityPub.Object.get_cached(
             pointer: e(boost.edge, :object, nil) || e(boost.edge, :object_id, nil)
           ) do
      ActivityPub.unannounce(%{actor: booster, object: object})
    else
      {:error, :not_found} ->
        :ignore

      e ->
        error(e)
    end
  end

  def ap_publish_activity(subject, _verb, boost) do
    boost = repo().maybe_preload(boost, :edge)

    with {:ok, booster} <-
           ActivityPub.Actor.get_cached(
             pointer:
               subject || e(boost, :edge, :subject, nil) || e(boost, :edge, :subject_id, nil)
           ),
         {:ok, object} <-
           ActivityPub.Object.get_cached(
             pointer: e(boost, :edge, :object, nil) || e(boost, :edge, :object_id, nil)
           ) do
      ActivityPub.announce(%{actor: booster, object: object, pointer: uid(boost)})
    else
      {:error, :not_found} ->
        :ignore

      e ->
        error(e)
    end
  end

  @doc """
  Receives and processes a federated boost activity.

  ## Examples

      iex> Bonfire.Social.Boosts.ap_receive_activity(creator, activity, object)
      {:ok, _boost}

  """
  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Announce"}} = _activity,
        object
      ) do
    Utils.maybe_apply(
      Bonfire.Federate.ActivityPub.AdapterUtils,
      :return_pointable,
      [object, [current_user: creator, verbs: [:boost]]]
    )
    ~> boost(creator, ..., local: false)
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Undo"}} = _activity,
        %{data: %{"object" => boosted_object}} = _object
      ) do
    with {:ok, object} <-
           ActivityPub.Object.get_cached(ap_id: boosted_object),
         {:ok, pointable} <-
           Utils.maybe_apply(
             Bonfire.Federate.ActivityPub.AdapterUtils,
             :return_pointable,
             [object, [current_user: creator, verbs: [:boost]]]
           ),
         [id] <- unboost(creator, pointable, skip_boundary_check: true) do
      {:ok, id}
    end
  end
end
