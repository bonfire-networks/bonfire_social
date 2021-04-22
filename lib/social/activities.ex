defmodule Bonfire.Social.Activities do

  alias Bonfire.Data.Social.{Activity, Like, Boost, Flag}
  alias Bonfire.Boundaries.Verbs
  # import Bonfire.Me.Integration
  # import Ecto.Query
  import Bonfire.Boundaries.Queries
  use Bonfire.Repo.Query,
    schema: Activity,
    searchable_fields: [:id, :subject_id, :verb_id, :object_id],
    sortable_fields: [:id, :subject_id, :verb_id, :object_id]

  def as_permitted_for(q, user \\ nil) do

    cs = can_see?({:activity, :object_id}, user)

    q
    |> join(:left_lateral, [], cs in ^cs, as: :cs)
    |> where([cs: cs], cs.can_see == true)

  end

  @doc """
  Create an Activity
  NOTE: you will usually want to use `FeedActivities.publish/3` instead
  """
  def create(%{id: subject_id}=subject, verb, %{id: object_id}=object) when is_atom(verb) do

    verb_id = Verbs.verbs()[verb]

    attrs = %{subject_id: subject_id, verb_id: verb_id, object_id: object_id}

    with {:ok, activity} <- repo().put(changeset(attrs)) do
       {:ok, %{activity | object: object, subject: subject, subject_profile: Map.get(subject, :profile), subject_character: Map.get(subject, :character)}}
    end
  end

  def changeset(activity \\ %Activity{}, %{} = attrs) do
    Activity.changeset(activity, attrs)
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_by_subject_verb_object(%{}=subject, verb, %{}=object) do
    q = by_subject_verb_object_q(subject, Verbs.verbs()[verb], object)
    Bonfire.Social.FeedActivities.delete_for_object(repo().all(q)) # TODO: see why cascading delete doesn't take care of this
    elem(repo().delete_all(q), 1)
  end

  def by_subject_verb_object_q(%{id: subject}, verb, %{id: object}), do: by_subject_verb_object_q(subject, verb, object)

  def by_subject_verb_object_q(subject, verb, object) when is_binary(subject) and is_binary(object) do
    from f in Activity,
      where: f.subject_id == ^subject and f.object_id == ^object and f.verb_id == ^verb,
      select: f.id
  end

  def object_preload_create_activity(q, current_user, preloads \\ :default) do
    verb_id = Verbs.verbs()[:create]

    q
    |> join(:left, [o], activity in Activity, as: :activity, on: activity.object_id == o.id and activity.verb_id == ^verb_id)
    |> preload([activity], :activity)
    |> activity_preloads(current_user, preloads)
  end

  def activity_preloads(query, current_user, preloads) when is_list(preloads) do
    #IO.inspect(preloads)
    Enum.reduce(preloads, query, fn preload, query ->
      query
      |> activity_preloads(current_user, preload)
    end)
  end

  def activity_preloads(query, current_user, :all) do

    query
      |> activity_preloads(current_user, :with_parents)
      |> activity_preloads(current_user, :with_creator)
      |> activity_preloads(current_user, :default)
      # |> IO.inspect
  end

  def activity_preloads(query, _current_user, :with_parents) do

    query
      # |> join_preload([:activity, :replied, :reply_to])
      |> join_preload([:activity, :replied, :thread_post_content])
      |> join_preload([:activity, :replied, :reply_to_post_content])
      |> join_preload([:activity, :replied, :reply_to_created, :creator_profile])
      |> join_preload([:activity, :replied, :reply_to_created, :creator_character])
      # |> IO.inspect
  end

  def activity_preloads(query, _current_user, :with_creator) do

    query
      |> join_preload([:activity, :object_created, :creator_profile])
      |> join_preload([:activity, :object_created, :creator_character])
      # |> IO.inspect
  end

  def activity_preloads(query, current_user, :default) do

    query
      |> activity_preloads(current_user, :minimal)
      |> join_preload([:activity, :verb])
      |> join_preload([:activity, :boost_count])
      |> join_preload([:activity, :like_count])
      # |> join_preload([:activity, :object])
      |> join_preload([:activity, :object_message])
      # |> join_preload([:activity, :object_post])
      |> join_preload([:activity, :object_post_content])
      |> join_preload([:activity, :replied])
      |> maybe_my_like(current_user)
      |> maybe_my_boost(current_user)
      |> maybe_my_flag(current_user)
      # |> IO.inspect
  end

  def activity_preloads(query, _current_user, :minimal) do

    query
      |> join_preload([:activity, :subject_character])
      |> join_preload([:activity, :subject_profile])
      # |> IO.inspect
  end

  def maybe_my_like(q, %{id: current_user_id} = _current_user) do
    q
    # |> join_preload([:activity, :my_like], ass.liked_id == via.object_id and ass.liker_id == ^current_user_id) # TODO: figure out how to use bindings
    |> join(:left, [o, activity: activity], l in Like, as: :my_like, on: l.liked_id == activity.object_id and l.liker_id == ^current_user_id)
    |> preload([l, activity: activity, my_like: my_like], activity: {activity, [my_like: my_like]})
  end
  def maybe_my_like(q, _), do: q

  def maybe_my_boost(q, %{id: current_user_id} = _current_user) do
    q
    |> join(:left, [o, activity: activity], l in Boost, as: :my_boost, on: l.boosted_id == activity.object_id and l.booster_id == ^current_user_id)
    |> preload([l, activity: activity, my_boost: my_boost], activity: {activity, [my_boost: my_boost]})
  end
  def maybe_my_boost(q, _), do: q

  def maybe_my_flag(q, %{id: current_user_id} = _current_user) do
    q
    |> join(:left, [o, activity: activity], l in Flag, as: :my_flag, on: l.flagged_id == activity.object_id and l.flagger_id == ^current_user_id)
    |> preload([l, activity: activity, my_flag: my_flag], activity: {activity, [my_flag: my_flag]})
  end
  def maybe_my_flag(q, _), do: q

  # TODO: extensions can add types / routes
  def permalink(assigns \\ nil, activity_or_object)
  # def permalink(%{reply_to_thread_id: reply_to_thread_id}, %{object: %{id: id}}) do
  #   "/discussion/"<>reply_to_thread_id<>"/reply/"<>id
  # end
  def permalink(_, %{url: url}) when is_binary(url), do: url
  def permalink(_, %{object: %{} = obj}), do: permalink(obj)
  def permalink(_, %{object_post: %{id: id}}) when is_binary(id) do
    "/post/"<>id
  end
  def permalink(_, %Bonfire.Data.Social.Post{id: id}) when is_binary(id) do
    "/post/"<>id
  end
  def permalink(_, %Bonfire.Data.Social.PostContent{id: id}) when is_binary(id) do
    "/post/"<>id
  end
  def permalink(_, %{object_post_content: %{id: id}}) when is_binary(id) do
    "/post/"<>id
  end
  def permalink(_, %{object_message: %{id: id}}) when is_binary(id) do
    "/message/"<>id
  end
  def permalink(_, %{object_id: id}) when is_binary(id) do
    "/discussion/"<>id
  end
  def permalink(_, %{id: id}) when is_binary(id) do
    "/discussion/"<>id
  end
end
