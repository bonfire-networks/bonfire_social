defmodule Bonfire.Social.Activities do

  use Arrows
  use Bonfire.Repo,
    schema: Activity,
    searchable_fields: [:id, :subject_id, :verb_id, :object_id],
    sortable_fields: [:id, :subject_id, :verb_id, :object_id]

  import Where
  use Bonfire.Common.Utils
  import Bonfire.Boundaries.Queries
  import Ecto.Query
  alias Bonfire.Data.Social.{Activity, Like, Boost, Flag, PostContent}
  alias Bonfire.Data.AccessControl.Verb
  alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Verbs
  alias Ecto.Changeset
  alias Bonfire.Social.{Feeds, FeedActivities}
  alias Pointers.{Changesets, Pointer, ULID}

  def queries_module, do: Activity
  def context_module, do: Activity

  def cast(changeset, verb, creator, opts) do
    verb_id = verb_id(verb)
    creator = repo().maybe_preload(creator, :character)
    #|> debug("creator")
    # debug(changeset)
    changeset
    |> put_assoc(verb, creator)
    |> FeedActivities.cast(opts[:feed_ids])
  end

  def put_assoc(changeset, verb, subject), do: put_assoc(changeset, verb, subject, changeset)
  def put_assoc(changeset, verb, subject, object) do
    verb = Changesets.set_state(struct(Verb, Verbs.get(verb)), :loaded)
    verb_id = verb.id
    %{subject_id: ulid(subject), object_id: ulid(object), verb_id: verb_id}
    |> Changesets.put_assoc(changeset, :activity, ...)
    |> Changeset.update_change(:activity, &put_verb(&1, verb))
  end

  def build_assoc(thing, verb, subject), do: build_assoc(thing, verb, subject, thing)
  def build_assoc(%Changeset{}=thing, verb, subject, object) do
    %{id: Changeset.get_field(thing, :id)}
    |> build_assoc(verb, subject, object)
  end
  def build_assoc(%{}=thing, verb, subject, object) do
    verb = Changesets.set_state(struct(Verb, Verbs.get(verb)), :loaded)
    verb_id = verb.id
    %{subject_id: ulid(subject), object_id: ulid(object), verb_id: verb_id}
    |> Ecto.build_assoc(thing, :activity, ...)
    |> Map.put(:verb, verb)
  end

  defp put_verb(changeset, verb), do: Changesets.update_data(changeset, &Map.put(&1, :verb, verb))

  def as_permitted_for(q, opts \\ [], verbs \\ [:see, :read]) do
    to_options(opts)
    |> Keyword.put_new(:verbs, verbs)
    |> boundarise(q, activity.object_id, ...)
  end

  @doc """
  Create an Activity
  NOTE: you will usually want to use `cast/3` instead
  """
  def create(subject, verb, object, activity_id \\ nil)
  def create(%{id: subject_id}=subject, verb, %{id: object_id}=object, activity_id) when  is_binary(subject_id) and is_binary(activity_id) and is_atom(verb) do
    verb_id = verb_id(verb)
    verb = Verbs.get(verb_id)
    attrs = %{id: activity_id, subject_id: subject_id, verb_id: verb_id, object_id: object_id} |> dump
    with {:ok, activity} <- repo().put(changeset(attrs)) do
       {:ok, %{activity | object: object, subject: subject, verb: verb}}
    end
  end
  def create(subject, verb, {object, %{id: id} = mixin_object}, _) do
    # dump(mixin_object, "mixin_object")
    create(subject, verb, object, id)
  end
  def create(subject, verb, %{id: id} = object, _) do
    # dump(object, "create_object")
    create(subject, verb, object, id)
  end

  defp changeset(activity \\ %Activity{}, %{} = attrs) do
    Activity.changeset(activity, attrs)
    |> Ecto.Changeset.cast(attrs, [:id])
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_by_subject_verb_object(%{}=subject, verb, %{}=object) do
    q = by_subject_verb_object_q(subject, Verbs.get_id!(verb), object)
    FeedActivities.delete_for_object(repo().many(q)) # TODO: see why cascading delete doesn't take care of this
    elem(repo().delete_all(q), 1)
  end

  def by_subject_verb_object_q(%{id: subject}, verb, %{id: object}), do: by_subject_verb_object_q(subject, verb, object)

  def by_subject_verb_object_q(subject, verb, object) when is_binary(subject) and is_binary(object) do
    from f in Activity,
      where: f.subject_id == ^subject and f.object_id == ^object and f.verb_id == ^verb,
      select: f.id
  end


  def object_preload_create_activity(object), do: object_preload_activity(object, :create)

  def object_preload_activity(object, verb \\ :create) do
    verb_id = verb_id(verb)
    query = from activity in Activity, as: :activity, where: activity.verb_id == ^verb_id
    repo().preload(object, [activity: query])
  end


  def query_object_preload_create_activity(q, opts \\ [], preloads \\ :default) do
    query_object_preload_activity(q, :create, :id, opts, preloads)
  end

  def query_object_preload_activity(q, verb \\ :create, object_id_field \\ :id, opts \\ [], preloads \\ :default) do
    verb_id = verb_id(verb)
    reusable_join(q, :left, [o],
      activity in Activity, as: :activity,
      on: activity.object_id == field(o, ^object_id_field) and activity.verb_id == ^verb_id
    )
    |> activity_preloads(opts, preloads)
  end


  def activity_preloads(query, opts, preloads) do
    case preloads do
      _ when is_list(preloads) ->
        Enum.reduce(preloads, query, &activity_preloads(&2, opts, &1))
      :all -> activity_preloads(query, opts, [:with_parents, :with_creator, :default])
      :with_parents ->
        # If the root replied to anything, fetch that and its creator too. e.g.
        # * Alice's post that replied to Bob's post
        # * Bob liked alice's post
         proload query,
           activity: [
             replied: [
               reply_to: {"reply_", [
                 :post_content,
                 created: [creator: {"creator_", [:character, profile: :icon]}],
               ]}
             ]
           ]
      :with_creator ->
        # This actually loads the creator of the object:
        # * In the case of a post, creator of the post
        # * In the case of like of a post, creator of the post
        proload query,
          created:  [creator: [:character, profile: :icon]],
          activity: [object: {"object_", [created: [creator: [:character, profile: :icon]]]}]
      :minimal ->
        # Subject here is standing in for the creator of the root. One day it may be replaced with it.
        proload query, activity: [subject: {"subject_", [:character, profile: :icon]}]
      :minimum -> # ???
        proload query, activity: [:object]
      :default ->
        proload query, activity: [:verb, :replied, object: {"object_", [:post_content, :peered]}]
      _ ->
        warn(preloads, "Unknown preload specification")
        query
    end
  end

  @doc """
  Get an activity by its ID
  """
  def get(id, opts) when is_binary(id), do: repo().single(query([id: id], opts))

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
    |> as_permitted_for(opts, [:read])
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
    FeedActivities.query(filters, opts_or_current_user, from(a in Activity, as: :main_object) )
  end

  # this is a hack to mimic the old structure of the data provided to
  # the activity component, which will we refactor soon(tm)
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
  def activity_under_object({:ok, %{} = object}) do
    {:ok, activity_under_object(object)}
  end

  def activity_under_object(%Activity{} = activity, %{}=object) do
    Map.put(object, :activity, activity)
  end


  def object_from_activity(%{object: %{edge: %{object: %{id: _} = object}}}), do: object |> repo().maybe_preload([:post_content]) |> repo().maybe_preload([:profile, :character]) # special case for edges (eg. Boost) coming to us via LivePush - FIXME: do this somewhere else and use Feed preload functions
  def object_from_activity(%{object: %{post_content: %{id: _} = _content} = object}), do: object # no need to load Post object
  def object_from_activity(%{object: %Pointers.Pointer{id: _} = object}), do: load_object(object) # get other pointable objects (only as fallback, should normally already be preloaded)
  def object_from_activity(%{object: %{id: _} = object}), do: object # any other preloaded object
  def object_from_activity(%{activity: activity}), do: object_from_activity(activity)
  def object_from_activity(%{object_id: id}), do: load_object(id) # last fallback, load any non-preloaded pointable object
  def object_from_activity(%Pointers.Pointer{id: _} = object), do: load_object(object) # get other pointable objects (only as fallback, should normally already be preloaded)
  def object_from_activity(object_or_activity), do: object_or_activity

  def load_object(id_or_pointer) do
    with {:ok, obj} <- Bonfire.Common.Pointers.get(id_or_pointer, skip_boundary_check: true)
      |> debug
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


  def verb(verb) when is_atom(verb), do: verb
  def verb(%{verb: %{verb: verb}}), do: verb
  def verb(%{verb_id: id}), do: Bonfire.Boundaries.Verbs.get_slug(id)

  def verb_maybe_modify("request", _), do: "request to follow" # FIXME: temporary as we may later request other things
  def verb_maybe_modify("create", %{replied: %{reply_to: %{post_content: %{id: _}} = _reply_to}}), do: "reply"
  def verb_maybe_modify("create", %{replied: %{reply_to: %{id: _} = _reply_to}}), do: "respond"
  def verb_maybe_modify("create", %{replied: %{reply_to_id: reply_to_id}}) when is_binary(reply_to_id), do: "respond"
  # def verb_maybe_modify("created", %{reply_to: %{id: _} = reply_to, object: %Bonfire.Data.Social.Post{}}), do: reply_to_display(reply_to)
  # def verb_maybe_modify("created", %{reply_to: %{id: _} = reply_to}), do: reply_to_display(reply_to)
  def verb_maybe_modify("create", %{object: %{post_content: %{id: _}}}), do: "write"
  def verb_maybe_modify("create", %{object: %Bonfire.Data.Social.PostContent{}}), do: "write"
  def verb_maybe_modify("create", %{object: %Bonfire.Data.Social.Post{} = _post}), do: "write"
  def verb_maybe_modify("create", %{object: %Bonfire.Data.Social.Message{}}), do: "send"
  def verb_maybe_modify("create", %{object: %{action: %{label: label}} = _economic_event}), do: label
  def verb_maybe_modify("create", %{object: %{action: %{id: id}} = _economic_event}), do: id
  def verb_maybe_modify("create", %{object: %{action_id: label} = _economic_event}) when is_binary(label), do: label
  def verb_maybe_modify("create", %{object: %{action: label} = _economic_event}) when is_binary(label), do: label
  def verb_maybe_modify(%{verb: verb}, activity) when is_binary(verb), do: verb |> String.downcase() |> verb_maybe_modify(activity)
  def verb_maybe_modify(%{verb: verb}, activity), do: verb_maybe_modify(verb, activity)
  def verb_maybe_modify(verb, activity) when is_atom(verb), do: maybe_to_string(verb) |> String.downcase() |> verb_maybe_modify(activity)
  def verb_maybe_modify(verb, _) when is_binary(verb), do:  verb |> String.downcase()

  def verb_display(verb) do
    verb = maybe_to_string(verb)
    case String.split(verb) do
      [verb, "to", other_verb] -> Enum.join([verb_congugate(verb), "to", other_verb], " ")
      _ -> verb_congugate(verb)
    end
  end

  defp verb_congugate(verb) do
    :"Elixir.Verbs".conjugate(verb, tense: "past", person: "third", plurality: "plural")
  end

  defp verb_id(verb) when is_binary(verb), do: verb
  defp verb_id(verb) when is_atom(verb), do: Verbs.get_id(verb) || Verbs.get_id!(:create)

end
