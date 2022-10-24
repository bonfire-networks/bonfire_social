defmodule Bonfire.Social.Boosts do
  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Integration
  alias Bonfire.Social.LivePush
  alias Bonfire.Social.Objects

  alias Bonfire.Data.Edges.Edge

  use Bonfire.Common.Repo,
    searchable_fields: [:booster_id, :boosted_id]

  # import Bonfire.Social.Integration
  use Bonfire.Common.Utils

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Boost

  def federation_module,
    do: [
      "Announce",
      {"Create", "Announce"},
      {"Undo", "Announce"},
      {"Delete", "Announce"}
    ]

  def boosted?(%{} = user, object),
    do: not is_nil(get!(user, object, skip_boundary_check: true))

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  def boost(%{} = booster, %{} = object) do
    if Bonfire.Boundaries.can?(booster, :boost, object) do
      do_boost(booster, object)
    else
      error(l("Sorry, you cannot boost this"))
    end
  end

  def boost(%{} = booster, boosted) when is_binary(boosted) do
    with {:ok, object} <-
           Bonfire.Common.Pointers.get(boosted,
             current_user: booster,
             verbs: [:boost]
           ) do
      # debug(liked)
      do_boost(booster, object)
    else
      _ ->
        error(l("Sorry, you cannot boost this"))
    end
  end

  def do_boost(%{} = booster, %{} = boosted) do
    boosted = Objects.preload_creator(boosted)
    boosted_creator = Objects.object_creator(boosted)

    opts = [
      # TODO: get the preset for boosting from config and/or user's settings
      boundary: "public",
      to_circles: [ulid(boosted_creator)],
      to_feeds:
        [outbox: booster] ++
          Feeds.maybe_creator_notification(booster, boosted_creator)
    ]

    with {:ok, boost} <- create(booster, boosted, opts) do
      # Push to AP, which will need to see the subject and object
      boost =
        repo().preload(boost,
          edge: [
            subject: fn _ -> [booster] end,
            object: fn _ -> [boosted] end
          ]
        )

      Integration.ap_push_activity(booster.id, boost)
      # Also livepush, which will need a list of feed IDs we published to
      feed_ids = for fp <- boost.feed_publishes, do: fp.feed_id

      LivePush.push_activity_object(feed_ids, boost, boosted,
        push_to_thread: false,
        notify: true
      )

      {:ok, boost}
    end
  end

  def unboost(%{} = booster, %{} = boosted) do
    # delete the Boost
    Edges.delete_by_both(booster, Boost, boosted)
    # delete the boost activity & feed entries
    {:ok, Activities.delete_by_subject_verb_object(booster, :boost, boosted)}
  end

  def unboost(%{} = booster, boosted) when is_binary(boosted) do
    with {:ok, boosted} <-
           Bonfire.Common.Pointers.get(boosted, current_user: booster) do
      # debug(liked)
      unboost(booster, boosted)
    end
  end

  @doc "List current user's boosts"
  def list_my(opts) do
    list_by(current_user_required(opts), opts)
  end

  @doc "List boosts by the user "
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    opts = to_options(opts)
    # query FeedPublish
    list_paginated([subject: by_user], opts ++ [preload: :object])
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
    do: query([subject: current_user_required(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(booster, boosted, opts) do
    Edges.changeset(Boost, booster, :boost, boosted, opts)
    |> repo().insert()
  end

  def ap_publish_activity("create", boost) do
    with {:ok, booster} <-
           ActivityPub.Actor.get_cached_by_local_id(boost.edge.subject_id),
         object when not is_nil(object) <-
           Bonfire.Federate.ActivityPub.Utils.get_object(boost.edge.object) do
      ActivityPub.announce(booster, object)
    end
  end

  def ap_publish_activity("delete", boost) do
    with {:ok, booster} <-
           ActivityPub.Actor.get_cached_by_local_id(boost.edge.subject_id),
         object when not is_nil(object) <-
           Bonfire.Federate.ActivityPub.Utils.get_object(boost.edge.object) do
      ActivityPub.unannounce(booster, object)
    end
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Announce"}} = _activity,
        object
      ) do
    with {:ok, boosted} <-
           Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator) do
      boost(creator, boosted)
    end
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Undo"}} = _activity,
        %{data: %{"object" => boosted_object}} = _object
      ) do
    with {:ok, object} <-
           ActivityPub.Object.get_cached_by_ap_id(boosted_object),
         {:ok, boosted} <-
           Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator),
         [id] <- unboost(creator, boosted) do
      {:ok, id}
    end
  end
end
