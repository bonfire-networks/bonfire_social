defmodule Bonfire.Social.Boosts do
  # alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Boost
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Integration
  alias Bonfire.Social.LivePush
  alias Bonfire.Social.Objects

  # alias Bonfire.Data.Edges.Edge

  use Bonfire.Common.Repo,
    searchable_fields: [:booster_id, :boosted_id]

  # import Bonfire.Social.Integration
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

  def boosted?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(object, _) when is_struct(object),
    do: Edges.count(:boost, object, skip_boundary_check: true)

  def date_last_boosted(%{} = user, object),
    do: Edges.last_date(__MODULE__, user, object, skip_boundary_check: true)

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

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
           Bonfire.Common.Needle.get(
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
    case Config.get([Bonfire.Social.Boosts, :can_reboost_after], false) |> debug("bconf") do
      seconds when is_integer(seconds) ->
        # max 1 re-boost every X seconds
        case date_last_boosted(booster, boosted) do
          nil ->
            do_boost(booster, boosted, opts)

          date_last_boosted ->
            if DateTime.diff(DateTime.now!("Etc/UTC"), date_last_boosted, :second) >
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
    boosted = Objects.preload_creator(boosted)
    boosted_creator = Objects.object_creator(boosted)

    opts = [
      # TODO: get the preset for boosting from config and/or user's settings
      boundary: "public",
      to_circles: [id(boosted_creator)],
      to_feeds:
        [outbox: booster] ++
          if(e(opts, :notify_creator, true),
            do: Feeds.maybe_creator_notification(booster, boosted_creator, opts),
            else: []
          )
    ]

    with {:ok, boost} <- create(booster, boosted, opts) do
      # livepush will need a list of feed IDs we published to
      feed_ids = for fp <- boost.feed_publishes, do: fp.feed_id

      LivePush.push_activity_object(feed_ids, boost, boosted,
        push_to_thread: false,
        notify: true
      )

      Integration.maybe_federate_and_gift_wrap_activity(booster, boost)
      |> debug("maybe_federated the boost")
    end
  end

  def unboost(booster, boosted, opts \\ [])

  def unboost(booster, %{} = boosted, _opts) do
    # delete the Boost
    Edges.delete_by_both(booster, Boost, boosted)
    # delete the boost activity & feed entries
    {:ok, Activities.delete_by_subject_verb_object(booster, :boost, boosted)}
  end

  def unboost(booster, boosted, opts) when is_binary(boosted) do
    with {:ok, boosted} <-
           Bonfire.Common.Needle.get(boosted, opts ++ [current_user: booster]) do
      # debug(liked)
      unboost(booster, boosted)
    end
  end

  @doc "List current user's boosts"
  def list_my(opts) do
    list_by(current_user_required!(opts), opts)
  end

  @doc "List boosts by the user "
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    # query FeedPublish
    # [preload: [object: [created: [:creator]]]])
    list_paginated(
      [subject: by_user],
      to_options(opts) ++ [preload: :object_with_creator, subject_user: by_user]
    )
  end

  @doc "List boost of an object"
  def list_of(id, opts \\ []) when is_binary(id) or is_list(id) or is_map(id) do
    opts = to_options(opts)
    # query FeedPublish
    list_paginated([object: id], opts ++ [preload: :subject])
  end

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
    do: query([subject: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(booster, boosted, opts) do
    Edges.insert(Boost, booster, :boost, boosted, opts)
  end

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
      ActivityPub.announce(%{actor: booster, object: object, pointer: ulid(boost)})
    else
      e ->
        error(e, "Could not find the federated actor or object to boost.")
    end
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Announce"}} = _activity,
        object
      ) do
    Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(object,
      current_user: creator,
      verbs: [:boost]
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
           Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(object,
             current_user: creator,
             verbs: [:boost]
           ),
         [id] <- unboost(creator, pointable, skip_boundary_check: true) do
      {:ok, id}
    end
  end
end
