defmodule Bonfire.Social.Activities do
  use Arrows
  use Untangle
  use Bonfire.Common.Utils

  use Bonfire.Common.Repo,
    schema: Activity,
    searchable_fields: [:id, :subject_id, :verb_id, :object_id],
    sortable_fields: [:id, :subject_id, :verb_id, :object_id]

  import Bonfire.Boundaries.Queries
  import Ecto.Query
  alias Bonfire.Data.Social.Activity
  # alias Bonfire.Data.Social.FeedPublish
  # alias Bonfire.Data.Social.Like
  # alias Bonfire.Data.Social.Boost
  # alias Bonfire.Data.Social.Flag
  # alias Bonfire.Data.Social.PostContent
  # alias Bonfire.Data.Social.Replied
  alias Bonfire.Data.Social.Seen

  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Data.AccessControl.Verb
  alias Bonfire.Data.Identity.User
  # alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Verbs
  alias Ecto.Changeset
  # alias Bonfire.Social.Edges
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedActivities

  alias Needle.Changesets
  alias Needle.Pointer
  # alias Needle.ULID

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Activity
  def query_module, do: __MODULE__

  def cast(changeset, verb, creator, opts) do
    # verb_id = verb_id(verb)
    creator = repo().maybe_preload(creator, :character)
    # |> debug("creator")
    # debug(changeset)
    changeset
    |> put_assoc(verb, creator)
    |> FeedActivities.cast(opts[:feed_ids])

    # |> debug("csss")
  end

  def put_assoc(changeset, verb, subject),
    do: put_assoc(changeset, verb, subject, changeset)

  def put_assoc(changeset, verb, subject, object) do
    verb = Changesets.set_state(struct(Verb, Verbs.get(verb)), :loaded)
    verb_id = verb.id

    %{subject_id: ulid(subject), object_id: ulid(object), verb_id: verb_id}
    |> Changesets.put_assoc!(changeset, :activity, ...)
    # |> Changeset.update_change(:activity, &put_data(&1, :subject, maybe_to_struct(subject, Needle.Pointer)))
    |> Changeset.update_change(:activity, &put_data(&1, :verb, verb))

    # |> Changeset.update_change(:activity, &put_data(&1, :subject, subject))
    # |> Changeset.update_change(:activity, &put_data(&1, :object, object))
  end

  def build_assoc(thing, verb, subject),
    do: build_assoc(thing, verb, subject, thing)

  def build_assoc(%Changeset{} = thing, verb, subject, object) do
    build_assoc(%{id: Changeset.get_field(thing, :id)}, verb, subject, object)
  end

  def build_assoc(%{} = thing, verb, subject, object) do
    verb = Changesets.set_state(struct(Verb, Verbs.get(verb)), :loaded)
    verb_id = verb.id

    %{subject_id: ulid(subject), object_id: ulid(object), verb_id: verb_id}
    |> Ecto.build_assoc(thing, :activity, ...)
    |> Map.put(:verb, verb)
  end

  defp put_data(changeset, key, value),
    do: Changesets.update_data(changeset, &Map.put(&1, key, value))

  def as_permitted_for(q, opts \\ [], verbs \\ [:see, :read]) do
    to_options(opts)
    |> Keyword.put_new(:verbs, verbs)
    |> boundarise(q, activity.object_id, ...)
  end

  def reply_to_as_permitted_for(q, opts \\ [], verbs \\ [:see, :read]) do
    to_options(opts)
    |> Keyword.put_new(:verbs, verbs)
    |> boundarise(q, replied.reply_to_id, ...)
  end

  @doc """
  Create an Activity
  NOTE: you will usually want to use `cast/3` instead or maybe `Objects.publish/5`
  """
  def create(subject, verb, object, activity_id \\ nil)

  def create(
        %{id: subject_id} = subject,
        verb,
        %{id: object_id} = object,
        activity_id
      )
      when is_binary(subject_id) and is_binary(activity_id) do
    verb_id = verb_id(verb || :create)
    verb = Verbs.get(verb_id)

    attrs =
      debug(%{
        id: activity_id,
        subject_id: subject_id,
        verb_id: verb_id,
        object_id: object_id
      })

    with {:ok, activity} <- repo().upsert(changeset(attrs)) do
      {:ok, %{activity | object: object, subject: subject, verb: verb}}
    end
  rescue
    e in Ecto.ConstraintError ->
      error(e, "Could not save the Activity")
      # TODO: get Activity instead?
      {:ok, object}

    e ->
      error(e, "Could not save the Activity")
  end

  def create(subject, verb, {object, %{id: id} = _mixin_object}, _) do
    # info(mixin_object, "mixin_object")
    create(subject, verb, object, id)
  end

  def create(%{id: _id} = subject, verb, %{id: id} = object, _) do
    # info(object, "create_object")
    create(subject, verb, object, id)
  end

  defp changeset(activity \\ %Activity{}, %{} = attrs) do
    Activity.changeset(activity, attrs)
    |> Ecto.Changeset.cast(attrs, [:id])
  end

  @doc "Delete an activity (usage by things like unlike)"
  def delete_by_subject_verb_object(subject, verb, object) do
    q = by_subject_verb_object_q(subject, Verbs.get_id!(verb), object)
    # FIXME? does cascading delete take care of this?
    FeedActivities.delete(repo().many(q), :id)
    # TODO? maybe_remove_for_deleters_feeds(id)
    elem(repo().delete_all(q), 1)
  end

  @doc "Delete activities, using specific filters"
  def delete(id) when is_binary(id) or is_struct(id) do
    # maybe_remove_for_deleters_feeds(id)
    delete({:id, id})
  end

  def delete(filters) when is_list(filters) or is_tuple(filters) do
    q =
      Activity
      |> query_filter(filters)
      |> debug("gonna delete")

    # FIXME? does cascading delete take care of this?
    FeedActivities.delete(repo().many(q), :id)

    q
    |> repo().delete_many()
    |> elem(0)
  end

  def delete_object(id) when is_binary(id) or is_struct(id) do
    # maybe_remove_for_deleters_feeds(id)
    delete({:object_id, id})
  end

  def maybe_remove_for_deleters_feeds(id) do
    # TODO: use pubsub to send the deletion to all feeds / connected users, not just the current one
    # FIXME: only if socket is connected
    maybe_apply(Bonfire.Social.Feeds.LiveHandler, :remove_activity, id)
  end

  def by_subject_verb_object_q(subject, verb, object)
      when is_binary(verb) do
    from(f in Activity,
      where:
        f.subject_id == ^ulid!(subject) and f.object_id == ^ulid!(object) and
          f.verb_id == ^verb,
      select: f.id
    )
  end

  def object_preload_create_activity(object),
    do: object_preload_activity(object, :create)

  def object_preload_activity(object, verb \\ :create) do
    verb_id = verb_id(verb)

    query =
      from(activity in Activity,
        as: :activity,
        where: activity.verb_id == ^verb_id
      )

    repo().preload(object, activity: query)
  end

  def query_object_preload_create_activity(q, opts \\ []) do
    query_object_preload_activity(q, :create, :id, opts)
  end

  def query_object_preload_activity(
        q,
        verb \\ :create,
        object_id_field \\ :id,
        opts \\ []
      )

  def query_object_preload_activity(q, :create, object_id_field, opts) do
    q
    |> reusable_join(:left, [o], activity in Activity,
      as: :activity,
      on: activity.id == field(o, ^object_id_field)
    )
    |> activity_preloads(opts)
  end

  def query_object_preload_activity(q, verb, object_id_field, opts) do
    verb_id = verb_id(verb)

    q
    |> reusable_join(:left, [o], activity in Activity,
      as: :activity,
      on:
        activity.object_id == field(o, ^object_id_field) and
          activity.verb_id == ^verb_id
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
      table_id = Bonfire.Common.Types.table_id(Seen)

      q
      |> reusable_join(:left, [activity: activity], seen_edge in Edge,
        as: :seen,
        on:
          activity.id == seen_edge.object_id and seen_edge.table_id == ^table_id and
            seen_edge.subject_id == ^user_id
      )
      |> preload([activity: activity, seen: seen],
        activity: {activity, seen: seen}
      )
    else
      q
    end
  end

  defp subquery_preload_seen(opts) do
    user_id = ulid(current_user(opts))

    if user_id do
      table_id = Bonfire.Common.Types.table_id(Seen)

      from(seen_edge in Edge,
        where: seen_edge.table_id == ^table_id and seen_edge.subject_id == ^user_id
      )
    end
  end

  def activity_preloads(query, opts) do
    opts = to_options(opts)
    activity_preloads(query, opts[:preload], opts)
  end

  def activity_preloads([], _, _) do
    debug("skip because we have an empty list")
    []
  end

  def activity_preloads(query, preloads, opts) when is_list(preloads) do
    # debug(query, "query or data")
    debug(preloads, "preloads")
    opts = to_options(opts)

    if not is_nil(query) and Ecto.Queryable.impl_for(query) do
      do_activity_preloads(query, preloads, opts)
      |> debug("accumulated proloads included in query")
    else
      do_activity_preloads(nil, preloads, opts)
      |> debug("accumulated postloads to try")
      |> maybe_repo_preload_activity(query, ..., opts)

      # |> debug()
    end
  end

  def activity_preloads(query, false, _opts) do
    query
  end

  def activity_preloads(query, preloads, opts) do
    activity_preloads(query, [preloads], opts)
  end

  defp do_activity_preloads(query, preloads, opts) when is_list(preloads) do
    # debug(preloads, "preloads list")

    if not is_nil(query) and Ecto.Queryable.impl_for(query) do
      preloads
      |> Enum.uniq()
      |> Enum.reduce(query, &do_activity_preloads(&2, &1, opts))
    else
      preloads
      |> Enum.uniq()
      |> Enum.flat_map(&do_activity_preloads(nil, &1, opts))
    end
  end

  defp do_activity_preloads(query, preloads, opts)
       when preloads in [
              :all,
              :feed,
              :feed_postload,
              :feed_metadata,
              :feed_by_subject,
              :feed_by_creator,
              :notifications,
              :posts,
              :posts_with_thread,
              :posts_with_reply_to,
              :default
            ] do
    # shorthand presets
    # debug(preloads)

    case preloads do
      :all ->
      
          [
            :feed,
            :tags
          ]

      :thread_postload ->
      
          [
            # :with_subject,
            # :feed_by_subject,
            :with_replied,
            :with_object_more
          ]

      :feed ->
       
          [
            :with_subject,
            :feed_by_subject,
            :with_replied
          ]

      :feed_postload ->
      
          [
            :with_thread_name,
            :with_reply_to,
            :with_media,
            :with_parent,
            :maybe_with_labelled
          ]

      :feed_metadata ->
       
          [
            :with_subject,
            :with_creator,
            # :with_verb,
            # :with_reply_to,
            :with_thread_name
            # :with_media
          ]

      :feed_by_subject ->
       
          [
            :with_creator,
            # :with_verb,
            :feed_by_creator
          ]

      :feed_by_creator ->
        
          [
            :with_object_more,
            # :with_reply_to,
            # :with_thread_name,
            :with_media
          ]

      :notifications ->
   
          [
            :feed_by_subject,
            :with_reply_to,
            :with_seen
          ]

      :posts_with_reply_to ->
    
          [
            :with_subject,
            :with_object_posts
            # :with_reply_to # do not preload as part of query because will be preloaded async later
          ]

      :posts_with_thread ->
   
          [
            :with_subject,
            :with_object_posts,
            :with_replied,
            :with_thread_name
          ]

      :posts ->

          [
            :with_subject,
            :with_object_posts
          ]

      _default ->

          [
            :with_subject,
            # :with_verb,
            :with_object_posts,
            :with_replied
          ]
    end
    |> debug("computed preloads")
    |> do_activity_preloads(
          query,
          ...,
          opts
        )
  end

  defp do_activity_preloads(query, preload, opts) when is_atom(preload) do

    if not is_nil(query) and Ecto.Queryable.impl_for(query) do
      current_user_id = current_user_id(opts)
      subject_user_id = id(opts[:subject_user])
      exclude_user_ids = [current_user_id, subject_user_id] |> filter_empty([])

      case preload do
        :with_creator ->
          # This actually loads the creator of the object:
          # * In the case of a post, creator of the post
          # * In the case of like of a post, creator of the post
          # TODO: in feeds, maybe load the creator with a where clause to skip it when creator==subject
          query
          # |> proload(activity: [:object])
          |> proload(
            activity: [
              object:
                {"object_",
                 [
                   :created
                 ]}
            ]
          )
          |> maybe_join_creator(exclude_user_ids)

        # :tags ->
        #   # Tags/mentions (this actual needs to be done by Repo.preload to be able to list more than one)
        #   proload query,
        #     activity: [tags:  {"tag_", [:character, profile: :icon]}]
        :with_subject ->
          query
          |> maybe_join_subject(exclude_user_ids)

        :with_verb ->
          proload(query, activity: [:verb])

        :with_object ->
          proload(query, activity: [:object])

        :with_object_posts ->
          proload(query,
            activity: [
              :sensitive,
              object: {"object_", [:post_content, :peered]}
            ]
          )

        :with_object_more ->
          proload(query,
            activity: [
              :sensitive,
              object: {"object_", [:post_content, :peered, :character, profile: :icon]}
            ]
          )

        :with_replied ->
          proload(query, activity: [:replied])

        :with_thread_name ->
          proload(query, activity: [replied: [thread: [:named]]])

        :with_parent ->
          # TODO: make proload check if the schema module of an assoc is enabled to avoid having to add conditionals like this?
          if Extend.module_enabled?(Bonfire.Classify.Tree, opts),
            do: proload(query, activity: [tree: [parent: [:profile, :character]]]),
            else: query

        :with_reply_to ->
          # If the root replied to anything, fetch that and its creator too. e.g.
          # * Alice's post that replied to Bob's post
          # * Bob liked alice's post

          # reply_query = fn reply_to_ids -> Bonfire.Common.Needles.list!(reply_to_ids, opts ++ [preload: [
          #            :post_content,
          #            :creator_of_reply_to
          #          ]]) end

          debug("reply_to should be preloaded with custom query so boundaries can be applied")

          if is_struct(query, Ecto.Query) and
               Enum.any?(query.preloads, fn
                 {:activity,
                  [
                    replied: [
                      reply_to: _
                    ]
                  ]} ->
                   true

                 other ->
                   debug(other)
                   false
               end) do
            warn("reply_to is already being preloaded")
            query
          else
            query
            |> proload(activity: [:replied])
            |> preload(
              activity: [
                replied: [
                  reply_to: ^maybe_preload_reply_to(opts)
                ]
              ]
            )
            |> debug("with reply_to")
          end

        # |> Ecto.Query.preload([activity: {activity, [replied: ^reply_query]}])
        # |> proload(
        #   activity: [
        #     replied: [
        #       reply_to:
        #         {"reply_",
        #          [
        #            :post_content,
        #            created: [
        #              creator: {"reply_to_creator_", [:character, profile: :icon]}
        #            ]
        #          ]}
        #     ]
        #   ]
        # )
        # |> Ecto.Query.preload([activity: {activity, [replied: {replied, [reply_to: ^reply_query]}]}])
        # |> proload(activity: [replied: [reply_to: ^reply_query]] )

        # proload(query,
        #   activity: [
        #     replied: [
        #       reply_to:
        #         {"reply_",
        #          [
        #            :post_content,
        #            created: [
        #              creator: {"reply_to_creator_", [:character, profile: :icon]}
        #            ]
        #          ]}
        #     ]
        #   ]
        # )

        :tags ->
          query

          query
          |> proload(activity: [tags: [:character, profile: :icon]])

        :with_media ->
          query
          |> proload(activity: [:sensitive])
          # use preload instead of proload because there can be many media
          |> preload(activity: [:media])

        :per_media ->
          query
          |> proload(activity: [:sensitive])
          |> proload(:inner, activity: [:media])
          |> distinct([media: media], desc: media.id)

        :maybe_with_labelled ->
          if Extend.extension_enabled?(:bonfire_label),
            do:
              query
              |> proload(
                activity: [labelled: {"labelled_", [:post_content, :media, subject: [:profile]]}]
              ),
            else: query

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
          [tags: [:character, profile: :icon]]

        :with_subject ->
          # Subject here is standing in for the creator of the root. One day it may be replaced with it.
          [subject: [:character, profile: :icon]]

        :with_verb ->
          [:verb]

        :with_object ->
          [:object]

        :with_object_posts ->
          [
            # :replied,
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

        :with_parent ->
          debug("with_parent!")

          if Extend.module_enabled?(Bonfire.Classify.Tree, opts),
            do: [tree: [parent: [:profile, :character]]],
            else: []

        :with_reply_to ->
          [
            replied: [
              reply_to: maybe_preload_reply_to(opts)
            ]
          ]

        :with_media ->
          [:media, :sensitive]

        :maybe_with_labelled ->
          if Extend.module_enabled?(Bonfire.Label, opts),
            do: [labelled: [:post_content, :media, subject: [:profile]]],
            else: []

        :with_seen ->
          subquery = subquery_preload_seen(opts)
          if subquery, do: [seen: subquery], else: []
      end
    end
  end

  defp maybe_preload_reply_to(opts) do
    # If the root replied to anything, fetch that and its creator too. e.g.
    # * Alice's post that replied to Bob's post
    # * Bob liked alice's post

    Common.Needles.pointer_query(
      [],
      Enums.merge_uniq(opts,
        skip_boundary_check: false
        # preload: [:with_content, :creator_of_reply_to]
      )
    )
    |> preload(
      # [{"reply_to_",
      [
        :post_content,
        :peered,
        created: [
          creator: [:character, profile: :icon]
        ]
      ]
      # }]
    )
    |> debug("query to attempt loading reply_to")

    # |> debug("reply_query subquery that applies boundaries")

    # (from reply_to in Pointer)
    # |> proload([
    #            :post_content,
    #            created: [
    #              creator: {"reply_to_creator_", [:character, profile: :icon]}
    #            ]
    #     ]
    # )
    # |> Activities.reply_to_as_permitted_for(opts)
  end

  def maybe_join_subject(query, []),
    do:
      query
      |> proload(
        activity: [
          subject:
            {"subject_",
             [
               character: [
                 # :peered
               ],
               profile: [:icon]
             ]}
        ]
      )

  def maybe_join_subject(query, exclude_user_ids) do
    # optimisation: only includes the subject if different current_user
    query
    |> proload([:activity])
    |> reusable_join(
      :left,
      [activity: activity],
      subject in Pointer,
      as: :subject,
      on:
        activity.subject_id not in ^exclude_user_ids and
          activity.subject_id == subject.id
    )
    |> proload(
      activity: [
        subject:
          {"subject_",
           [
             character: [
               # :peered
             ],
             profile: [:icon]
           ]}
      ]
    )
  end

  @doc "query optimisation: only includes the subject if different from subject or current_user"
  def maybe_join_creator(query, []) do
    query
    #  join subject, since creator will only be loaded if different from the subject
    |> maybe_join_subject([])
    |> proload(
      activity: [
        object:
          {"object_",
           [
             :created
           ]}
      ]
    )
    |> reusable_join(
      :left,
      [activity: activity, object_created: object_created],
      creator in Pointer,
      as: :object_creator,
      #  only includes the creator if different than the subject
      on:
        object_created.creator_id != activity.subject_id and
          object_created.creator_id == creator.id
    )
    |> proload(
      activity: [
        object:
          {"object_",
           [
             # reusable_join should mean the above is respected and the creator mixins are only loaded when needed
             created: [
               creator:
                 {"creator_",
                  [
                    character: [
                      # :peered
                    ],
                    profile: [:icon]
                  ]}
             ]
           ]}
      ]
    )
  end

  def maybe_join_creator(query, exclude_user_ids) do
    query
    #  join subject, since creator will only be loaded if different from the subject
    |> maybe_join_subject(exclude_user_ids)
    |> proload(
      activity: [
        object:
          {"object_",
           [
             :created
           ]}
      ]
    )
    |> reusable_join(
      :left,
      [activity: activity, object_created: object_created],
      creator in Pointer,
      as: :object_creator,
      #  only includes the creator if different than the subject
      on:
        object_created.creator_id != activity.subject_id and
          object_created.creator_id not in ^exclude_user_ids and
          object_created.creator_id == creator.id
    )
    |> proload(
      activity: [
        object:
          {"object_",
           [
             # reusable_join should mean the above is respected and the creator mixins are only loaded when needed
             created: [
               creator:
                 {"creator_",
                  [
                    character: [
                      # :peered
                    ],
                    profile: [:icon]
                  ]}
             ]
           ]}
      ]
    )
  end

  defp maybe_repo_preload_activity(%{edges: list} = page, preloads, opts)
       when is_list(list) do
    # pages
    maybe_repo_preload_activity_cases(List.first(list), page, preloads, opts)
  end

  defp maybe_repo_preload_activity(list, preloads, opts) when is_list(list) and list != [] do
    maybe_repo_preload_activity_cases(List.first(list), list, preloads, opts)
  end

  defp maybe_repo_preload_activity(%{} = object, preloads, opts) do
    maybe_repo_preload_activity_cases(nil, object, preloads, opts)
  end

  defp maybe_repo_preload_activity(object, _preloads, _opts) do
    warn(object, "Could not recognise activity object(s) to preload activity assoc")
    object
  end

  defp maybe_repo_preload_activity_cases(example_object, objects, preloads, opts) do
    # debug(example_object)

    case example_object || objects do
      %Bonfire.Data.Social.Activity{} ->
        debug("preload with Activity")
        do_maybe_repo_preload(objects, List.wrap(preloads), opts)

      %Bonfire.Data.Edges.Edge{} ->
        debug(
          "preload with Edge (special case possible as long as we declare all the same assocs as Activity)"
        )

        do_maybe_repo_preload(objects, List.wrap(preloads), opts)

      %{activity: _, __struct__: _} = _map ->
        debug("activity within a parent struct")
        do_maybe_repo_preload(objects, [activity: preloads], opts)

      %{activity: %{__struct__: _} = _activity} = _map ->
        # if is_list(objects) do
        debug("list of maps with activities")
        do_maybe_repo_preload(objects, [activity: preloads], opts)

      # else
      #   debug("activity within a map")
      #   do_maybe_repo_preload(objects, [activity: preloads], opts)
      #   Map.put(map, :activity, do_maybe_repo_preload(activity, List.wrap(preloads), opts))
      # end

      _ ->
        warn(objects, "Could not preload activity data")
        objects
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
  def read(query, opts \\ []),
    do:
      read_query(query, opts)
      |> as_permitted_for(opts, [:read])
      |> repo().single()

  def read_query(query, opts \\ [])

  def read_query(object_id, opts) when is_binary(object_id),
    do: read_query([object_id: object_id], opts)

  def read_query(%Ecto.Query{} = query, %User{} = user),
    do: read_query(query, current_user: user)

  def read_query(%Ecto.Query{} = query, opts) do
    opts = to_options(opts)
    # debug(opts, "opts")
    query
    |> debug("base query")
    |> query_object_preload_create_activity(
      Keyword.put_new(opts, :preload, [:default, :with_media, :with_reply_to, :with_parent])
    )
    |> debug("activity query")

    # |> debug("permitted query")

    #  #|> repo().maybe_preload(controlled: [acl: [grants: [access: [:interacts]]]])
    # |> IO.inspect
  end

  def read_query(filters, opts) when is_map(filters) or is_list(filters) do
    # current_user = current_user(opts)
    Activity
    |> query_filter(filters)
    |> read_query(opts)
  end

  def query(filters \\ [], opts_or_current_user \\ [])

  def query([my: :feed], opts_or_current_user) do
    current_user = current_user_required!(opts_or_current_user)
    query([feed_id: ulid(current_user)], opts_or_current_user)
  end

  def query(filters, opts_or_current_user) do
    # debug(filters, "filters")
    # debug(opts_or_current_user, "opts or user")
    FeedActivities.query(
      filters,
      opts_or_current_user,
      from(a in Activity, as: :main_object)
    )
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
    Map.put(activity_object, :activity, Map.drop(activity, [:object]))
  end

  def activity_under_object(%{} = object_without_activity) do
    Map.put(object_without_activity, :activity, %{})
  end

  def activity_under_object({:ok, %{} = object}) do
    {:ok, activity_under_object(object)}
  end

  def activity_under_object(%Activity{} = activity, %{} = object) do
    Map.put(object, :activity, activity)
  end

  def activity_with_object_from_assigns(%{activity: %{object: %{id: _}} = activity} = _assigns) do
    activity
  end

  def activity_with_object_from_assigns(
        %{activity: %{} = activity, object: %{id: _} = object} = _assigns
      ) do
    debug("Activity with both an activity and object")

    Map.put(
      activity,
      :object,
      object
    )
  end

  def activity_with_object_from_assigns(%{activity: %{} = activity} = assigns) do
    debug("Activity without :object as assoc")

    object_under_activity(activity, assigns[:object])
  end

  def activity_with_object_from_assigns(%{object: %{} = _object} = assigns) do
    debug("Activity with only an object")

    e(assigns[:object], :activity, nil) ||
      %Activity{
        subject:
          e(assigns[:object], :created, :creator, nil) || e(assigns[:object], :creator, nil),
        object: assigns[:object]
      }
  end

  def activity_with_object_from_assigns(_), do: nil

  def object_under_activity(%{object: %{id: _}} = activity, nil) do
    activity
  end

  def object_under_activity(activity, nil) do
    activity
    # |> Map.put(
    #   :object,
    #   Activities.object_from_activity(activity) # risk of n+1
    # )
  end

  def object_under_activity(%{} = activity, object) do
    activity
    |> Map.put(
      :object,
      object
    )
  end

  def object_under_activity(activity, _) do
    activity
  end

  @decorate time()
  def object_from_activity(activity)

  # special case for edges (eg. Boost) coming to us via LivePush
  # FIXME: do this somewhere else and use Feed preload functions
  def object_from_activity(%{object: %{edge: %{object: %{id: _} = object}}}),
    do: repo().maybe_preload(object, [:post_content, :profile, :character])

  # no need to load Post object
  def object_from_activity(%{
        object: %{post_content: %{id: _} = _content} = object
      }),
      do: object

  # get other pointable objects (only as fallback for unknown object types, most objects should already be preloaded by `Bonfire.Social.Feeds.LiveHandler.preload/2`)
  def object_from_activity(%{object: %Needle.Pointer{id: _} = object}),
    do: load_object(object, skip_boundary_check: true)

  # any other preloaded object
  def object_from_activity(%{object: %{id: _} = object}), do: object

  def object_from_activity(%{activity: activity}),
    do: object_from_activity(activity)

  # last fallback, load any non-preloaded pointable object
  def object_from_activity(%{object_id: id}), do: load_object(id, skip_boundary_check: true)

  # def object_from_activity(%Needle.Pointer{id: _} = object), do: load_object(object, skip_boundary_check: true) # get other pointable objects (only as fallback, should normally already be preloaded)
  def object_from_activity(object_or_activity), do: object_or_activity

  def load_object(id_or_pointer, opts \\ []) do
    # TODO: avoid so many queries
    # |> repo().maybe_preload([:post_content])
    # |> repo().maybe_preload([created: [:creator_profile, :creator_character]])
    # |> repo().maybe_preload([:profile, :character])
    with {:ok, obj} <-
           Bonfire.Common.Needles.get(id_or_pointer, opts) do
      obj
    else
      # {:ok, obj} -> obj
      _ -> nil
    end
  end

  # TODO: put in Verbs module
  def verb_name(slug) when is_atom(slug),
    do: Bonfire.Boundaries.Verbs.get(slug)[:verb]

  def verb_name(%{verb: %{verb: verb}}), do: verb
  def verb_name(%{verb_id: id}), do: Bonfire.Boundaries.Verbs.get(id)[:verb]
  def verb_name(%{verb: verb}) when is_binary(verb), do: verb

  # @decorate time()
  def verb_maybe_modify(verb, activity \\ nil)

  # FIXME: temporary as we may later request other things
  def verb_maybe_modify("Request", _), do: "Request to Follow"

  def verb_maybe_modify("Create", %{
        replied: %{reply_to: %{post_content: %{id: _}} = _reply_to}
      }),
      do: "Reply"

  def verb_maybe_modify("Create", %{replied: %{reply_to: %{id: _} = _reply_to}}),
    do: "Respond"

  def verb_maybe_modify("Create", %{replied: %{reply_to_id: reply_to_id}})
      when is_binary(reply_to_id),
      do: "Respond"

  # def verb_maybe_modify("Created", %{reply_to: %{id: _} = reply_to, object: %Bonfire.Data.Social.Post{}}), do: reply_to_display(reply_to)
  # def verb_maybe_modify("Created", %{reply_to: %{id: _} = reply_to}), do: reply_to_display(reply_to)
  def verb_maybe_modify("Create", %{object: %{post_content: %{id: _}}}),
    do: "Write"

  def verb_maybe_modify("Create", %{object: %Bonfire.Data.Social.PostContent{}}),
    do: "Write"

  def verb_maybe_modify("Create", %{object: %Bonfire.Data.Social.Post{} = _post}),
    do: "Write"

  def verb_maybe_modify("Create", %{object: %Bonfire.Data.Social.Message{}}),
    do: "Send"

  def verb_maybe_modify("Create", %{
        object: %{action: %{label: label}} = _economic_event
      }),
      do: label

  def verb_maybe_modify("Create", %{
        object: %{action: %{id: id}} = _economic_event
      }),
      do: id

  def verb_maybe_modify("Create", %{
        object: %{action_id: label} = _economic_event
      })
      when is_binary(label),
      do: label

  def verb_maybe_modify("Create", %{object: %{action: label} = _economic_event})
      when is_binary(label),
      do: label

  # def verb_maybe_modify(%{verb: verb}, activity) when is_binary(verb), do: verb |> verb_maybe_modify(activity)
  def verb_maybe_modify(%{verb: verb}, activity),
    do: verb_maybe_modify(verb, activity)

  def verb_maybe_modify(verb, activity) when is_atom(verb),
    do: maybe_to_string(verb) |> verb_maybe_modify(activity)

  def verb_maybe_modify(verb, activity) when is_binary(verb) do
    if is_ulid?(verb) do
      verb_maybe_modify(Bonfire.Boundaries.Verbs.get!(verb)[:verb], activity)
    else
      verb
    end
  end

  # |> String.downcase()

  # @decorate time()
  def verb_display(verb) do
    verb = maybe_to_string(verb)

    case String.split(verb) do
      # FIXME: support localisation
      [verb, "to", other_verb] ->
        Enum.join([verb_congugate(verb), "to", other_verb], " ")

      _ ->
        verb_congugate(verb)
    end
    |> localise_dynamic(__MODULE__)
    |> String.downcase()
  end

  def verb_congugate(verb) do
    :"Elixir.Verbs".conjugate(verb,
      tense: "past",
      person: "third",
      plurality: "plural"
    )
  end

  def verb_id(verb) when is_binary(verb),
    do: ulid(verb) || Verbs.get_id(maybe_to_atom(verb))

  def verb_id(verb) when is_atom(verb),
    do: Verbs.get_id(verb) || Verbs.get_id!(:create)

  @doc """
  Outputs the names all object verbs, for the purpose of adding to the localisation strings, as long as the output is piped through to localise_strings/1 at compile time.
  """
  def all_verb_names() do
    # Bonfire.Boundaries.Verbs.verbs()
    case Bonfire.Common.Config.get(:verbs, nil, :bonfire) do
      verbs when is_map(verbs) or (is_list(verbs) and verbs != []) ->
        verbs
        |> Enum.flat_map(fn {_key, data} ->
          List.wrap(data[:verb])
        end)

      other ->
        debug(other, ":verbs list not found in Config, fallback to :verb_names")
        Bonfire.Common.Config.get!([:verb_names])
    end
  end

  def all_verb_names_extra() do
    Enum.flat_map(all_verb_names(), fn v ->
      conjugated =
        v
        |> Bonfire.Social.Activities.verb_congugate()
        |> sanitise_verb_name()

      [
        v,
        "Request to " <> v,
        "Requested to " <> v,
        conjugated,
        conjugated <> " by"
      ]
    end)

    # |> IO.inspect(label: "Making all verb names localisable")
  end

  # workaround `Verbs` bug
  defp sanitise_verb_name("Editted"), do: "Edited"
  defp sanitise_verb_name(verb), do: verb

  def count_total(), do: repo().one(select(Activity, [u], count(u.id)))

  def query_order(query, :num_replies, sort_order) do
    if sort_order == :asc do
      query
      |> proload(:activity)
      |> order_by(
        [activity: activity, replied: replied],
        asc_nulls_first: replied.total_replies_count,
        asc: activity.id
      )
    else
      query
      |> proload(:activity)
      |> order_by(
        [activity: activity, replied: replied],
        # [desc_nulls_last: replied.nested_replies_count, desc: replied.id]
        desc_nulls_last: replied.total_replies_count,
        desc: activity.id
      )
    end
  end

  # def query_order(query, :num_replies, sort_order) do
  #   if sort_order == :asc do
  #     query
  #     |> proload(:activity)
  #     |> order_by(
  #       [activity: activity, replied: replied],
  #       asc_nulls_first:
  #         fragment(
  #           "?+?",
  #           replied.nested_replies_count,
  #           replied.direct_replies_count
  #         ),
  #       asc: activity.id
  #     )
  #   else
  #     query
  #     |> proload(:activity)
  #     |> order_by(
  #       [activity: activity, replied: replied],
  #       # [desc_nulls_last: replied.nested_replies_count, desc: replied.id]
  #       desc_nulls_last:
  #         fragment(
  #           "?+?",
  #           replied.nested_replies_count,
  #           replied.direct_replies_count
  #         ),
  #       desc: activity.id
  #     )
  #   end
  # end

  def query_order(query, :num_boosts, sort_order) do
    if sort_order == :asc do
      query
      |> proload(activity: [:boost_count])
      |> order_by([activity: activity, boost_count: boost_count],
        asc_nulls_first: boost_count.object_count,
        asc: activity.id
      )
    else
      query
      |> proload(activity: [:boost_count])
      |> order_by([activity: activity, boost_count: boost_count],
        desc_nulls_last: boost_count.object_count,
        desc: activity.id
      )
    end
  end

  def query_order(query, :num_likes, sort_order) do
    if sort_order == :asc do
      query
      |> proload(activity: [:like_count])
      |> order_by([activity: activity, like_count: like_count],
        asc_nulls_first: like_count.object_count,
        asc: activity.id
      )
    else
      query
      |> proload(activity: [:like_count])
      |> order_by([activity: activity, like_count: like_count],
        desc_nulls_last: like_count.object_count,
        desc: activity.id
      )
    end
  end

  def query_order(query, _, sort_order) do
    if sort_order == :asc do
      query
      |> proload(:activity)
      |> order_by([activity: activity], activity.id)
    else
      query
      |> proload(:activity)
      |> order_by([activity: activity], desc: activity.id)
    end
  end

  def order_pagination_opts(sort_by, sort_order) do
    # [cursor_fields: [{{:activity, :id}, sort_order}]]
    [
      cursor_fields: order_cursor_fields(sort_by, sort_order || :desc),
      fetch_cursor_value_fun: &fetch_cursor_value_fun/2
    ]
  end

  def fetch_cursor_value_fun(%{nested_replies_count: _} = replied, :num_replies) do
    debug(:num_replies)
    e(replied, :nested_replies_count, 0) + e(replied, :direct_replies_count, 0)
  end

  def fetch_cursor_value_fun(%{replied: %{id: _} = replied}, :num_replies) do
    debug(:num_replies)
    e(replied, :nested_replies_count, 0) + e(replied, :direct_replies_count, 0)
  end

  def fetch_cursor_value_fun(%{activity: %{replied: %{id: _} = replied}}, :num_replies) do
    debug(:num_replies)
    e(replied, :nested_replies_count, 0) + e(replied, :direct_replies_count, 0)
  end

  def fetch_cursor_value_fun(d, list) when is_tuple(list) do
    debug(list, "with list")
    apply(Utils, :e, [d] ++ Tuple.to_list(list) ++ [nil])
  end

  def fetch_cursor_value_fun(d, field) do
    # debug(d)
    debug(field)
    Paginator.default_fetch_cursor_value(d, field)
  end

  def order_cursor_fields(:num_likes, sort_order),
    do: [{{:activity, :like_count, :object_count}, sort_order}, {{:activity, :id}, sort_order}]

  def order_cursor_fields(:num_boosts, sort_order),
    do: [{{:activity, :boost_count, :object_count}, sort_order}, {{:activity, :id}, sort_order}]

  def order_cursor_fields(:num_replies, sort_order),
    do: [
      {{:activity, :replied, :total_replies_count}, sort_order},
      {{:activity, :id}, sort_order}
    ]

  # {:num_replies, sort_order},
  # def order_cursor_fields(:num_replies, sort_order), do: [{{:activity, :id}, sort_order}]

  def order_cursor_fields(_, sort_order), do: [{{:activity, :id}, sort_order}]
end
