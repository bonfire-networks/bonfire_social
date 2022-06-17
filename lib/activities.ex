defmodule Bonfire.Social.Activities do

  use Arrows
  use Bonfire.Common.Repo,
    schema: Activity,
    searchable_fields: [:id, :subject_id, :verb_id, :object_id],
    sortable_fields: [:id, :subject_id, :verb_id, :object_id]

  import Where
  use Bonfire.Common.Utils
  import Bonfire.Boundaries.Queries
  import Ecto.Query
  alias Bonfire.Data.Social.{Activity, Like, Boost, Flag, PostContent, Seen}
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Data.AccessControl.Verb
  alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Verbs
  alias Ecto.Changeset
  alias Bonfire.Social.{Edges, Feeds, FeedActivities}
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
    # |> Changeset.update_change(:activity, &put_data(&1, :subject, maybe_to_struct(subject, Pointers.Pointer)))
    |> Changeset.update_change(:activity, &put_data(&1, :verb, verb))
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

  defp put_data(changeset, key, value), do: Changesets.update_data(changeset, &Map.put(&1, key, value))

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
    # info(mixin_object, "mixin_object")
    create(subject, verb, object, id)
  end
  def create(subject, verb, %{id: id} = object, _) do
    # info(object, "create_object")
    create(subject, verb, object, id)
  end

  defp changeset(activity \\ %Activity{}, %{} = attrs) do
    Activity.changeset(activity, attrs)
    |> Ecto.Changeset.cast(attrs, [:id])
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_by_subject_verb_object(%{}=subject, verb, %{}=object) do
    q = by_subject_verb_object_q(subject, Verbs.get_id!(verb), object)
    FeedActivities.delete(repo().many(q)) # TODO: see why cascading delete doesn't take care of this
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

  def query_object_preload_create_activity(q, opts \\ []) do
    query_object_preload_activity(q, :create, :id, opts)
  end

  def query_object_preload_activity(q, verb \\ :create, object_id_field \\ :id, opts \\ [])
  def query_object_preload_activity(q, :create, object_id_field, opts) do
    q
    |> reusable_join(:left, [o],
      activity in Activity, as: :activity,
      on: activity.id == field(o, ^object_id_field)
    )
    |> activity_preloads(opts)
  end

  def query_object_preload_activity(q, verb, object_id_field, opts) do
    verb_id = verb_id(verb)
    q
    |> reusable_join(:left, [o],
      activity in Activity, as: :activity,
      on: activity.object_id == field(o, ^object_id_field) and activity.verb_id == ^verb_id
    )
    |> activity_preloads(opts)
  end

  # def preload_seen(object, opts) do # TODO
  #   user = current_user(opts)
  #   if user do
  #     preload_query = from seen in Seen, as: :activity_seen, where: activity.id == seen.object_id and seen.subject_id == ^user
  #     repo().preload(object, [activity: [seen: preload_query]])
  #   else
  #     q
  #   end
  # end

  defp query_preload_seen(q, opts) do
    user_id = ulid(current_user(opts))
    if user_id do
      table_id = Edges.table_id(Seen)
      q
      |> reusable_join(:left, [activity: activity],
        seen_edge in Edge, as: :seen,
        on: activity.id == seen_edge.object_id and seen_edge.table_id == ^table_id and seen_edge.subject_id == ^user_id
      )
      |> preload([activity: activity, seen: seen], [activity: {activity, seen: seen}])
    else
      q
    end
  end

  defp subquery_preload_seen(opts) do
    user_id = ulid(current_user(opts) |> debug())
    if user_id do
      table_id = Edges.table_id(Seen)
      from(seen_edge in Edge, where: seen_edge.table_id == ^table_id and seen_edge.subject_id == ^user_id)
    end
  end

  def activity_preloads(query, opts) do
    activity_preloads(query, opts[:preload], opts)
  end

  def activity_preloads(query, preloads, opts) when is_list(preloads) do
    debug(query, "query or data")
    debug(preloads, "preloads")
    if not is_nil(query) and Ecto.Queryable.impl_for(query) do
      Enum.reduce(preloads, query, &do_activity_preloads(&2, &1, opts))
    else
      all_preloads = Enum.flat_map(preloads, &do_activity_preloads(nil, &1, opts))
      |> debug("accumulated preloads to try")
      maybe_repo_preload(query, all_preloads, opts)
    end
  end

  def activity_preloads(query, preloads, opts) do
    activity_preloads(query, [preloads], opts)
  end

  defp do_activity_preloads(query, preloads, opts) when is_list(preloads) do
    debug(preloads)
    if not is_nil(query) and Ecto.Queryable.impl_for(query) do
      Enum.reduce(preloads, query, &do_activity_preloads(&2, &1, opts))
    else
      Enum.flat_map(preloads, &do_activity_preloads(nil, &1, opts))
      |> debug("subset from preset")
    end
  end

  defp do_activity_preloads(query, preloads, opts) when preloads in [:all, :feed, :feed_metadata, :notifications, :posts, :posts_with_reply_to, :default] do
    # shorthand presets
    debug(preloads)
    case preloads do
      :all -> do_activity_preloads(query, [
          :feed, :tags
        ], opts)
      :feed -> do_activity_preloads(query, [
          :with_subject, :with_creator, :with_verb, :with_object_more, :with_reply_to, :with_thread_name, :with_media
        ], opts)
      :feed_metadata -> do_activity_preloads(query, [
          :with_subject, :with_creator, :with_verb, :with_reply_to, :with_thread_name, :with_media
        ], opts)
      :notifications ->
        do_activity_preloads(query, [
          :feed, :with_seen
        ], opts)
      :posts_with_reply_to -> do_activity_preloads(query, [
          :with_subject, :with_object_posts, :with_reply_to
        ], opts)
      :posts -> do_activity_preloads(query, [
          :with_subject, :with_object_posts, :with_replied, :with_thread_name
        ], opts)
      _default -> do_activity_preloads(query, [
          :with_subject, :with_verb, :with_object_posts, :with_replied
        ], opts)
    end
  end

  defp do_activity_preloads(query, preload, opts) when is_atom(preload) do
    debug(preload)
    if not is_nil(query) and Ecto.Queryable.impl_for(query) do
      case preload do
        :with_creator ->
          # This actually loads the creator of the object:
          # * In the case of a post, creator of the post
          # * In the case of like of a post, creator of the post
          # TODO: in feeds, maybe load the creator with a where clause to skip it when creator==subject
          proload query,
            # created:  [creator: [:character, profile: :icon]],
            activity: [object: {"object_", [created: [creator: [:character, profile: :icon]]]}]
        # :tags ->
        #   # Tags/mentions (this actual needs to be done by Repo.preload to be able to list more than one)
        #   proload query,
        #     activity: [tags:  {"tag_", [:character, profile: :icon]}]
        :with_subject ->
          # Subject here is standing in for the creator of the root. One day it may be replaced with it.
          proload query, activity: [subject: {"subject_", [:character, profile: :icon]}]
        :with_verb ->
          proload query, activity: [:verb]
        :with_object ->
          proload query, activity: [:object]
        :with_object_posts ->
          proload query, activity: [
            :replied,
            object: {"object_", [:post_content, :peered]}
          ]
        :with_object_more ->
          proload query, activity: [
            :replied,
            object: {"object_", [:post_content, :peered, :character, profile: :icon]}
          ]
        :with_replied ->
          proload query, activity: [:replied]
        :with_thread_name ->
          proload query, activity: [replied: [thread: [:named]]]
        :with_reply_to ->
        # If the root replied to anything, fetch that and its creator too. e.g.
        # * Alice's post that replied to Bob's post
        # * Bob liked alice's post
         proload query,
           activity: [
             replied: [
               reply_to: {"reply_", [
                 :post_content,
                 created: [creator: {"reply_to_creator_", [:character, profile: :icon]}],
               ]}
             ]
           ]
        :with_media ->
          query
          # proload query, activity: [:media] # FYI: proloading media only queries one attachment
        :with_seen ->
          query_preload_seen(query, opts)
    end
  else
    case preload do
      :with_creator ->
        # This actually loads the creator of the object:
        # * In the case of a post, creator of the post
        # * In the case of like of a post, creator of the post
        [object: [created: [creator: [:character, profile: :icon]]]]
      :tags ->
        # Tags/mentions (this actual needs to be done by Repo.preload to be able to list more than one)
        [tags:  [:character, profile: :icon]]
      :with_subject ->
        # Subject here is standing in for the creator of the root. One day it may be replaced with it.
        [subject: [:character, profile: :icon]]
      :with_verb ->
        [:verb]
      :with_object ->
        [:object]
      :with_object_posts ->
        [
          :replied,
          object: [:post_content, :peered]
        ]
      :with_object_more ->
        [
          :replied,
          object: [:post_content, :peered, :character, profile: :icon]
        ]
      :with_replied ->
        [:replied]
      :with_thread_name ->
        [replied: [thread: [:named]]]
      :with_reply_to ->
        # If the root replied to anything, fetch that and its creator too. e.g.
        # * Alice's post that replied to Bob's post
        # * Bob liked alice's post
           [
             replied: [
               reply_to: [
                 :post_content,
                 created: [creator: [:character, profile: :icon]],
               ]
             ]
           ]
        :with_media ->
          [:media]
        :with_seen ->
          subquery = subquery_preload_seen(opts)
          if subquery, do: [seen: subquery], else: []
      end
    end
  end


  defp maybe_repo_preload(%{edges: list} = page, preloads, opts) when is_list(list) do
    cased_maybe_repo_preload(List.first(list), page, preloads, opts)
  end
  defp maybe_repo_preload(list, preloads, opts) when is_list(list) do
    cased_maybe_repo_preload(List.first(list), list, preloads, opts)
  end
  defp maybe_repo_preload(object, preloads, opts) do
    cased_maybe_repo_preload(nil, object, preloads, opts)
  end

  defp cased_maybe_repo_preload(example_object, objects, preloads, opts) do
    debug(example_object)
    case example_object || objects do
      %Bonfire.Data.Social.Activity{} ->
        do_maybe_repo_preload(objects, List.wrap(preloads), opts)

      %{activity: _} ->
        do_maybe_repo_preload(objects, [activity: preloads], opts)

      # _ ->
      #   error(objects, "Could not preload activity data")
      #   objects
    end
  end

  defp do_maybe_repo_preload(objects, preloads, opts) do
    opts
    |> Keyword.put_new(:follow_pointers, false)
    |> repo().maybe_preload(objects, preloads, ...)
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
    opts = to_options(opts)
    # debug(opts, "opts")
    query
    # |> debug("base query")
    |> query_object_preload_create_activity(opts ++ [preload: [:default, :with_reply_to]])
    # |> debug("activity query")
    |> as_permitted_for(opts, [:read])
    # |> debug("permitted query")
    |> repo().single()
    #  #|> repo().maybe_preload(controlled: [acl: [grants: [access: [:interacts]]]])
    # |> IO.inspect
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


  def object_from_activity(%{object: %{edge: %{object: %{id: _} = object}}}), do: object |> repo().maybe_preload([:post_content, :profile, :character]) # special case for edges (eg. Boost) coming to us via LivePush - FIXME: do this somewhere else and use Feed preload functions
  def object_from_activity(%{object: %{post_content: %{id: _} = _content} = object}), do: object # no need to load Post object
  # def object_from_activity(%{object: %Pointers.Pointer{id: _} = object}), do: load_object(object) # get other pointable objects (only as fallback, should normally already be preloaded)
  def object_from_activity(%{object: %{id: _} = object}), do: object # any other preloaded object
  def object_from_activity(%{activity: activity}), do: object_from_activity(activity)
  def object_from_activity(%{object_id: id}), do: load_object(id) # last fallback, load any non-preloaded pointable object
  # def object_from_activity(%Pointers.Pointer{id: _} = object), do: load_object(object) # get other pointable objects (only as fallback, should normally already be preloaded)
  def object_from_activity(object_or_activity), do: object_or_activity

  def load_object(id_or_pointer) do
    with {:ok, obj} <- Bonfire.Common.Pointers.get(id_or_pointer, skip_boundary_check: true)
      |> debug
      # TODO: avoid so many queries
      # |> repo().maybe_preload([:post_content])
      # |> repo().maybe_preload([created: [:creator_profile, :creator_character]])
      # |> repo().maybe_preload([:profile, :character])
      do
        obj
      else
        # {:ok, obj} -> obj
        _ -> nil
      end
  end

  # TODO: put in Verbs module
  def verb_name(slug) when is_atom(slug), do: Bonfire.Boundaries.Verbs.get(slug)[:verb]
  def verb_name(%{verb: %{verb: verb}}), do: verb
  def verb_name(%{verb_id: id}), do: Bonfire.Boundaries.Verbs.get(id)[:verb]
  def verb_name(%{verb: verb}) when is_binary(verb), do: verb

  def verb_maybe_modify("Request", _), do: "Request to Follow" # FIXME: temporary as we may later request other things
  def verb_maybe_modify("Create", %{replied: %{reply_to: %{post_content: %{id: _}} = _reply_to}}), do: "Reply"
  def verb_maybe_modify("Create", %{replied: %{reply_to: %{id: _} = _reply_to}}), do: "Respond"
  def verb_maybe_modify("Create", %{replied: %{reply_to_id: reply_to_id}}) when is_binary(reply_to_id), do: "Respond"
  # def verb_maybe_modify("Created", %{reply_to: %{id: _} = reply_to, object: %Bonfire.Data.Social.Post{}}), do: reply_to_display(reply_to)
  # def verb_maybe_modify("Created", %{reply_to: %{id: _} = reply_to}), do: reply_to_display(reply_to)
  def verb_maybe_modify("Create", %{object: %{post_content: %{id: _}}}), do: "Write"
  def verb_maybe_modify("Create", %{object: %Bonfire.Data.Social.PostContent{}}), do: "Write"
  def verb_maybe_modify("Create", %{object: %Bonfire.Data.Social.Post{} = _post}), do: "Write"
  def verb_maybe_modify("Create", %{object: %Bonfire.Data.Social.Message{}}), do: "Send"
  def verb_maybe_modify("Create", %{object: %{action: %{label: label}} = _economic_event}), do: label
  def verb_maybe_modify("Create", %{object: %{action: %{id: id}} = _economic_event}), do: id
  def verb_maybe_modify("Create", %{object: %{action_id: label} = _economic_event}) when is_binary(label), do: label
  def verb_maybe_modify("Create", %{object: %{action: label} = _economic_event}) when is_binary(label), do: label
  # def verb_maybe_modify(%{verb: verb}, activity) when is_binary(verb), do: verb |> verb_maybe_modify(activity)
  def verb_maybe_modify(%{verb: verb}, activity), do: verb_maybe_modify(verb, activity)
  def verb_maybe_modify(verb, activity) when is_atom(verb), do: maybe_to_string(verb) |> verb_maybe_modify(activity)
  def verb_maybe_modify(verb, _) when is_binary(verb), do: verb
  #|> String.downcase()

  def verb_display(verb) do
    verb = maybe_to_string(verb)
    case String.split(verb) do
      # FIXME: support localisation
      [verb, "to", other_verb] -> Enum.join([verb_congugate(verb), "to", other_verb], " ")
      _ -> verb_congugate(verb)
    end
    |> localise_dynamic(__MODULE__)
    |> String.downcase()
  end

  def verb_congugate(verb) do
    :"Elixir.Verbs".conjugate(verb, tense: "past", person: "third", plurality: "plural")
  end

  def verb_id(verb) when is_binary(verb), do: ulid(verb) || Verbs.get_id(maybe_to_atom(verb))
  def verb_id(verb) when is_atom(verb), do: Verbs.get_id(verb) || Verbs.get_id!(:create)

  @doc """
  Outputs the names all object verbs, for the purpose of adding to the localisation strings, as long as the output is piped through to localise_strings/1 at compile time.
  """
  def all_verb_names() do
    # Bonfire.Boundaries.Verbs.verbs()
    case Bonfire.Common.Config.get(:verbs) do
      verbs when is_map(verbs) ->
        verbs
        |> Map.values()
        |> Enum.flat_map(fn v ->
          [v[:verb]]
        end)
      _ ->
        Bonfire.Common.Config.get!(:verb_names)
    end
  end

  def all_verb_names_extra() do
    all_verb_names()
    |> Enum.flat_map(fn v ->
      conjugated = v
      |> Bonfire.Social.Activities.verb_congugate()
      |> sanitise_verb_name()

      [v, "Request to "<>v, "Requested to "<>v, conjugated, conjugated<>" by %{user}"]
    end)
    # |> IO.inspect(label: "Making all verb names localisable")
  end

  defp sanitise_verb_name("Editted"), do: "Edited" # workaround `Verbs` bug
  defp sanitise_verb_name(verb), do: verb
end
