defmodule Bonfire.Social.Activities do

  alias Bonfire.Data.Social.{Activity, Like, Boost, Flag, PostContent}
  alias Bonfire.Boundaries.Verbs
  import Bonfire.Common.Utils
  alias Bonfire.Social.FeedActivities
  import Ecto.Query
  require Logger
  import Bonfire.Boundaries.Queries

  use Bonfire.Repo.Query,
    schema: Activity,
    searchable_fields: [:id, :subject_id, :verb_id, :object_id],
    sortable_fields: [:id, :subject_id, :verb_id, :object_id]

  def queries_module, do: Activity
  def context_module, do: Activity

  def as_permitted_for(q, user \\ nil) do
    user = current_user(user)

    cs = can_see?({:activity, :object_id}, user)
    # perms = permitted_on({:activity, :object_id}, user)

    q
    |> join(:left_lateral, [], cs in ^cs, as: :cs)
    # |> join(:left_lateral, [], perms in ^perms, as: :perms)
    |> where([cs: cs], cs.can_see == true)

  end

  @doc """
  Create an Activity
  NOTE: you will usually want to use `FeedActivities.publish/3` instead
  """
  def create(%{id: subject_id}=subject, verb, %{id: object_id}=object) when is_atom(verb) do

    verb_id = Verbs.verbs()[verb] || Verbs.verbs()[:create]

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
    Bonfire.Social.FeedActivities.delete_for_object(repo().many(q)) # TODO: see why cascading delete doesn't take care of this
    elem(repo().delete_all(q), 1)
  end

  def by_subject_verb_object_q(%{id: subject}, verb, %{id: object}), do: by_subject_verb_object_q(subject, verb, object)

  def by_subject_verb_object_q(subject, verb, object) when is_binary(subject) and is_binary(object) do
    from f in Activity,
      where: f.subject_id == ^subject and f.object_id == ^object and f.verb_id == ^verb,
      select: f.id
  end


  def object_preload_create_activity(object, object_id_field \\ :id) do
    object_preload_activity(object, :create, object_id_field)
  end

  def object_preload_activity(object, verb \\ :create, object_id_field \\ :id) do
    verb_id = Verbs.verbs()[verb]

    query = from activity in Activity, as: :activity, where: activity.verb_id == ^verb_id
    repo().preload(object, [activity: query])
  end


  def query_object_preload_create_activity(q, current_user, preloads \\ :default) do
    query_object_preload_activity(q, :create, :id, current_user, preloads)
  end

  def query_object_preload_activity(q, verb \\ :create, object_id_field \\ :id, current_user \\ nil, preloads \\ :default) do
    verb_id = Verbs.verbs()[verb]

    q
    |> reusable_join(:left, [o], activity in Activity, as: :activity, on: activity.object_id == field(o, ^object_id_field) and activity.verb_id == ^verb_id)
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
    current_user = current_user(current_user)
    query
      |> activity_preloads(current_user, :minimal)
      |> join_preload([:activity, :verb])
      |> join_preload([:activity, :boost_count])
      |> join_preload([:activity, :like_count])
      |> join_preload([:activity, :object])
      # |> join_preload([:activity, :object_message])
      # |> join_preload([:activity, :object_post])
      |> join_preload([:activity, :object, :post_content])
      |> join_preload([:activity, :replied])
      |> maybe_my_like(current_user)
      |> maybe_my_boost(current_user)
      |> maybe_my_flag(current_user)
      # |> IO.inspect(label: "activity with preloads")
  end

  def activity_preloads(query, _current_user, :minimal) do

    query
      |> join_preload([:activity, :subject_character])
      |> join_preload([:activity, :subject_profile])
      |> join_preload([:activity, :subject_profile, :icon])
      # |> IO.inspect
  end


  def activity_preloads(query, _current_user, _) do
    query
  end

  def maybe_my_like(q, %{id: current_user_id} = _current_user) do
    q
    # |> join_preload([:activity, :my_like], ass.liked_id == via.object_id and ass.liker_id == ^current_user_id) # TODO: figure out how to use bindings in join_preload with ON
    |> reusable_join(:left, [o, activity: activity], l in Like, as: :my_like, on: l.liked_id == activity.object_id and l.liker_id == ^current_user_id)
    |> preload([l, activity: activity, my_like: my_like], activity: {activity, [my_like: my_like]})
  end
  def maybe_my_like(q, _), do: q

  def maybe_my_boost(q, %{id: current_user_id} = _current_user) do
    q
    |> reusable_join(:left, [o, activity: activity], l in Boost, as: :my_boost, on: l.boosted_id == activity.object_id and l.booster_id == ^current_user_id)
    |> preload([l, activity: activity, my_boost: my_boost], activity: {activity, [my_boost: my_boost]})
  end
  def maybe_my_boost(q, _), do: q

  def maybe_my_flag(q, %{id: current_user_id} = _current_user) do
    q
    |> reusable_join(:left, [o, activity: activity], l in Flag, as: :my_flag, on: l.flagged_id == activity.object_id and l.flagger_id == ^current_user_id)
    |> preload([l, activity: activity, my_flag: my_flag], activity: {activity, [my_flag: my_flag]})
  end
  def maybe_my_flag(q, _), do: q

  def read(query, socket_or_current_user \\ nil)

  def read(object_id, socket_or_current_user) when is_binary(object_id) do # note: we're fetching by object_id, and not activity.id

    read([object_id: object_id], socket_or_current_user)
  end

  def read(%Ecto.Query{} = query, socket_or_current_user) do

    IO.inspect(query: query)

    current_user = current_user(socket_or_current_user)

    with {:ok, object} <- query
      |> query_object_preload_create_activity(current_user, [:default, :with_parents])
      # |> IO.inspect
      |> as_permitted_for(current_user)
      # |> IO.inspect
      |> repo().single() do

        # pubsub_subscribe(e(object, :activity, :replied, :thread_id, nil) || object.id, socket_or_current_user) # subscribe to realtime feed updates

        {:ok, object} #|> repo().maybe_preload(controlled: [acl: [grants: [access: [:interacts]]]]) |> IO.inspect
      end
  end

  def read(filters, socket_or_current_user) when is_map(filters) or is_list(filters) do # note: we're fetching by object_id, and not activity.id

    current_user = current_user(socket_or_current_user)

    with {:ok, activity} <- Activity |> EctoShorts.filter(filters)
      |> read(socket_or_current_user) do

        {:ok, activity}
      end
  end

  def query(filters \\ [], opts_or_current_user \\ [])

  def query(filters, opts_or_current_user) do
    # IO.inspect(opts_or_current_user: opts_or_current_user)

    FeedActivities.query(filters, opts_or_current_user, :all, (from a in Activity, as: :main_object) )
  end

  def activity_under_object(%{activity: %{object: activity_object} = activity} = _top_object) do
    activity_under_object(activity) # TODO: merge top_object ?
  end
  def activity_under_object(%Activity{object: activity_object} = activity) do
    Map.put(activity_object, :activity, Map.drop(activity, [:object])) # ugly, but heh
  end

  def object_from_activity(%{object: %{post_content: %{id: _} = _content} = object}), do: object # no need to load Post object
  def object_from_activity(%{object: %Pointers.Pointer{id: _} = object}), do: load_object(object) # get other pointable objects (only as fallback, should normally already be preloaded)
  def object_from_activity(%{object: %{id: _} = object}), do: object # any other preloaded object
  def object_from_activity(%{object_id: id}), do: load_object(id) # last fallback, load any non-preloaded pointable object
  def object_from_activity(activity), do: activity

  def load_object(id_or_pointer) do
    with {:ok, obj} <- Bonfire.Common.Pointers.get(id_or_pointer)
      # |> IO.inspect
      # TODO: avoid so many queries
      |> repo().maybe_preload([:post_content])
      |> repo().maybe_preload([created: [:creator_profile, :creator_character]])
      |> repo().maybe_preload([:profile, :character]) do
        obj
      else
        # {:ok, obj} -> obj
        _ -> nil
      end
  end
end
