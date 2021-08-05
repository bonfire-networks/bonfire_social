defmodule Bonfire.Social.Boosts do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Boundaries.Verbs
  # alias Bonfire.Data.Social.BoostCount
  alias Bonfire.Social.{Activities, FeedActivities}
  use Bonfire.Repo.Query,
    searchable_fields: [:booster_id, :boosted_id]
  # import Bonfire.Me.Integration
  import Bonfire.Common.Utils

  # def queries_module, do: Boost
  def context_module, do: Boost
  def federation_module, do: ["Announce", {"Create", "Announce"}, {"Undo", "Announce"}, {"Delete", "Announce"}]

  def boosted?(%User{}=user, boosted), do: not is_nil(get!(user, boosted))
  def get(%User{}=user, boosted), do: repo().single(by_both_q(user, boosted))
  def get!(%User{}=user, boosted), do: repo().one(by_both_q(user, boosted))
  def by_booster(%User{}=user), do: repo().many(by_booster_q(user))
  def by_boosted(%User{}=user), do: repo().many(by_boosted_q(user))
  def by_any(%User{}=user), do: repo().many(by_any_q(user))

  def boost(%User{} = booster, %{} = boosted) do
    with {:ok, boost} <- create(booster, boosted),
    {:ok, published} <- FeedActivities.publish(booster, :boost, boosted) do
      # TODO: increment the boost count

      FeedActivities.maybe_notify_creator(booster, published, boosted) #|> IO.inspect

      {:ok, boost}
    end
  end
  def boost(%User{} = booster, boosted) when is_binary(boosted) do
    with {:ok, boosted} <- Bonfire.Common.Pointers.get(boosted) do
      #IO.inspect(liked)
      boost(booster, boosted)
    end
  end

  def unboost(%User{}=booster, %{}=boosted) do
    delete_by_both(booster, boosted) # delete the Boost
    Activities.delete_by_subject_verb_object(booster, :boost, boosted) # delete the boost activity & feed entries
    # TODO: decrement the boost count
  end
  def unboost(%User{} = booster, boosted) when is_binary(boosted) do
    with {:ok, boosted} <- Bonfire.Common.Pointers.get(boosted) do
      #IO.inspect(liked)
      unboost(booster, boosted)
    end
  end

  @doc "List current user's boosts, which are in their outbox"
  def list_my(current_user, cursor_after \\ nil, preloads \\ :all) when is_binary(current_user) or is_map(current_user) do
    list_by(current_user, current_user, cursor_after, preloads)
  end

  @doc "List boosts by the user and which are in their outbox"
  def list_by(by_user, current_user \\ nil, cursor_after \\ nil, preloads \\ :all) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do

    # query FeedPublish
    [feed_id: ulid(by_user), boosts_by: {ulid(by_user), &filter/3} ]
    |> FeedActivities.feed_paginated(current_user, cursor_after, preloads)
  end

  @doc "List boost of an object and which are in a feed"
  def list_of(id, current_user \\ nil, cursor_after \\ nil, preloads \\ :all) when is_binary(id) or is_list(id) or is_map(id) do

    # query FeedPublish
    [boosts_of: {ulid(id), &filter/3} ]
    |> FeedActivities.feed_paginated(current_user, cursor_after, preloads)
  end

  defp create(booster, boosted) do
    changeset(booster, boosted) |> repo().insert()
  end

  defp changeset(booster, boosted) do
    Boost.changeset(%Boost{}, %{booster_id: ulid(booster), boosted_id: ulid(boosted)})
  end

  #doc "Delete boosts where i am the booster"
  defp delete_by_booster(%User{}=me), do: elem(repo().delete_all(by_booster_q(me)), 1)

  #doc "Delete boosts where i am the boosted"
  defp delete_by_boosted(%User{}=me), do: elem(repo().delete_all(by_boosted_q(me)), 1)

  #doc "Delete boosts where i am the booster or the boosted."
  defp delete_by_any(%User{}=me), do: elem(repo().delete_all(by_any_q(me)), 1)

  #doc "Delete boosts where i am the booster and someone else is the boosted."
  defp delete_by_both(%User{}=me, %{}=boosted), do: elem(repo().delete_all(by_both_q(me, boosted)), 1)

  defp by_booster_q(%User{id: id}) do
    from f in Boost,
      where: f.booster_id == ^id,
      select: f.id
  end

  defp by_boosted_q(%User{id: id}) do
    from f in Boost,
      where: f.boosted_id == ^id,
      select: f.id
  end

  defp by_any_q(%User{id: id}) do
    from f in Boost,
      where: f.booster_id == ^id or f.boosted_id == ^id,
      select: f.id
  end

  defp by_both_q(%User{id: booster}, %{id: boosted}), do: by_both_q(booster, boosted)

  defp by_both_q(booster, boosted) when is_binary(booster) and is_binary(boosted) do
    from f in Boost,
      where: f.booster_id == ^booster or f.boosted_id == ^boosted,
      select: f.id
  end


  #doc "List likes created by the user and which are in their outbox, which are not replies"
  def filter(:boosts_of, id, query) do
    verb_id = Verbs.verbs()[:boost]

    query
    |> join_preload([:activity])
    |> where(
      [activity: activity],
      activity.verb_id==^verb_id and activity.object_id == ^ulid(id)
    )
  end


  #doc "List likes created by the user and which are in their outbox, which are not replies"
  def filter(:boosts_by, user_id, query) do
    verb_id = Verbs.verbs()[:boost]

      query
      |> join_preload([:activity, :subject_character])
      |> where(
        [activity: activity, subject_character: booster],
        activity.verb_id==^verb_id and booster.id == ^ulid(user_id)
      )
  end

  def ap_publish_activity("create", boost) do
    boost = Bonfire.Repo.preload(boost, :boosted)

    with {:ok, booster} <- ActivityPub.Actor.get_cached_by_local_id(boost.booster_id),
         boosted when not is_nil(boosted) <- Bonfire.Common.Pointers.follow!(boost.boosted),
         object when not is_nil(boosted) <- Bonfire.Federate.ActivityPub.Utils.get_object(boosted) do
            ActivityPub.announce(booster, object)
    end
  end

  def ap_publish_activity("delete", boost) do
    boost = Bonfire.Repo.preload(boost, :boosted)

    with {:ok, booster} <- ActivityPub.Actor.get_cached_by_local_id(boost.booster_id),
         boosted when not is_nil(boosted) <- Bonfire.Common.Pointers.follow!(boost.boosted),
         object when not is_nil(boosted) <- Bonfire.Federate.ActivityPub.Utils.get_object(boosted) do
            ActivityPub.unannounce(booster, object)
    end
  end

  def ap_receive_activity(creator, %{data: %{"type" => "Announce"}} = _activity, object) do
    with {:ok, pointer} <- Bonfire.Common.Pointers.one(object.pointer_id),
         boosted = Bonfire.Common.Pointers.follow!(pointer) do
           boost(creator, boosted)
    end
  end

  def ap_receive_activity(creator, %{data: %{"type" => "Undo"}} = _activity, %{data: %{"object" => boosted_object}} = _object) do
    with object when not is_nil(object) <- ActivityPub.Object.get_cached_by_ap_id(boosted_object),
         {:ok, pointer} <- Bonfire.Common.Pointers.one(object.pointer_id),
         boosted <- Bonfire.Common.Pointers.follow!(pointer),
         [id] <- unboost(creator, boosted) do
          {:ok, id}
    end
  end
end
