defmodule Bonfire.Social.Activities do

  use Arrows
  use Bonfire.Repo,
    schema: Activity,
    searchable_fields: [:id, :subject_id, :verb_id, :object_id],
    sortable_fields: [:id, :subject_id, :verb_id, :object_id]

  require Logger
  use Bonfire.Common.Utils
  import Bonfire.Boundaries.Queries
  import Ecto.Query
  alias Bonfire.Data.Social.{Activity, Like, Boost, Flag, PostContent}
  alias Bonfire.Data.AccessControl.Verb
  alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries
  alias Bonfire.Social.FeedActivities
  alias Pointers.ULID

  def queries_module, do: Activity
  def context_module, do: Activity

  def as_permitted_for(q, opts \\ []) do
    boundarise(q, activity.object_id, opts)
  end

  def cast(changeset, verb, creator, preset_or_custom_boundary) do
    verb_id = Boundaries.Verbs.get_id(verb) || Boundaries.Verbs.get_id!(:create)
    creator = repo().maybe_preload(creator, :character)
    #|> debug("creator")
    id = ULID.generate() # le sigh, it's just easier this way
    activity = %{
      id: id,
      subject_id: creator.id,
      verb_id: verb_id
    } # publish in appropriate feeds
    |> Map.put(..., :feed_publishes, FeedActivities.cast_data(changeset, ..., creator, preset_or_custom_boundary))
    # |> debug("activity attrs")
    changeset
    |> Map.update(:data, nil, &Map.put(&1, :activities, [])) # force an insert
    |> Changeset.cast(%{activities: [activity]}, [])
    |> Changeset.cast_assoc(:activities, with: &Activity.changeset/2)
    # |> Map.update(:data, nil, &Map.put(&1, :activity, activity)) # force an insert
    # |> debug("changeset")
  end



  @doc """
  Create an Activity
  NOTE: you will usually want to use `cast/3` instead
  """
  def create(%{id: subject_id}=subject, verb, %{id: object_id}=object) when is_atom(verb) do
    verb_id = Boundaries.Verbs.get_id(verb) || Boundaries.Verbs.get_id!(:create)
    attrs = %{subject_id: subject_id, verb_id: verb_id, object_id: object_id}
    with {:ok, activity} <- repo().put(changeset(attrs)) do
       {:ok, %{activity | object: object, subject: subject, verb: %Verb{verb: verb}}}
    end
  end

  def changeset(activity \\ %Activity{}, %{} = attrs) do
    Activity.changeset(activity, attrs)
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_by_subject_verb_object(%{}=subject, verb, %{}=object) do
    q = by_subject_verb_object_q(subject, Boundaries.Verbs.get_id!(verb), object)
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
    verb_id = Boundaries.Verbs.get_id(verb)

    query = from activity in Activity, as: :activity, where: activity.verb_id == ^verb_id
    repo().preload(object, [activity: query])
  end


  def query_object_preload_create_activity(q, opts \\ [], preloads \\ :default) do
    query_object_preload_activity(q, :create, :id, opts, preloads)
  end

  def query_object_preload_activity(q, verb \\ :create, object_id_field \\ :id, opts \\ [], preloads \\ :default) do
    verb_id = Boundaries.Verbs.get_id(verb)
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
    :verb, :replied,
    # :boost_count, :like_count, # preload these in the view instead
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

  def read(object_id, opts) when is_binary(object_id), do: read([object_id: object_id], opts)
  def read(%Ecto.Query{} = query, %User{}=user), do: read(query, current_user: user)
  def read(%Ecto.Query{} = query, opts) do
    # debug(opts, "opts")
    query
    # |> debug("base query")
    |> query_object_preload_create_activity(opts, [:default, :with_parents])
    # |> debug("activity query")
    |> as_permitted_for(opts)
    # |> debug("permitted query")
    |> repo().single()
    # # pubsub_subscribe(e(object, :activity, :replied, :thread_id, nil) || object.id, opts) # subscribe to realtime feed updates
    #  #|> repo().maybe_preload(controlled: [acl: [grants: [access: [:interacts]]]]) |> IO.inspect
  end

  def read(filters, opts) when is_map(filters) or is_list(filters) do
    current_user = current_user(opts)
    Activity
    |> query_filter(filters)
    |> read(opts)
  end

  def query(filters \\ [], opts_or_current_user \\ [])

  def query([my: :feed], opts_or_current_user) do
    current_user = current_user(opts_or_current_user)
    query([feed_id: ulid(current_user)], opts_or_current_user)
  end

  def query(filters, opts_or_current_user) do
    # debug(filters, "filters")
    # debug(opts_or_current_user, "opts or user")
    FeedActivities.query(filters, opts_or_current_user, :all, from(a in Activity, as: :main_object) )
  end

  def activity_under_object(%{activity: %{object: %{id: _} = object} = activity} = top_object) do
    activity_under_object(activity, Map.merge(top_object, object))
  end
  def activity_under_object(%{activity: %{id: _} = activity} = top_object) do
    activity_under_object(activity, top_object)
  end
  def activity_under_object(%{activities: [%{id: _} = activity]} = top_object) do
    activity_under_object(activity, Map.drop(top_object, [:activities]))
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

  def verb_maybe_modify("create", %{replied: %{reply_to_post_content: %{id: _} = _reply_to}}), do: "reply"
  def verb_maybe_modify("create", %{replied: %{reply_to: %{id: _} = _reply_to}}), do: "respond"
  def verb_maybe_modify("create", %{replied: %{reply_to_id: reply_to_id}}) when is_binary(reply_to_id), do: "respond"
  # def verb_maybe_modify("created", %{reply_to: %{id: _} = reply_to, object: %Bonfire.Data.Social.Post{}}), do: reply_to_display(reply_to)
  # def verb_maybe_modify("created", %{reply_to: %{id: _} = reply_to}), do: reply_to_display(reply_to)
  def verb_maybe_modify("create", %{object: %Bonfire.Data.Social.PostContent{name: name} = post}), do: "write" #<> object_link(name, post)
  def verb_maybe_modify("create", %{object: %Bonfire.Data.Social.PostContent{} = _post}), do: "write"
  def verb_maybe_modify("create", %{object: %Bonfire.Data.Social.Post{} = _post}), do: "write"
  def verb_maybe_modify("create", %{object: %{action: %{label: label}} = _economic_event}), do: label
  def verb_maybe_modify("create", %{object: %{action: %{id: id}} = _economic_event}), do: id
  def verb_maybe_modify("create", %{object: %{action_id: label} = _economic_event}) when is_binary(label), do: label
  def verb_maybe_modify("create", %{object: %{action: label} = _economic_event}) when is_binary(label), do: label
  def verb_maybe_modify(verb, _), do: verb

  def verb_display(verb) when is_atom(verb), do: Atom.to_string(verb) |> verb_display()
  def verb_display(verb) do
    verb
      |> Verbs.conjugate(tense: "past", person: "third", plurality: "plural")
  end
end
