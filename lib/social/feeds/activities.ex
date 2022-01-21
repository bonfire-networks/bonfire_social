defmodule Bonfire.Social.Activities do

  alias Bonfire.Data.Social.{Activity, Like, Boost, Flag, PostContent}
  alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries.Verbs
  import Bonfire.Common.Utils
  alias Bonfire.Social.FeedActivities
  import Ecto.Query
  require Logger
  import Bonfire.Boundaries.Queries

  use Bonfire.Repo,
    schema: Activity,
    searchable_fields: [:id, :subject_id, :verb_id, :object_id],
    sortable_fields: [:id, :subject_id, :verb_id, :object_id]

  def queries_module, do: Activity
  def context_module, do: Activity

  def as_permitted_for(q, opts \\ []) do
    if is_list(opts) and opts[:skip_boundary_check] do
      q
    else
      agent = current_user(opts) || current_account(opts)
      boundarise(q, activity.object_id, current_user: agent)
    end
  end

  def cast(changeset, verb, creator, preset) do
    verb_id = Verbs.get_id(verb) || Verbs.get_id!(:create)
    activity = %{
      subject_id: creator.id,
      verb_id: verb_id,
      feed_publishes: feed_publishes(changeset, creator, preset),
    }
    changeset
    |> put_in([:data, :activities], []) # force an insert
    |> Changeset.cast(%{activities: [activity]}, [])
    |> Changeset.cast_assoc(:activities)
  end

  defp feed_publishes(_activity, creator, preset) do
    creator = repo().preload(creator, character: :inbox)
    # TODO: let other people see it
    [creator.character.inbox.feed_id]
    |> Enum.map(&(%{feed_id: &1}))
  end

  @doc """
  Create an Activity
  NOTE: you will usually want to use `FeedActivities.publish/3` instead
  """
  def create(%{id: subject_id}=subject, verb, %{id: object_id}=object) when is_atom(verb) do
    verb_id = Verbs.get_id(verb) || Verbs.get_id!(:create)
    attrs = %{subject_id: subject_id, verb_id: verb_id, object_id: object_id}
    with {:ok, activity} <- repo().put(changeset(attrs)) do
       {:ok, %{activity | object: object, subject: subject}}
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


  def query_object_preload_create_activity(q, opts \\ [], preloads \\ :default) do
    query_object_preload_activity(q, :create, :id, opts, preloads)
  end

  def query_object_preload_activity(q, verb \\ :create, object_id_field \\ :id, opts \\ [], preloads \\ :default) do
    verb_id = Verbs.get_id!(verb)
    q
    |> reusable_join(:left, [o], activity in Activity, as: :activity, on: activity.object_id == field(o, ^object_id_field) and activity.verb_id == ^verb_id)
    |> activity_preloads(opts, preloads)
  end


  def activity_preloads(query, opts, preloads) when is_list(preloads) do
    #IO.inspect(preloads)
    Enum.reduce(preloads, query, fn preload, query ->
      query
      |> activity_preloads(opts, preload)
    end)
  end

  def activity_preloads(query, opts, :all) do
    query
      |> activity_preloads(opts, :with_parents)
      |> activity_preloads(opts, :with_creator)
      |> activity_preloads(opts, :default)
      # |> IO.inspect
  end

  def activity_preloads(query, _opts, :with_parents) do
    proload query,
      activity: [replied:
                 [reply_to:
                  {"reply_",
                   [:post_content,
                    created: [creator: {"creator_", [:profile, :character]}]]}]]
  end

  def activity_preloads(query, _opts, :with_creator) do
    proload query,
      activity: [object: {"object_", [created: [creator: [:profile, :character]]]}]
  end

  @default_activity_preloads [
    :verb, :boost_count, :like_count, :replied,
    object: {"object_", [:post_content]}
  ]

  def activity_preloads(query, opts, :default) do
    query
    |> activity_preloads(opts, :minimal)
    |> proload(activity: @default_activity_preloads)
    # |> IO.inspect(label: "activity with preloads")
  end

  def activity_preloads(query, _opts, :minimal) do
    proload query,
      activity: [subject: {"subject_", [:character, profile: :icon]}]
  end


  def activity_preloads(query, _opts, _) do
    query
  end


  @doc """
  Get an activity by its ID
  """
  def get(id, opts) when is_binary(id) do

    query([id: id], opts)
    |> repo().single()
  end

  @doc """
  Get an activity by its object ID (usually a create activity)
  """
  def read(query, opts \\ [])

  def read(object_id, opts) when is_binary(object_id) do

    read([object_id: object_id], opts)
  end

  def read(%Ecto.Query{} = query, %User{}=user), do: read(query, current_user: user)
  def read(%Ecto.Query{} = query, opts) do

    # IO.inspect(query: query, opts: opts)

    with {:ok, object} <- query
      |> query_object_preload_create_activity(opts, [:default, :with_parents])
      # |> IO.inspect
      |> as_permitted_for(opts)
      |> IO.inspect(label: "Activities.read query")
      |> repo().single() do

        # pubsub_subscribe(e(object, :activity, :replied, :thread_id, nil) || object.id, opts) # subscribe to realtime feed updates

        {:ok, object} #|> repo().maybe_preload(controlled: [acl: [grants: [access: [:interacts]]]]) |> IO.inspect
      end
  end

  def read(filters, opts) when is_map(filters) or is_list(filters) do

    current_user = current_user(opts)

    Activity
    |> query_filter(filters)
    |> read(opts)
  end

  def query(filters \\ [], opts_or_current_user \\ [])

  def query([my: :feed], opts_or_current_user) do
    # IO.inspect(filters: filters)
    current_user = current_user(opts_or_current_user)

    query([feed_id: ulid(current_user)], opts_or_current_user)
  end

  def query(filters, opts_or_current_user) do
    IO.inspect(filters: filters)
    # IO.inspect(opts_or_current_user: opts_or_current_user)

    FeedActivities.query(filters, opts_or_current_user, :all, from(a in Activity, as: :main_object) )
  end

  def activity_under_object(%{activity: %{object: _activity_object} = activity} = _top_object) do
    activity_under_object(activity) # TODO: merge top_object ?
  end
  def activity_under_object(%Activity{object: activity_object} = activity) do
    Map.put(activity_object, :activity, Map.drop(activity, [:object])) # ugly, but heh
  end
  def activity_under_object(%{} = object_without_activity) do
    Map.put(object_without_activity, :activity, %{})
  end
  def activity_under_object(%Activity{} = activity, %{}=object) do
    Map.put(object, :activity, activity)
  end

  def object_from_activity(%{object: %{post_content: %{id: _} = _content} = object}), do: object # no need to load Post object
  def object_from_activity(%{object: %Pointers.Pointer{id: _} = object}), do: load_object(object) # get other pointable objects (only as fallback, should normally already be preloaded)
  def object_from_activity(%{object: %{id: _} = object}), do: object # any other preloaded object
  def object_from_activity(%{object_id: id}), do: load_object(id) # last fallback, load any non-preloaded pointable object
  def object_from_activity(activity), do: activity

  def load_object(id_or_pointer) do
    with {:ok, obj} <- Bonfire.Common.Pointers.get(id_or_pointer, skip_boundary_check: true)
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
