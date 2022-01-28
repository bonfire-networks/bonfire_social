defmodule Bonfire.Social.Boosts do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Boundaries.Verbs
  # alias Bonfire.Data.Social.BoostCount
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds
  alias Bonfire.Data.Edges.Edge

  use Bonfire.Repo,
    searchable_fields: [:booster_id, :boosted_id]
  # import Bonfire.Social.Integration
  use Bonfire.Common.Utils


  def queries_module, do: Boost
  def context_module, do: Boost
  def federation_module, do: ["Announce", {"Create", "Announce"}, {"Undo", "Announce"}, {"Delete", "Announce"}]

  def boosted?(%{}=user, object), do: not is_nil(get!(user, object, skip_boundary_check: true))

  def get(subject, object, opts \\ []), do: Edges.get(__MODULE__, subject, object, opts)
  def get!(subject, object, opts \\ []), do: Edges.get!(__MODULE__, subject, object, opts)

  def boost(%{} = booster, %{} = boosted) do

    boosted = Objects.preload_creator(boosted)
    boosted_creator = Objects.object_creator(boosted)

    preset_or_custom_boundary = [
      preset: "public", # TODO: get the preset for boosting from config and/or user's settings
      to_circles: [ulid(boosted_creator)],
      to_feeds: [Feeds.feed_id(:notifications, boosted_creator), Feeds.feed_id(:outbox, booster)]
    ]

    with {:ok, boost} <- create(booster, boosted, preset_or_custom_boundary),
    {:ok, published} <- FeedActivities.publish(booster, :boost, boosted, preset_or_custom_boundary) do

      # debug(published)
      # make the boost itself visible to both
      # Bonfire.Me.Boundaries.maybe_make_visible_for(booster, boost, e(boosted, :created, :creator_id, nil))

      FeedActivities.maybe_notify_creator(booster, published, boosted) #|> IO.inspect

      {:ok, Activities.activity_under_object(published, boost)}
    end
  end
  def boost(%{} = booster, boosted) when is_binary(boosted) do
    with {:ok, boosted} <- Bonfire.Common.Pointers.get(boosted, current_user: booster) do
      #IO.inspect(liked)
      boost(booster, boosted)
    end
  end

  def unboost(%{}=booster, %{}=boosted) do
    Edges.delete_by_both(booster, boosted) # delete the Boost
    Activities.delete_by_subject_verb_object(booster, :boost, boosted) # delete the boost activity & feed entries
  end
  def unboost(%{} = booster, boosted) when is_binary(boosted) do
    with {:ok, boosted} <- Bonfire.Common.Pointers.get(boosted, current_user: booster) do
      #IO.inspect(liked)
      unboost(booster, boosted)
    end
  end

  @doc "List current user's boosts"
  def list_my(opts) do
    list_by(current_user(opts), opts)
  end

  @doc "List boosts by the user "
  def list_by(by_user, opts \\ []) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do

    # query FeedPublish
    [subject: by_user]
    |> list_paginated(opts)
  end

  @doc "List boost of an object"
  def list_of(id, opts \\ []) when is_binary(id) or is_list(id) or is_map(id) do

    # query FeedPublish
    [object: id]
    |> list_paginated(opts)
  end

  def list_paginated(filters, opts \\ []) do
    filters
    |> query(opts)
    # |> debug()
    |> Bonfire.Repo.many_paginated(opts)
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

  def query([my: :boosts], opts), do: [subject: current_user(opts)] |> query(opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(booster, boosted, preset_or_custom_boundary) do
    Edges.changeset(Boost, booster, :boost, boosted, preset_or_custom_boundary)
    |> repo().insert()
  end

  def ap_publish_activity("create", boost) do
    with {:ok, booster} <- ActivityPub.Actor.get_cached_by_local_id(boost.activity.subject_id),
         object when not is_nil(object) <- Bonfire.Federate.ActivityPub.Utils.get_object(boost.activity.object) do
            ActivityPub.announce(booster, object)
    end
  end

  def ap_publish_activity("delete", boost) do
    with {:ok, booster} <- ActivityPub.Actor.get_cached_by_local_id(boost.activity.subject_id),
         object when not is_nil(object) <- Bonfire.Federate.ActivityPub.Utils.get_object(boost.activity.object) do
            ActivityPub.unannounce(booster, object)
    end
  end

  def ap_receive_activity(creator, %{data: %{"type" => "Announce"}} = _activity, object) do
    with {:ok, boosted} <- Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator) do
           boost(creator, boosted)
    end
  end

  def ap_receive_activity(creator, %{data: %{"type" => "Undo"}} = _activity, %{data: %{"object" => boosted_object}} = _object) do
    with object when not is_nil(object) <- ActivityPub.Object.get_cached_by_ap_id(boosted_object),
         {:ok, boosted} <- Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator),
         [id] <- unboost(creator, boosted) do
          {:ok, id}
    end
  end
end
