defmodule Bonfire.Social.Activities do
  @moduledoc """
  Helpers to create or query (though that's usually done through `Bonfire.Social.FeedActivities`) activities, preload relevant associations, and otherwise massage activity-related data.

  This is the [context](https://hexdocs.pm/phoenix/contexts.html) for `Bonfire.Data.Social.Activity`, which has these fields:
  - id: primary key (which when the verb is Create usually matches the related Object)
  - subject: references the who (eg. a user)
  - verb: what kind of action (eg. references Like or Follow in `Bonfire.Data.AccessControl.Verb`)
  - object: references the what (eg. a specific post)
  """

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
  alias Bonfire.Social.Objects

  alias Needle.Changesets
  alias Needle.Pointer
  # alias Needle.ULID

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Activity
  def query_module, do: __MODULE__

  @doc """
  Casts a changeset with the provided verb, creator and options.

  ## Examples

      > cast(changeset, :like, %User{}, feed_ids: [])
      # Changeset with associations set

  """
  def cast(changeset, verb, creator, opts \\ []) do
    # verb_id = verb_id(verb)
    creator = repo().maybe_preload(creator, :character)
    # |> debug("creator")
    # debug(changeset)
    changeset
    |> put_assoc(verb, creator, opts[:object_id])
    |> FeedActivities.cast(opts[:feed_ids])

    # |> debug("csss")
  end

  def put_assoc(changeset, verb, subject, object_id \\ nil)

  def put_assoc(changeset, verb, subject, nil),
    do: put_assoc(changeset, verb, subject, changeset)

  def put_assoc(changeset, verb, subject, object_id) do
    verb = Changesets.set_state(struct(Verb, Verbs.get(verb)), :loaded)
    verb_id = verb.id

    %{subject_id: uid(subject), object_id: uid(object_id), verb_id: verb_id}
    |> Changesets.put_assoc(changeset, :activity, ...)
    |> Changeset.foreign_key_constraint(:activity_id,
      name: "bonfire_data_social_activity_object_id_fkey"
    )
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

    %{subject_id: uid(subject), object_id: uid(object), verb_id: verb_id}
    |> Ecto.build_assoc(thing, :activity, ...)
    |> Map.put(:verb, verb)
  end

  defp put_data(changeset, key, value),
    do: Changesets.update_data(changeset, &Map.put(&1, key, value))

  @doc """
  Filters a query to include only permitted objects.

  ## Examples

      > as_permitted_for(query, [])
      # Filtered query

  """
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
  Create an Activity.
  NOTE: you will usually want to use `cast/3` instead or maybe `Objects.publish/5`

  ## Examples

      > create(%User{id: "1"}, :like, %Post{id: "1"})
      {:ok, %Activity{}}
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

  @doc """
  Deletes an activity by subject, verb, and object.

  ## Examples

      > delete_by_subject_verb_object(%User{id: "1"}, :like, %Post{id: "1"})
      # Number of deleted activities
  """
  def delete_by_subject_verb_object(subject, verb, object) do
    q = by_subject_verb_object_q(subject, Verbs.get_id!(verb), object)
    # FIXME? does cascading delete take care of this?
    FeedActivities.delete(repo().many(q), :id)
    # TODO? maybe_remove_for_deleters_feeds(id)
    elem(repo().delete_all(q), 1)
  end

  @doc """
  Deletes activities by ID or struct, or using specific filters.

  ## Examples

      > delete(activity)
      # Number of deleted activities

      > delete("1")
      # Number of deleted activities

      > delete([id: "1"])
      # Number of deleted activities

  """
  def delete(id) when is_binary(id) or is_struct(id) do
    maybe_apply(Bonfire.Search, :maybe_unindex, [id])
    delete({:id, id})
  end

  def delete(filters) when is_list(filters) or is_tuple(filters) do
    q =
      Activity
      |> query_filter(filters)
      |> debug("gonna delete")

    # TODO: move call Objects.maybe_unindex here to delete from search index?

    # FIXME? does cascading delete take care of deleting the activities from feeds?
    FeedActivities.delete(repo().many(q), :id)

    q
    |> repo().delete_many()
    |> elem(0)
  end

  @doc """
  Deletes an activity by object ID.

  ## Examples

      > delete_by_object("1")
      # Number of deleted objects
  """
  def delete_by_object(id) when is_binary(id) or is_struct(id) do
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
        f.subject_id == ^uid!(subject) and f.object_id == ^uid!(object) and
          f.verb_id == ^verb,
      select: f.id
    )
  end

  @doc """
  Preloads the creation activity for an object.

  ## Examples

      > object_preload_create_activity(%Post{})
      # Object with preloaded creation activity

  """
  def object_preload_create_activity(object),
    do: object_preload_activity(object, :create)

  @doc """
  Preloads the activity for an object and verb.

  ## Examples

      > object_preload_activity(%Post{}, :like)
      # Object with preloaded activity

  """
  def object_preload_activity(object, verb \\ :create) do
    verb_id = verb_id(verb)

    query =
      from(activity in Activity,
        as: :activity,
        where: activity.verb_id == ^verb_id
      )

    repo().preload(object, activity: query)
  end

  @doc """
  Preloads creation activity for objects in a query.

  ## Examples

      > query_object_preload_create_activity(query, [])
      # Query with preloaded creation activities
  """
  def query_object_preload_create_activity(q, opts \\ []) do
    query_object_preload_activity(q, :create, :id, opts)
  end

  @doc """
  Preloads activity for objects in a query using the specified verb and object ID field.

  ## Examples

      > query_object_preload_activity(query, :like, :post_id, [])
      # Query with preloaded activities

  """
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

  @doc """
  Applies preloads to a query or or post-loads to object(s) with the specified options. See `activity_preloads/3` for what preload options you can specify.

  ## Examples

      > activity_preloads(query, preload: [])
      # Query with applied activity preloads

  """
  def activity_preloads(query_or_object_or_objects, opts) do
    opts = to_options(opts)
    debug(opts, "preloads")
    activity_preloads(query_or_object_or_objects, opts[:preload], opts)
  end

  @doc """
  Applies preloads to a query or or post-loads to object(s) with the specified preloads and options.

  ## Examples

      > activity_preloads(query, [], [])
      # Original query, with no extra joins/preloads

      > activity_preloads(object, [], [])
      # Original object, with no extra assocs preloads

      > activity_preloads(object_or_query, [:with_creator], [])
      # Object or query with extra assocs preloads

      > activity_preloads(object_or_query, [:feed, :with_reply_to, :with_media, :with_object_more, :maybe_with_labelled])
      # Object or query several extra assoc preloads

  """
  def activity_preloads([], _, _) do
    debug("skip because we have an empty list")
    []
  end

  def activity_preloads(query_or_object_or_objects, preloads, opts) when is_list(preloads) do
    # debug(query, "query or data")
    debug(preloads, "preloads inputted")
    opts = to_options(opts) |> Keyword.put(:preloads, preloads)

    if not is_nil(query_or_object_or_objects) and
         Ecto.Queryable.impl_for(query_or_object_or_objects) do
      preloads
      |> Bonfire.Social.FeedLoader.map_activity_preloads()
      |> debug("accumulated preloads to proload")
      |> Enum.reduce(query_or_object_or_objects, &prepare_activity_preloads(&2, &1, opts))
      |> debug("query with accumulated proloads")
    else
      already_preloaded =
        is_tuple(opts[:activity_preloads]) &&
          elem(opts[:activity_preloads], 0) |> debug("already_preloaded")

      preloads
      |> Bonfire.Social.FeedLoader.map_activity_preloads(already_preloaded)
      |> Enum.flat_map(&prepare_activity_preloads(nil, &1, opts))
      |> Enum.uniq()
      |> debug("accumulated postloads to try")
      |> maybe_repo_preload_activity(query_or_object_or_objects, ..., opts)

      # |> debug()
    end
  end

  def activity_preloads(query, false, _opts) do
    query
  end

  def activity_preloads(query, preloads, opts) do
    activity_preloads(query, [preloads], opts)
  end

  defp prepare_activity_preloads(query, preload, opts) when is_atom(preload) do
    current_user_id = current_user_id(opts)

    skip_loading_user_ids =
      [current_user_id, id(opts[:subject_user])]
      |> filter_empty([])
      |> debug("skip_loading_user_ids")

    # pre-loading on a query
    if not is_nil(query) and Ecto.Queryable.impl_for(query) do
      case preload do
        :with_creator ->
          # This actually loads the creator of the object:
          # * In the case of a post, creator of the post
          # * In the case of like of a post, creator of the post
          # in feeds, we join the creator with a where clause to skip it when creator==subject
          query
          |> proload(
            activity: [
              :object
              # object: {"object_", [:created]}
            ]
          )
          |> maybe_preload_creator(skip_loading_user_ids, opts)

        # :tags ->
        #   # Tags/mentions (this actual needs to be done by Repo.preload to be able to list more than one)
        #   proload query,
        #     activity: [tags:  {"tag_", [:character, profile: :icon]}]
        :with_subject ->
          query
          |> maybe_preload_subject(skip_loading_user_ids, opts)

        :with_verb ->
          proload(query, activity: [:verb])

        :with_object ->
          proload(query, activity: [:object])

        :with_post_content ->
          proload(query,
            activity: [
              :sensitive,
              object: {"object_", [:post_content]}
            ]
          )

        :with_object_more ->
          proload(query,
            activity: [
              :sensitive,
              object: {"object_", [:post_content, :character, profile: :icon]}
            ]
          )

        :with_object_peered ->
          proload(query,
            activity: [
              object: {"object_", [:peered]}
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
                  reply_to: ^maybe_preload_reply_to(skip_loading_user_ids, opts)
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
          |> join_per_media(:left)
          # use preload instead of proload because there can be many media
          |> preload(activity: [:media])

        :per_media ->
          query
          |> proload(activity: [:sensitive])
          |> join_per_media(:left)
          |> proload(activity: [:media])

        # |> Ecto.Query.exclude(:distinct)
        # |> distinct([media: media], desc: media.id)
        # ^ NOTE: the media id should be equivalent to the object id so not necessary to customise

        :maybe_with_labelled ->
          if Extend.extension_enabled?(:bonfire_label),
            do:
              query
              |> proload(
                activity: [
                  labelled:
                    {"labelled_",
                     [
                       :post_content
                       # :media,
                       # subject: [:profile]
                     ]}
                ]
              ),
            else: query

        # NOTE: media attached to the label should be loaded separately as there can be several

        # proload query, activity: [:media] # FYI: proloading media only queries one attachment
        :with_seen ->
          query_preload_seen(query, opts)

        :emoji ->
          # TODO: optimise so we don't load the Edge for non-like activities
          query
          |> proload(activity: [:emoji])

        :extra_info ->
          query
          |> proload(activity: [object: [:extra_info]])

        nil ->
          query

        other ->
          warn(other, "Unknown preload")
          query
      end
    else
      # post-loading on an struct or list of structs

      case preload do
        :with_creator ->
          # This actually loads the creator of the object:
          # * In the case of a post, creator of the post
          # * In the case of like of a post, creator of the post

          # preload_fn = fn ids, assoc ->
          #   debug(ids)
          #   debug(assoc)

          #   %{related_key: related_key, queryable: queryable} = assoc

          #   ids = Enum.reject(ids, fn id -> id in skip_loading_user_ids end)
          #   # TODO: how to also exclude the activity's subject_id?

          #   repo().all(
          #     from q in queryable,
          #       where: field(q, ^related_key) in ^ids
          #   )
          #   |> debug()
          # end

          [
            object: [
              created: [
                creator:
                  {repo().reject_preload_ids(skip_loading_user_ids), [:character, profile: :icon]}
              ]
            ]
          ]

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

        :with_post_content ->
          [
            # :replied,
            object: [:post_content]
          ]

        :with_object_more ->
          [
            :replied,
            object: [:post_content]
            # object: [:post_content, :peered, :character, profile: :icon]
          ]

        :with_object_peered ->
          #  NOTE: :peered info is needed to correctly render remote posts, but only loaded when unknown, depending on feed type
          [
            object: [:peered]
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
              reply_to: maybe_preload_reply_to(skip_loading_user_ids, opts)
            ]
          ]

        :with_media ->
          [:media, :sensitive]

        :maybe_with_labelled ->
          maybe_with_labelled()

        :with_seen ->
          subquery = subquery_preload_seen(opts)
          if subquery, do: [seen: subquery], else: []

        :emoji ->
          [:emoji]

        :extra_info ->
          [object: [:extra_info]]

        nil ->
          []

        other ->
          warn(other, "Unknown preload")
          []
      end
    end
  end

  @doc "join media"

  def join_per_media(query, :inner) do
    query
    # |> reusable_join(:inner, [activity: activity], media in Bonfire.Files.Media,
    #     as: :media,
    #     on:
    #       activity.object_id == media.id
    #   )
    # ^ adds a join to show ONLY media objects in activities (does not include media attached to an object)
    |> reusable_join(
      :left,
      [activity: activity],
      files in assoc(activity, :files),
      as: :files
    )
    |> reusable_join(
      :inner,
      [activity: activity, files: files],
      media in Bonfire.Files.Media,
      as: :media,
      on: files.media_id == media.id or activity.object_id == media.id
    )
  end

  def join_per_media(query, _) do
    query
    |> reusable_join(
      :left,
      [activity: activity],
      files in assoc(activity, :files),
      as: :files
    )
    |> reusable_join(
      :left,
      [activity: activity, files: files],
      media in Bonfire.Files.Media,
      as: :media,
      on: files.media_id == media.id or activity.object_id == media.id
    )
  end

  defp query_preload_seen(q, opts) do
    user_id = uid(current_user(opts))

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
    user_id = uid(current_user(opts))

    if user_id do
      table_id = Bonfire.Common.Types.table_id(Seen)

      from(seen_edge in Edge,
        where: seen_edge.table_id == ^table_id and seen_edge.subject_id == ^user_id
      )
    end
  end

  def maybe_with_labelled do
    if Extend.extension_enabled?(:bonfire_label),
      do: [labelled: [:post_content, :media, subject: [:profile]]],
      else: []
  end

  defp maybe_preload_reply_to([], opts) do
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
        # :peered # should not be needed as we can assume if it's remote from the creator peered (and we don't display a canonical link for reply_to)
        created: [
          creator: [character: [:peered], profile: :icon]
        ]
      ]
      # }]
    )
    |> debug("query to attempt loading reply_to")
  end

  defp maybe_preload_reply_to(skip_loading_user_ids, opts) do
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
        :post_content
        # :peered # should not be needed as we can assume if it's remote from the creator peered (and we don't display a canonical link for reply_to)
      ]
      # }]
    )
    |> reusable_join(
      :left,
      [reply_to],
      created in assoc(reply_to, :created),
      as: :created,
      on: created.creator_id not in ^skip_loading_user_ids
    )
    |> preload(
      # [{"reply_to_",
      created: [
        creator: [character: [:peered], profile: :icon]
      ]
      # }]
    )
    |> debug("query to attempt loading reply_to")
  end

  @doc """
  Optimizes the query to optionally include the subject data.

  If `skip_loading_user_ids` is empty, the subject is always included. Otherwise, it is included only if it is different from the users in `skip_loading_user_ids`.

  ## Examples

      > maybe_preload_subject(query, [], [])
      # returns query with subject preloaded

      > maybe_preload_subject(query, [1, 2, 3], [])
      # returns query with subject included only if subject.id not in [1, 2, 3]
  """
  def maybe_preload_subject(query, [], opts) do
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
    |> maybe_preload_subject_peered(:with_object_peered not in (opts[:preloads] || []))
  end

  def maybe_preload_subject(query, skip_loading_user_ids, opts) do
    # optimisation: only includes the subject if different current_user
    query
    |> proload([:activity])
    |> reusable_join(
      :left,
      [activity: activity],
      subject in assoc(activity, :subject),
      as: :subject,
      on: activity.subject_id not in ^skip_loading_user_ids
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
    |> maybe_preload_subject_peered(:with_object_peered not in (opts[:preloads] || []))
  end

  defp maybe_preload_subject_peered(query, true) do
    query
    |> proload(
      activity: [
        subject:
          {"subject_",
           [
             character: [:peered]
           ]}
      ]
    )
  end

  defp maybe_preload_subject_peered(query, _false) do
    query
  end

  @doc """
  Optionally joins the creator.

  Performs a query optimization: only includes the creator if different from the subject or current user.

  If `skip_loading_user_ids` is empty, the creator is always included. Otherwise, it is included only if it is different from the users in `skip_loading_user_ids`.

  ## Examples

      > maybe_preload_creator(query, [], [])
      # returns query with creator preloaded if different from the subject

      > maybe_preload_creator(query, [1, 2, 3], [])
      # returns query with creator included only if creator.id not in [1, 2, 3]
  """
  def maybe_preload_creator(query, skip_loading_user_ids, opts) do
    query
    |> maybe_join_creator(skip_loading_user_ids, opts)
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
    |> maybe_preload_creator_peered(:with_object_peered not in (opts[:preloads] || []))

    # |> IO.inspect(label: "maybe_preload_creator")
  end

  def maybe_join_creator(query, [], opts) do
    if :with_subject in e(opts, :preload, []) do
      query
      # first join subject, since creator will only be loaded if different from the subject
      |> maybe_preload_subject([], opts)
      |> reusable_join(
        :left,
        [activity: activity, object: object],
        object_created in assoc(object, :created),
        as: :object_created,
        #  only includes the created with creator_id if different than the subject
        on: object_created.creator_id != activity.subject_id
      )
    else
      query
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
        subject in assoc(activity, :subject),
        as: :subject,
        #  preload subject if the object has no created info
        on: is_nil(object_created.id)
      )
      |> maybe_preload_subject([], opts)
    end
  end

  def maybe_join_creator(query, skip_loading_user_ids, opts) do
    if :with_subject in e(opts, :preload, []) do
      query
      # first join subject, since creator will only be loaded if different from the subject
      |> maybe_preload_subject(skip_loading_user_ids, opts)
      |> reusable_join(
        :left,
        [activity: activity, object: object],
        object_created in assoc(object, :created),
        as: :object_created,
        #  only includes the created with creator_id if different than the subject
        on: object_created.creator_id != activity.subject_id
      )
      |> reusable_join(
        :left,
        [activity: activity, object_created: object_created],
        creator in assoc(object_created, :creator),
        as: :object_creator,
        # only includes the creator if not excluded
        on: object_created.creator_id not in ^skip_loading_user_ids
      )
    else
      query
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
        creator in assoc(object_created, :creator),
        as: :object_creator,
        # only includes the creator if not excluded
        on: object_created.creator_id not in ^skip_loading_user_ids
      )
      |> reusable_join(
        :left,
        [activity: activity, object_created: object_created],
        subject in assoc(activity, :subject),
        as: :subject,
        #  preload subject if the object has no created info
        on: is_nil(object_created.id) and activity.subject_id not in ^skip_loading_user_ids
      )
      |> maybe_preload_subject(skip_loading_user_ids, opts)
    end
  end

  defp maybe_preload_creator_peered(query, true) do
    query
    |> proload(
      activity: [
        object:
          {"object_",
           [
             created: [
               creator:
                 {"creator_",
                  [
                    character: [
                      :peered
                    ]
                  ]}
             ]
           ]}
      ]
    )
  end

  defp maybe_preload_creator_peered(query, _false) do
    query
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
    #  why not?
    |> Keyword.put_new(:follow_pointers, false)
    |> repo().maybe_preload(objects, preloads, ...)
  end

  @doc """
  Gets an activity by its ID.

  ## Examples

      > get("activity_id", [])
  """
  def get(id, opts) when is_binary(id), do: repo().single(query([id: id], opts))

  @doc """
  Retrieves an activity based on a query and options.

  ## Examples

      > read(query)
      # returns an activity based on the provided query

      > read(object_id)
      # returns an activity for the provided object ID (usually a create activity)
  """
  def read(query, opts \\ []),
    do:
      read_query(query, opts)
      |> as_permitted_for(opts, [:read])
      # |> debug("a")
      |> repo().single()

  @doc """
  Constructs a query for reading activities based on input.

  ## Examples

      > read_query(query, opts)

      > read_query(object_id, opts)
  """
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
    # |> debug
  end

  def read_query(filters, opts) when is_map(filters) or is_list(filters) do
    # current_user = current_user(opts)
    Activity
    |> maybe_filter(filters, opts)
    |> read_query(opts)
  end

  def maybe_filter(query, filters, opts \\ [])

  def maybe_filter(query, filters, opts) when is_list(filters) or is_map(filters) do
    # filters = Keyword.drop(filters, @skip_warn_filters)
    Enum.reduce(filters, query, &maybe_filter(&2, &1, opts))
    |> query_filter(filters)
    |> debug()
  end

  def maybe_filter(query, {:activity_types, types}, _opts) do
    debug(types, "filter by activity_types")

    case Verbs.ids(types) do
      verb_ids when is_list(verb_ids) and verb_ids != [] ->
        # debug(verb_ids, label: "filter by verb_ids")
        where(query, [activity: activity], activity.verb_id in ^verb_ids)

      other ->
        # debug(other, label: "no verb_ids")
        query
    end
  end

  def maybe_filter(query, {:exclude_activity_types, types}, opts) do
    debug(types, "filter by exclude_activity_types")

    case Verbs.ids(types) do
      verb_ids when is_list(verb_ids) and verb_ids != [] ->
        # FIXME: would this work if any exclude_verb_ids are also set?
        maybe_filter(query, {:exclude_verb_ids, verb_ids}, opts)

      _ ->
        query
    end
  end

  def maybe_filter(query, {:exclude_verb_ids, exclude_verb_ids}, opts) do
    exclude_verb_ids =
      List.wrap(exclude_verb_ids)
      |> debug("filter by exclude_verb_ids")

    user_id =
      current_user_id(opts)

    request_verb_id = "1NEEDPERM1SS10NT0D0TH1SN0W"

    if user_id && request_verb_id not in exclude_verb_ids do
      exclude_verb_ids = exclude_verb_ids ++ [request_verb_id]

      # FIXME: would this also be triggered if no exclude_activity_types or exclude_verb_ids are provided?
      query
      |> where(
        [activity: activity],
        activity.verb_id not in ^exclude_verb_ids or
          (activity.verb_id == ^request_verb_id and activity.object_id == ^user_id)
      )
    else
      exclude_verb_ids = exclude_verb_ids ++ [request_verb_id]
      where(query, [activity: activity], activity.verb_id not in ^exclude_verb_ids)
    end
  end

  def maybe_filter(query, {:exclude_object_types, types}, _opts) when not is_nil(types) do
    debug(types, "filter by exclude_object_types")

    case Objects.prepare_exclude_object_types(
           types,
           Bonfire.Social.FeedLoader.skip_types_default()
         ) do
      exclude_table_ids when is_list(exclude_table_ids) and exclude_table_ids != [] ->
        debug(types, "filter by exclude_table_ids")
        maybe_filter(query, {:exclude_table_ids, exclude_table_ids}, [])

      other ->
        debug(other, "other exclude_table_ids")
        query
    end
  end

  def maybe_filter(query, {:exclude_table_ids, exclude_table_ids}, _opts)
      when is_list(exclude_table_ids) and exclude_table_ids != [] do
    debug(exclude_table_ids, "filter by exclude_table_ids")

    query
    # |> proload([:activity])
    # this loads the Pointer for the Activity, only in cases where the Activity ID does not match the Object ID which means this isn't a Create activity, and allows us to check that the Object (which may be boosted/liked/flagged/etc in this Activity) is not deleted or an excluded type
    |> reusable_join(:left, [activity: activity], activity_pointer in Pointer,
      as: :activity_pointer,
      on: activity.object_id != activity.id and activity_pointer.id == activity.id
    )
    |> where(
      [activity_pointer: activity_pointer],
      is_nil(activity_pointer.deleted_at) and
        (is_nil(activity_pointer.table_id) or activity_pointer.table_id not in ^exclude_table_ids)
    )
    |> reusable_join(:inner, [activity: activity], object in Pointer,
      as: :object,
      # Don't show certain object types (like messages) or anything deleted
      on:
        object.id == activity.object_id and
          is_nil(object.deleted_at) and object.table_id not in ^exclude_table_ids
    )
  end

  # doc "List objects created by a user and which are in their outbox, which are not replies"
  def maybe_filter(query, {:creators, creators}, _opts) do
    case Types.uids(creators) do
      nil ->
        query

      ids ->
        # user = repo().maybe_preload(user, [:character])
        verb_id = Verbs.get_id!(:create)

        query
        |> proload(activity: [:replied])
        |> where(
          [activity: activity, replied: replied],
          is_nil(replied.reply_to_id) and
            activity.verb_id == ^verb_id and
            activity.subject_id in ^ids
        )
    end
  end

  def maybe_filter(query, {:exclude_creators, creators}, _opts) do
    case Types.uids(creators) do
      nil ->
        query

      ids ->
        # user = repo().maybe_preload(user, [:character])
        verb_id = Verbs.get_id!(:create)

        query
        |> proload(activity: [:replied])
        |> where(
          [activity: activity, replied: replied],
          not (is_nil(replied.reply_to_id) and activity.verb_id == ^verb_id and
                 activity.subject_id in ^ids)
        )
    end
  end

  def maybe_filter(query, {:subjects, subject}, opts) do
    case subject do
      :visible ->
        boundarise(query, activity.subject_id, opts)

      _ ->
        case uids(subject) do
          [] ->
            debug(subject, "unrecognised subject")
            query

          ids ->
            where(query, [activity: activity], activity.subject_id in ^ids)
        end
    end
  end

  def maybe_filter(query, {:exclude_subjects, subject}, opts) do
    case Types.uids(subject) do
      nil ->
        warn(subject, "unrecognised subject")
        query

      ids ->
        where(query, [activity: activity], activity.subject_id not in ^ids)
    end
  end

  def maybe_filter(query, {:subject_types, types}, _opts) do
    case Bonfire.Common.Types.table_types(types) do
      table_ids when is_list(table_ids) and table_ids != [] ->
        where(query, [subject: subject], subject.table_id in ^table_ids)

      _ ->
        query
    end
  end

  def maybe_filter(query, {:exclude_subject_types, types}, _opts) do
    case Bonfire.Common.Types.table_types(types) |> debug("exclude_subject_types table_ids") do
      table_ids when is_list(table_ids) and table_ids != [] ->
        query
        |> proload(activity: [:subject])
        |> where([subject: subject], subject.table_id not in ^table_ids)

      _ ->
        query
    end
  end

  def maybe_filter(query, {:subject_circles, circle_ids}, opts) do
    case Types.uids(circle_ids, nil) do
      nil ->
        warn(circle_ids, "unrecognized circle_ids")
        query

      # exclude members of all specified circles
      circle_ids ->
        query
        |> reusable_join(
          :inner,
          [activity: activity],
          subject_encircle in Bonfire.Data.AccessControl.Encircle,
          as: :subject_encircle,
          on:
            activity.subject_id == subject_encircle.subject_id and
              subject_encircle.circle_id in ^circle_ids
        )
    end
  end

  def maybe_filter(query, {:exclude_subject_circles, circle_ids}, opts) do
    case Types.uids(circle_ids, nil) do
      nil ->
        warn(circle_ids, "unrecognized circle_ids")
        query

      # exclude members of all specified circles
      circle_ids ->
        query
        |> reusable_join(
          :left,
          [activity: activity],
          subject_disencircle in Bonfire.Data.AccessControl.Encircle,
          as: :subject_disencircle,
          on:
            activity.subject_id == subject_disencircle.subject_id and
              subject_disencircle.circle_id in ^circle_ids
        )
        |> where([subject_disencircle: subject_disencircle], is_nil(subject_disencircle.id))
    end
  end

  def maybe_filter(query, {:objects, object}, _opts) do
    case Types.uid_or_uids(object) do
      id when is_binary(id) ->
        where(query, [activity: activity], activity.object_id == ^id)

      ids when is_list(ids) and ids != [] ->
        where(query, [activity: activity], activity.object_id in ^ids)

      _ ->
        query
    end
  end

  def maybe_filter(query, {:exclude_objects, object}, _opts) do
    case Types.uid_or_uids(object) do
      id when is_binary(id) ->
        where(query, [activity: activity], activity.object_id != ^id)

      ids when is_list(ids) and ids != [] ->
        where(query, [activity: activity], activity.object_id not in ^ids)

      _ ->
        query
    end
  end

  def maybe_filter(query, {:origin, origin}, _opts) when is_list(origin) and origin != [] do
    fetcher_user_id = "1ACT1V1TYPVBREM0TESFETCHER"

    cond do
      :local in origin ->
        debug("local feed")
        local_feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

        query
        # WIP: optimise by avoiding subject and object :peered preloads (only need to join them)
        |> proload(activity: [:object])
        |> reusable_join(
          :left,
          [activity: activity],
          subject in assoc(activity, :subject),
          as: :subject
        )
        |> reusable_join(
          :left,
          [subject: subject],
          subject_character in assoc(subject, :character),
          as: :subject_character
        )
        |> reusable_join(
          :left,
          [subject_character: subject_character],
          subject_peered in assoc(subject_character, :peered),
          as: :subject_peered
        )
        |> reusable_join(
          :left,
          [object: object],
          object_peered in assoc(object, :peered),
          as: :object_peered
        )
        |> where(
          [
            fp,
            activity: activity,
            subject_character: subject_character,
            subject_peered: subject_peered,
            object: object,
            object_peered: object_peered
          ],
          activity.subject_id != ^fetcher_user_id and fp.feed_id == ^local_feed_id and
            ((is_nil(subject_character.id) or is_nil(subject_peered.peer_id)) and
               (is_nil(object.id) or is_nil(object_peered.peer_id)))
        )

      :remote in origin ->
        debug("remote/federated feed")
        federated_feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)

        query
        |> proload(
          activity: [subject: {"subject_", character: [:peered]}, object: {"object_", [:peered]}]
        )
        |> where(
          [fp, activity: activity, subject_peered: subject_peered, object_peered: object_peered],
          fp.feed_id == ^federated_feed_id or activity.subject_id == ^fetcher_user_id or
            not is_nil(subject_peered.peer_id) or not is_nil(object_peered.peer_id)
        )

      true ->
        {instance_ids, instance_urls} =
          Enum.split_with(origin, &Types.uid/1)
          |> debug("list of instances")

        instance_ids =
          (instance_ids ++
             if instance_urls != [] do
               maybe_apply(
                 Bonfire.Federate.ActivityPub.Instances,
                 :list_by_domains,
                 [instance_urls],
                 fallback_return: []
               )
               |> Types.uids()
             else
               []
             end)
          |> debug("peers ids")

        query
        |> proload(
          activity: [subject: {"subject_", character: [:peered]}, object: {"object_", [:peered]}]
        )
        |> where(
          [subject_peered: subject_peered, object_peered: object_peered],
          subject_peered.peer_id in ^instance_ids or object_peered.peer_id in ^instance_ids
        )
    end
  end

  def maybe_filter(query, {:origin, origin}, opts) when not is_nil(origin),
    do: maybe_filter(query, {:origin, List.wrap(origin)}, opts)

  # TODO? put somewhere more relevant:

  def maybe_filter(query, {:in_thread, threads}, _opts) do
    query
    # |> proload(activity: [:replied])
    |> Bonfire.Social.Threads.filter(:in_thread, threads, ...)
  end

  def maybe_filter(query, {:tree_parent, parents}, _opts) do
    query
    |> proload(activity: [:tree])
    |> where([tree: tree], tree.parent_id in ^uids(parents))
  end

  def maybe_filter(query, filters, _opts) do
    warn(filters, "no supported activity-related filters defined")
    query
  end

  @doc """
  Constructs a query based on filters and optional user context.

  ## Examples

      > query(filters)

      iex> query([my: :feed], [current_user: nil])
      ** (Bonfire.Fail.Auth) You need to log in first. 
  """
  def query(filters \\ [], opts_or_current_user \\ [])

  def query([my: :feed], opts_or_current_user) do
    current_user = current_user_required!(opts_or_current_user)
    query([feed_id: uid(current_user)], opts_or_current_user)
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

  @doc """
  Processes and structures activity data within an object.

  ## Examples

      iex> %{id: 1, activity: %{id: 2}} = activity_under_object(%{activity: %Bonfire.Data.Social.Activity{id: 2, object: %{id: 1}}})

  """
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

  def activity_under_object(%Activity{object: %{id: _} = activity_object} = activity) do
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

  @doc """
  Processes and structures activity data within a media.

  ## Examples

      iex> %{id: 1, activity: %{id: 2}} = activity_under_media(%{activity: %Bonfire.Data.Social.Activity{id: 2, media: %{id: 1}}})

  """
  # this is a hack to mimic the old structure of the data provided to
  # the activity component, which will we refactor soon(tm)
  def activity_under_media(%{activity: %{media: %{id: _} = media} = activity} = top_object) do
    activity_under_media(activity, media)
  end

  def activity_under_media(%{activity: %{media: [%{id: _} = media]} = activity} = top_object) do
    activity_under_media(activity, media)
  end

  def activity_under_media(%Activity{media: %{id: _} = media} = activity) do
    activity_under_media(activity, media)
  end

  def activity_under_media(%Activity{media: [%{id: _} = media]} = activity) do
    activity_under_media(activity, media)
  end

  def activity_under_media(%{activity: %{id: _} = activity} = media) do
    activity_under_media(activity, media)
  end

  def activity_under_media(%{activities: [%{id: _} = activity]} = top_object) do
    activity_under_media(activity, Map.drop(top_object, [:activities]))
  end

  def activity_under_media(%{} = object_without_activity) do
    Map.put(object_without_activity, :activity, %{})
  end

  def activity_under_media({:ok, %{} = media}) do
    {:ok, activity_under_media(media)}
  end

  def activity_under_media(%Activity{} = activity, %{} = media) do
    Map.put(media, :activity, Map.drop(activity, [:media]))
  end

  def activity_under_media(%Activity{} = activity, [%{} = media]) do
    Map.put(media, :activity, Map.drop(activity, [:media]))
  end

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
  @doc """
  Retrieves or constructs the object from an activity.

  ## Examples

      iex> object_from_activity(%{object: %{id: 1}})
      %{id: 1}
  """
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

  @doc """
  Loads an object based on its ID or pointer.

  ## Examples

      > load_object("object_id")
  """
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

  # Helper to inject subject and creator data into activities
  def prepare_subject_and_creator(%{edges: edges}, opts) when is_list(edges) do
    Enum.map(edges, &prepare_subject_and_creator(&1, opts))
  end

  def prepare_subject_and_creator(edges, opts) when is_list(edges) do
    Enum.map(edges, &prepare_subject_and_creator(&1, opts))
  end

  def prepare_subject_and_creator(
        %{activity: %Bonfire.Data.Social.Activity{} = activity} = e,
        opts
      ) do
    Map.put(e, :activity, prepare_subject_and_creator(activity, opts))
  end

  def prepare_subject_and_creator(%Bonfire.Data.Social.Activity{object: object} = activity, opts) do
    # Find subject for this activity
    subject_id = e(activity, :subject_id, :nil!)

    subject =
      find_subject(activity, subject_id, opts)

    # |> ensure_completeness!(:subject, opts)

    subject_id = subject_id || id(subject)
    creator_id = creator_id(activity, object)

    # Update the activity with subject
    activity = if subject, do: Map.put(activity, :subject, subject), else: activity

    # Find creator for this activity

    if not is_nil(creator_id) and creator_id != subject_id do
      creator =
        find_creator(activity, object, creator_id, opts)

      # |> ensure_completeness!(:creator, opts)

      cond do
        # Update the creator in the creator
        creator && is_map(object) ->
          created =
            e(object, :created, %{})
            |> Map.put(:creator, creator)

          object = Map.put(object, :created, created)

          Map.put(activity, :object, object)

        creator ->
          created =
            e(activity, :created, %{})
            |> Map.put(:creator, creator)

          Map.put(activity, :created, created)

        true ->
          debug(creator, "no creator found")
          activity
      end
    else
      # If the creator is the same as the subject, we don't need to load it again
      activity
    end
  end

  def prepare_subject_and_creator(object, _opts), do: object

  # NOTE: only for testing purposes, should be able to remove once preloads are all working
  defp ensure_completeness!(data, type, opts) do
    if opts[:preload] != [] do
      if not is_map(data) do
        err(data, "#{type}'s data is invalid")
        data
      else
        # If subject has minimal data, check if profile and character are missing
        if !e(data, :profile, nil) || !e(data, :character, nil) do
          # We could preload here to ensure at least the character and profile are loaded, but that would cause n+1 queries, so we raise instead, to reveal the issue in dev/test so that the data can be preloaded in activity_preloads instead
          # repo().maybe_preload(subject_data, [:character, profile: :icon])
          err(data, "#{type}'s profile or character are not loaded")
          data
        else
          # Subject already has complete data
          data
        end
      end
    else
      data
    end
  end

  def find_subject(opts) do
    find_subject(e(opts, :activity, nil), opts)
  end

  def find_subject(activity, opts) do
    find_subject(activity, e(activity, :subject_id, :nil!), opts)
  end

  def find_subject(activity, subject_id, opts) do
    subject =
      e(activity, :subject, nil)

    subject_id =
      (subject_id || id(subject))
      |> debug("subject_id")

    # Get subject or try to find it using user_if_loaded
    # || subject_id
    subject || user_if_loaded(:subject, subject_id, opts)
  end

  def find_creator(opts) do
    find_creator(e(opts, :activity, nil), opts)
  end

  def find_creator(activity, opts) do
    find_creator(activity, e(opts, :object, nil) || e(activity, :object, nil), opts)
  end

  def find_creator(activity, object, opts) do
    find_creator(activity, object, creator_id(activity, object), opts)
  end

  def find_creator(activity, object, creator_id, opts) do
    creator = creator(activity, object)

    creator_id = creator_id || id(creator)

    # |> debug("creator_id")

    # || creator_id
    creator || user_if_loaded(:creator, creator_id, opts)
  end

  def creator(activity, object),
    do:
      (e(object, :created, :creator, nil) || e(activity, :created, :creator, nil) ||
         e(object, :creator, nil))
      |> debug("maybe creator")

  def creator_id(activity, object),
    do:
      (e(object, :created, :creator_id, nil) ||
         e(activity, :created, :creator_id, nil) || e(object, :creator_id, nil))
      |> debug("creator_id")

  defp user_if_loaded(type, creator_or_subject_id, opts) do
    current_user =
      current_user(opts)

    debug(id(current_user), "current_user id")

    subject_user =
      e(opts, :subject_user, nil)

    debug(id(subject_user), "subject_user id")

    user_if_loaded(type, creator_or_subject_id, subject_user, current_user, opts)
  end

  defp user_if_loaded(type, creator_or_subject_id, subject_user, current_user, opts) do
    creator_or_subject_id = id(creator_or_subject_id)

    # Determine which user data to use based on matching IDs
    cond do
      current_user && creator_or_subject_id == id(current_user) ->
        current_user

      subject_user && creator_or_subject_id == id(subject_user) ->
        subject_user

      true ->
        ensure_user_loaded!(type, creator_or_subject_id, opts[:preload] || [])

        nil
    end
  end

  defp ensure_user_loaded!(type, creator_or_subject_id, []), do: :ok

  defp ensure_user_loaded!(:creator = type, creator_or_subject_id, preload) do
    if :with_subject not in preload,
      do:
        err(
          creator_or_subject_id,
          "No current_user or subject_user found matching this #{type} ID"
        )
  end

  defp ensure_user_loaded!(:subject = type, creator_or_subject_id, preload) do
    if :with_creator not in preload,
      do:
        err(
          creator_or_subject_id,
          "No current_user or subject_user found matching this #{type} ID"
        )
  end

  @doc """
  Returns the name of a verb based on its slug or identifier.

  ## Examples

      iex> verb_name(:create)
      "Create"
  """
  # TODO: put in Verbs module
  def verb_name(slug) when is_atom(slug),
    do: Bonfire.Boundaries.Verbs.get(slug)[:verb]

  def verb_name(%{verb: %{verb: verb}}), do: verb
  def verb_name(%{verb_id: id}), do: Bonfire.Boundaries.Verbs.get(id)[:verb]
  def verb_name(%{verb: verb}) when is_binary(verb), do: verb

  # @decorate time()
  @doc """
  Optionally modifies the verb based on activity context.

  ## Examples

      iex> verb_maybe_modify("Create", %{object: %{post_content: %{id: 1}}})
      "Write"
  """
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
    if is_uid?(verb) do
      verb_maybe_modify(Bonfire.Boundaries.Verbs.get!(verb)[:verb], activity)
    else
      verb
    end
  end

  # |> String.downcase()

  # @decorate time()
  @doc """
  Returns a localized and formatted display name for a verb.

  ## Examples

      iex> verb_display("create")
  """
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

  @doc """
  Retrieves or constructs an ID for a verb based on its name or identifier.

  ## Examples

      iex> verb_id(:create)
  """
  def verb_id(verb) when is_binary(verb),
    do: uid(verb) || Verbs.get_id(maybe_to_atom(verb))

  def verb_id(verb) when is_atom(verb),
    do: Verbs.get_id(verb) || Verbs.get_id!(:create)

  @doc """
  Outputs the names of all object verbs for localization, for the purpose of adding to the localisation strings, as long as the output is piped through to localise_strings/1 at compile time.
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

  @doc """
  Retrieves additional verb names with various formats for localization.
  """
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

    # |> debug(label: "Making all verb names localisable")
  end

  # workaround `Verbs` bug
  defp sanitise_verb_name("Editted"), do: "Edited"
  defp sanitise_verb_name(verb), do: verb

  @doc """
  Counts the total number of activities.
  """
  def count_total(), do: repo().one(select(Activity, [u], count(u.id)))

  @doc """
  Orders query results based on a specified field and sort order.

  ## Examples

      > query_order(query, :num_replies, :asc)
      # returns the query ordered by number of replies in ascending order
  """
  def query_order(query, sort_by, sort_order, with_pins? \\ false)

  def query_order(query, :num_replies, sort_order, _no_pins) do
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

  def query_order(query, :num_boosts, sort_order, _no_pins) do
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

  def query_order(query, :num_likes, sort_order, _no_pins) do
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

  def query_order(query, _, sort_order, true = _with_pins) do
    if sort_order == :asc do
      query
      |> proload(:activity)
      |> order_by([activity: activity, pinned: pinned],
        desc_nulls_last: pinned.id,
        asc: activity.id
      )
    else
      query
      |> proload(:activity)
      |> order_by([activity: activity, pinned: pinned],
        desc_nulls_last: pinned.id,
        desc: activity.id
      )
    end
  end

  def query_order(query, _, sort_order, _no_pins) do
    if sort_order == :asc do
      query
      |> proload(:activity)
      |> order_by([activity: activity],
        asc: activity.id
      )
    else
      query
      |> proload(:activity)
      |> order_by([activity: activity],
        desc: activity.id
      )
    end
  end

  @doc """
  Provides pagination options for ordering.

  ## Examples

      > order_pagination_opts(:num_likes, :desc)
      # returns pagination options for ordering by number of likes in descending order
  """
  def order_pagination_opts(sort_by, sort_order) do
    # [cursor_fields: [{{:activity, :id}, sort_order}]]
    [
      cursor_fields: order_cursor_fields(sort_by, sort_order || :desc),
      fetch_cursor_value_fun: &fetch_cursor_value_fun/2
    ]
  end

  @doc """
  Retrieves the cursor value for pagination based on field or data structure.

  ## Examples

      > fetch_cursor_value_fun(%{nested_replies_count: 5}, :num_replies)
      # returns the cursor value based on the number of replies
  """
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
    apply(E, :ed, [d] ++ Tuple.to_list(list) ++ [nil])
  end

  def fetch_cursor_value_fun(d, field) do
    # debug(d)
    debug(field)
    Paginator.default_fetch_cursor_value(d, field)
  end

  @doc """
  Provides cursor fields for ordering based on sort criteria.

  ## Examples

      > order_cursor_fields(:num_likes, :asc)
      # returns cursor fields for ordering by number of likes in ascending order
  """
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
