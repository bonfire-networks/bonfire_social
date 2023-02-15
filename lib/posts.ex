defmodule Bonfire.Social.Posts do
  use Arrows
  import Untangle
  import Bonfire.Boundaries.Queries
  alias Bonfire.Data.Social.Post
  # alias Bonfire.Data.Social.PostContent
  # alias Bonfire.Data.Social.Replied
  # alias Bonfire.Data.Social.Activity

  alias Bonfire.Social.Activities
  # alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social.Objects

  # alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Verbs

  alias Bonfire.Epics.Epic
  # alias Bonfire.Social.Integration
  alias Bonfire.Social.PostContents
  alias Bonfire.Social.Tags
  # alias Bonfire.Social.Threads

  # alias Ecto.Changeset

  use Bonfire.Common.Repo,
    schema: Post,
    searchable_fields: [:id],
    sortable_fields: [:id]

  use Bonfire.Common.Utils

  # import Bonfire.Boundaries.Queries

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Post

  def federation_module,
    do: [
      "Note",
      {"Create", "Note"},
      {"Update", "Note"},
      {"Create", "Article"},
      {"Update", "Article"}
    ]

  def draft(_creator, _attrs) do
    # TODO: create as private
    # with {:ok, post} <- create(creator, attrs) do
    #   {:ok, post}
    # end
  end

  def publish(opts \\ []) do
    run_epic(:publish, to_options(opts))
  end

  @doc "You should call `Objects.delete/2` instead"
  def delete(object, opts \\ []) do
    opts =
      to_options(opts)
      |> Keyword.put(:object, object)

    opts
    |> Keyword.put(
      :delete_associations,
      # adds per-type assocs
      (opts[:delete_associations] || []) ++
        [
          :post_content
        ]
    )
    |> run_epic(:delete, ..., :object)
  end

  def run_epic(type, options \\ [], on \\ :post) do
    env = Config.get(:env)

    options =
      Keyword.merge(options, crash: env == :test, debug: env != :prod, verbose: env == :test)

    with %{errors: []} = epic <-
           Epic.from_config!(__MODULE__, type)
           |> Epic.assign(:options, options)
           |> Epic.run() do
      {:ok, epic.assigns[on]}
    else
      e ->
        if options[:return_epic_on_error] do
          e
        else
          {:error, Errors.error_msg(e)}
        end
    end
  end

  # def reply(creator, attrs) do
  #   with  {:ok, published} <- publish(creator, attrs),
  #         {:ok, r} <- get_replied(published.post.id) do
  #     reply = Map.merge(r, published)
  #     # |> IO.inspect
  #     PubSub.broadcast(e(reply, :thread_id, nil), {{Bonfire.Social.Threads.LiveHandler, :new_reply}, reply}) # push to online users

  #     {:ok, reply}
  #   end
  # end

  def changeset(action, attrs, creator \\ nil, preset \\ nil)

  def changeset(:create, attrs, _creator, _preset) when attrs == %{} do
    # keep it simple for forms
    Post.changeset(%Post{}, attrs)
  end

  def changeset(:create, attrs, _creator, _preset_or_custom_boundary) do
    attrs
    |> prepare_post_attrs()
    |> debug("post_attrs")
    |> Post.changeset(%Post{}, ...)
  end

  def prepare_post_attrs(attrs) do
    # FIXME: find a less nasty way (this is to support graceful degradation with the textarea inside noscript)
    deep_merge(
      attrs,
      %{
        post: %{
          post_content: %{
            html_body:
              e(attrs, :post, :post_content, :html_body, nil) ||
                e(attrs, :fallback_post, :post_content, :html_body, nil)
          }
        }
      }
    )
  end

  def read(post_id, opts_or_socket_or_current_user \\ [])
      when is_binary(post_id) do
    with {:ok, post} <-
           base_query([id: post_id], opts_or_socket_or_current_user)
           |> Activities.read(opts_or_socket_or_current_user) do
      {:ok, Activities.activity_under_object(post)}
    end
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, opts \\ []) do
    # query FeedPublish
    # [posts_by: {by_user, &filter/3}]
    filter(:posts_by, by_user, Post)
    |> list_paginated(opts)
  end

  @doc "List posts with pagination"
  def list_paginated(filters, opts \\ [])

  def list_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    paginate = e(opts, :paginate, opts)

    filters
    # |> Keyword.drop([:paginate])
    # |> debug("filters")
    |> query_paginated(opts)
    |> repo().many_paginated(paginate)

    # |> FeedActivities.feed_paginated(filters, opts)
  end

  @doc "Query posts with pagination"
  def query_paginated(filters, opts \\ [])

  def query_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    # |> debug("filters")
    Objects.list_query(filters, opts)

    # |> FeedActivities.query_paginated(opts, Post)
    # |> debug("after FeedActivities.query_paginated")
  end

  # query_paginated(filters \\ [], current_user_or_socket_or_opts \\ [],  query \\ FeedPublish)
  def query_paginated({a, b}, opts), do: query_paginated([{a, b}], opts)

  def query(filters \\ [], opts \\ nil)

  def query(filters, opts) when is_list(filters) or is_tuple(filters) do
    base_query(filters, opts)
    |> proload([:post_content])
    |> boundarise(main_object.id, opts)
  end

  defp base_query(filters, _opts) when is_list(filters) or is_tuple(filters) do
    from(p in Post, as: :main_object)
    |> query_filter(filters, nil, nil)
  end

  # doc "List posts created by the user and which are in their outbox, which are not replies"
  def filter(:posts_by, user, query) do
    # user = repo().maybe_preload(user, [:character])
    verb_id = Verbs.get_id!(:create)

    query
    |> proload(activity: [object: {"object_", [:replied]}])
    |> where(
      [activity: activity, object_replied: replied],
      is_nil(replied.reply_to_id) and
        activity.verb_id == ^verb_id and
        activity.subject_id == ^ulid(user)
    )
  end

  # TODO: federated delete, in addition to create:
  def ap_publish_activity(subject, _verb, post) do
    with id <- ulid!(post),
         post <-
           post
           |> repo().maybe_preload([
             :replied,
             :post_content,
             :media,
             :created,
             tags: [:character]
           ])
           |> Activities.object_preload_create_activity(),
         subject <-
           subject || Utils.e(post, :created, :creator, nil) ||
             Utils.e(post, :created, :creator_id, nil) || Utils.e(post, :activity, :subject, nil) ||
             Utils.e(post, :activity, :subject_id, nil),
         {:ok, actor} <-
           ActivityPub.Actor.get_cached(pointer: info(subject, "subject"))
           |> info("subject_actor"),
         published_in_feeds <-
           Bonfire.Social.FeedActivities.feeds_for_activity(post.activity)
           |> debug("published_in_feeds"),

         # FIXME only publish to public URI if in a public enough cirlce
         # Everything is public atm
         to <-
           (if Bonfire.Boundaries.Circles.get_id!(:guest) in published_in_feeds do
              ["https://www.w3.org/ns/activitystreams#Public"]
            else
              []
            end),

         # TODO: find a better way of deleting non actor entries from the list
         # (or represent them in AP)
         mentions <-
           e(post, :tags, [])
           #  |> info("tags")
           |> Enum.reject(fn tag ->
             is_nil(e(tag, :character, nil)) or
               tag.id == ulid(subject) or
               tag.id == e(post, :created, :creator_id, nil)
           end)
           |> debug("mentions to recipients")
           |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1))
           |> filter_empty([])
           |> debug("direct_recipients"),
         # TODO: put somewhere reusable by objects other than Post
         bcc <-
           Bonfire.Boundaries.list_grants_on(post, [:see, :read])
           #  only positive grants
           |> Enum.filter(& &1.value)
           #  TODO: for circles also add the circle members to bcc
           |> Enum.map(&Map.take(&1, [:subject_id, :subject]))
           |> debug("post_grants")
           |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1.subject))
           |> filter_empty([])
           |> debug("bcc actors based on grants"),
         cc <- List.wrap(actor.data["followers"]),
         context <-
           (if e(post, :replied, :thread_id, nil) && post.replied.thread_id != id do
              with {:ok, ap_object} <-
                     ActivityPub.Object.get_cached(pointer: post.replied.thread_id) do
                ap_object.data["id"]
              else
                e ->
                  error(e, "Could not fetch the context (eg. thread)")
                  nil
              end
            end),
         to <- to ++ Enum.map(mentions, fn actor -> actor.ap_id end),
         object <-
           %{
             "type" => "Note",
             "actor" => actor.ap_id,
             "attributedTo" => actor.ap_id,
             "to" => to,
             "cc" => cc,
             "name" => e(post, :post_content, :name, nil),
             "summary" => e(post, :post_content, :summary, nil),
             "content" => Text.maybe_markdown_to_html(e(post, :post_content, :html_body, nil)),
             "attachment" => Bonfire.Files.ap_publish_activity(e(post, :media, nil)),
             # TODO support replies and context for all object types, not just posts
             "inReplyTo" =>
               if e(post, :replied, :reply_to_id, nil) && post.replied.reply_to_id != id do
                 with {:ok, ap_object} <-
                        ActivityPub.Object.get_cached(pointer: post.replied.reply_to_id) do
                   ap_object.data["id"]
                 else
                   e ->
                     error(e, "Could not fetch what is being replied to")
                     nil
                 end
               end,
             "context" => context,
             "tag" =>
               Enum.map(mentions, fn actor ->
                 %{
                   "href" => actor.ap_id,
                   "name" => actor.username,
                   "type" => "Mention"
                 }
               end)
           }
           |> Enum.filter(fn {_, v} -> not is_nil(v) end)
           |> Enum.into(%{}),
         {:ok, activity} <-
           ActivityPub.create(
             %{
               pointer: id,
               local: true,
               actor: actor,
               context: context,
               object: object,
               to: to,
               additional: %{
                 "cc" => cc,
                 "bcc" => bcc
               }
             }
             |> debug("params for ActivityPub.create")
           ) do
      {:ok, activity}
    end
  end

  @doc """
  record an incoming ActivityPub post
  """
  def ap_receive_activity(creator, activity, object, circles \\ [])

  def ap_receive_activity(creator, activity, %{public: true} = object, []) do
    ap_receive_activity(creator, activity, object, [:guest])
  end

  # record an incoming post
  def ap_receive_activity(
        creator,
        %{data: activity_data} = _activity,
        %{data: post_data, pointer_id: id, public: is_public} = _object,
        circles
      ) do
    # debug(activity: activity)
    # debug(creator: creator)
    # debug(object: object)

    direct_recipients =
      (List.wrap(activity_data["to"]) ++
         List.wrap(activity_data["cc"]) ++
         List.wrap(activity_data["audience"]) ++
         List.wrap(post_data["to"]) ++
         List.wrap(post_data["cc"]) ++
         List.wrap(post_data["audience"]))
      |> filter_empty([])
      |> List.delete(Bonfire.Federate.ActivityPub.AdapterUtils.public_uri())
      |> info("incoming recipients")
      |> Enum.map(fn ap_id -> Bonfire.Me.Users.by_ap_id!(ap_id) end)
      |> info("incoming users")
      |> ulid()
      |> filter_empty([])

    reply_to = post_data["inReplyTo"] || activity_data["inReplyTo"]

    reply_to_id =
      if reply_to,
        do:
          reply_to
          |> info()
          |> ActivityPub.Object.get_cached!(ap_id: ...)
          |> e(:pointer_id, nil)

    tags =
      (List.wrap(activity_data["tag"]) ++
         List.wrap(post_data["tag"]))
      |> Enum.uniq()

    mentions =
      for %{"type" => "Mention"} = mention <- tags do
        with {:ok, character} <-
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(
                 mention["href"] || mention["namne"]
               ) do
          character
        else
          e ->
            warn(e, "could not lookup incoming mention")
            nil
        end
      end
      |> filter_empty(nil)
      |> info("incoming mentions")

    # FIXME?
    # TODO, in a mixin?
    # FIXME
    attrs =
      info(
        %{
          id: id,
          local: false,
          canonical_url: nil,
          to_circles: circles ++ direct_recipients,
          mentions: mentions,
          post_content: %{
            name: post_data["name"],
            html_body: post_data["content"]
          },
          created: %{
            date: post_data["published"]
          },
          reply_to_id: reply_to_id,
          uploaded_media: Bonfire.Files.ap_receive_attachments(creator, post_data["attachment"])
        },
        "post attrs"
      )

    info(is_public, "is_public")

    if is_public == false and is_list(mentions) and length(mentions) > 0 do
      info("treat as Message if private with @ mentions")
      Bonfire.Social.Messages.send(creator, attrs)
    else
      boundary = if(is_public, do: "federated", else: "mentions") |> info("boundary")

      publish(
        current_user: creator,
        post_attrs: attrs,
        boundary: boundary,
        post_id: id
      )
    end
  end

  # TODO: rewrite to take a post instead of an activity?
  def indexing_object_format(post, opts \\ []) do
    # current_user = current_user(opts)

    case post do
      %{
        # The indexer is written in terms of the inserted object, so changesets need fake inserting
        id: id,
        post_content: content,
        activity: %{
          subject: %{profile: profile, character: character} = activity
        }
      } ->
        indexable(id, content, activity, profile, character)

      %{
        id: id,
        post_content: content,
        created: %{creator: %{id: _} = creator},
        activity: activity
      } ->
        indexable(
          id,
          content,
          activity,
          e(creator, :profile, nil),
          e(creator, :character, nil)
        )

      %{
        id: id,
        post_content: content,
        activity: %{subject_id: subject_id} = activity
      } ->
        # FIXME: we should get the creator/subject from the data
        creator = Bonfire.Me.Users.by_id(subject_id)

        indexable(
          id,
          content,
          activity,
          e(creator, :profile, nil),
          e(creator, :character, nil)
        )

      _ ->
        error("Posts: no clause match for function indexing_object_format/3")
        debug(post)
        nil
    end
  end

  defp indexable(id, content, activity, profile, character) do
    # "url" => path(post),
    %{
      "id" => id,
      "index_type" => "Bonfire.Data.Social.Post",
      "post_content" => PostContents.indexing_object_format(content),
      "created" => Bonfire.Me.Integration.indexing_format_created(profile, character),
      "tags" => Tags.indexing_format_tags(activity)
    }
  end
end
