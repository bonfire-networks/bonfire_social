defmodule Bonfire.Social.Posts do
  use Arrows
  import Untangle
  import Bonfire.Boundaries.Queries
  alias Bonfire.Data.Social.Post
  # alias Bonfire.Data.Social.PostContent
  # alias Bonfire.Data.Social.Replied
  # alias Bonfire.Data.Social.Activity

  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social.Objects

  # alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Verbs

  alias Bonfire.Epics.Epic
  alias Bonfire.Social.Integration
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

    # TODO: should we only delete the PostContent and the activity? so as to preserve thread and nesting integrity

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
    env = Config.env()

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
    debug(attrs, "IVAAAAAAA")
    # FIXME: find a less nasty way (this is to support graceful degradation with the textarea inside noscript)
    deep_merge(
      attrs,
      %{
        post: %{
          post_content: %{
            html_body:
              e(attrs, :html_body, nil) || e(attrs, :post, :post_content, :html_body, nil) ||
                e(attrs, :fallback_post, :post_content, :html_body, nil)
          }
        }
      }
    )
  end

  def read(post_id, opts_or_socket_or_current_user \\ [])
      when is_binary(post_id) do
    with {:ok, post} <-
           query([id: post_id], opts_or_socket_or_current_user)
           |> Activities.read_query(opts_or_socket_or_current_user)
           |> Objects.as_permitted_for(opts_or_socket_or_current_user)
           |> repo().single() do
      {:ok, Activities.activity_under_object(post)}
    end
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, opts \\ []) do
    # query FeedPublish
    # [posts_by: {by_user, &filter/3}]
    filter(:posts_by, by_user, Post)
    |> list_paginated(to_options(opts) ++ [subject_user: by_user])
  end

  @doc "List posts with pagination"
  def list_paginated(filters, opts \\ [])

  def list_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    filters
    # |> debug("filters")
    |> query_paginated(opts)
    |> FeedActivities.feed_many_paginated(opts)
  end

  @doc "Query posts with pagination"
  def query_paginated(filters, opts \\ [])

  def query_paginated(filters, opts)
      when is_list(filters) or is_struct(filters) do
    # |> debug("filters")
    Objects.list_query(filters, opts)
    # |> proload([:post_content])

    # |> FeedActivities.query_paginated(opts, Post)
    # |> debug("after FeedActivities.query_paginated")
  end

  # query_paginated(filters \\ [], current_user_or_socket_or_opts \\ [],  query \\ FeedPublish)
  def query_paginated({a, b}, opts), do: query_paginated([{a, b}], opts)

  def query(filters \\ [], opts \\ nil)

  def query(filters, opts) when is_list(filters) or is_tuple(filters) do
    base_query(filters, opts)
    |> boundarise(main_object.id, opts)
  end

  defp base_query(filters, _opts) when is_list(filters) or is_tuple(filters) do
    from(main_object in Post, as: :main_object)
    |> proload([:post_content])
    |> query_filter(filters, nil, nil)
  end

  # doc "List posts created by the user and which are in their outbox, which are not replies"
  def filter(:posts_by, user, query) do
    # user = repo().maybe_preload(user, [:character])
    verb_id = Verbs.get_id!(:create)

    query
    |> proload(activity: [:object, :replied])
    |> where(
      [activity: activity, replied: replied],
      is_nil(replied.reply_to_id) and
        activity.verb_id == ^verb_id and
        activity.subject_id == ^ulid(user)
    )
  end

  # TODO: federated delete, in addition to create:
  def ap_publish_activity(subject, _verb, post) do
    # TODO: get from config
    public_acl_ids = Bonfire.Boundaries.Acls.remote_public_acl_ids()

    id = ulid!(post)

    post =
      post
      |> repo().maybe_preload([
        :post_content,
        :media,
        :created,
        :sensitive,
        replied: [thread: [:created], reply_to: [:created]],
        tags: [:character]
      ])
      |> Activities.object_preload_create_activity()

    # |> debug("post to federate")

    subject =
      subject ||
        Utils.e(post, :created, :creator, nil) ||
        Utils.e(post, :created, :creator_id, nil) || Utils.e(post, :activity, :subject, nil) ||
        Utils.e(post, :activity, :subject_id, nil)

    thread_id = e(post, :replied, :thread_id, nil)

    thread_creator =
      e(post, :replied, :thread, :created, :creator, nil) ||
        e(post, :replied, :thread, :created, :creator_id, nil)

    reply_to_creator =
      (e(post, :replied, :reply_to, :created, :creator, nil) ||
         e(post, :replied, :reply_to, :created, :creator_id, nil))
      |> debug("reply_to_creator")

    # TODO: should we just include ALL thread participants? ^

    # FIXME: use `get_preset_on_object` instead of loading them all
    acls = Bonfire.Boundaries.list_object_acls(post)
    # |> debug("acls")

    is_public = Enum.any?(acls, fn %{id: acl_id} -> acl_id in public_acl_ids end)

    to =
      if is_public do
        ["https://www.w3.org/ns/activitystreams#Public"]
      else
        []
      end

    with {:ok, actor} <-
           ActivityPub.Actor.get_cached(pointer: subject),

         # TODO: find a better way of deleting non-actor entries from the list
         # (or better: represent them in AP)
         # Note: `mentions` preset adds grants to mentioned people which should trigger the boundaries-based logic in `Adapter.external_followers_for_activity`, so should we use this only for tagging and not for addressing (if we expand the scope of that function beyond followers)?
         mentions <-
           e(post, :tags, [])
           #  |> info("tags")
           |> Enum.reject(fn tag ->
             is_nil(e(tag, :character, nil)) or id(tag) == id(subject)
           end)
           |> debug("mentions to tags")
           |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1))
           |> filter_empty([])
           |> debug("include_as_tags"),
         # TODO: put much of this logic somewhere reusable by objects other than Post, eg `Bonfire.Federate.ActivityPub.AdapterUtils.determine_recipients/4`
         # TODO: add a followers-only preset?
         #  (if is_public do
         #     mentions ++ List.wrap(actor.data["followers"])
         #   else
         cc <-
           [reply_to_creator, thread_creator]
           #  |> info("tags")
           |> Enums.uniq_by_id()
           |> Enum.reject(fn u ->
             id(u) == id(subject)
           end)
           |> Enum.map(&ActivityPub.Actor.get_cached!(pointer: &1))
           |> Enum.concat(mentions)
           |> Enums.uniq_by_id()
           |> debug("mentions to recipients")
           |> Enum.map(& &1.ap_id)
           |> debug("direct_recipients"),
         # end),
         # FIXME: the below seems to return ALL known users for public posts?
         bcc <- [],
         context <-
           (if thread_id && thread_id != id do
              with {:ok, ap_object} <-
                     ActivityPub.Object.get_cached(pointer: thread_id) do
                ap_object.data["id"]
              else
                e ->
                  error(e, "Could not fetch the context (eg. thread)")
                  nil
              end
            end),
         #  to <- to ++ Enum.map(mentions, fn actor -> actor.ap_id end),
         object <-
           %{
             "type" => "Note",
             "actor" => actor.ap_id,
             "attributedTo" => actor.ap_id,
             "to" => to,
             "cc" => cc,
             # TODO: put somewhere reusable by other types?
             "sensitive" => e(post, :sensitive, :is_sensitive, false),
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
             # TODO: add hashtags?
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

    #  TODO: put somewhere reusable by other types
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

    #  TODO: put somewhere reusable by other types
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

    #  TODO: put somewhere reusable by other types
    mentions =
      for %{"type" => "Mention"} = mention <- tags do
        url =
          (mention["href"] || "")
          # workaround for Mastodon using different URLs in text
          |> String.replace("/users/", "/@")

        with {:ok, character} <-
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(
                 mention["href"] || mention["name"]
               ) do
          {
            url,
            character
          }
        else
          e ->
            info(e, "could not find known actor for incoming mention")

            {
              url,
              mention["name"]
            }
        end
      end
      |> filter_empty([])
      |> Map.new()
      |> info("incoming mentions")

    #  TODO: put somewhere reusable by other types
    hashtags =
      for %{"type" => "Hashtag"} = tag <- tags do
        with {:ok, hashtag} <- Bonfire.Tag.Hashtag.get_or_create_by_name(tag["name"]) do
          {tag["href"], hashtag}
        else
          none ->
            warn(none, "could not create Hashtag for #{tag["name"]}")
            nil
        end
      end
      |> filter_empty([])
      |> Map.new()
      |> info("incoming hashtags")

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
          hashtags: hashtags,
          post_content: %{
            name: post_data["name"],
            html_body: post_data["content"]
          },
          created: %{
            date: post_data["published"]
          },
          sensitive: post_data["sensitive"],
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
      # FIXME: should this use mentions for remote rather than custom?
      boundary =
        if(is_public, do: "public", else: "custom")
        |> debug("set boundary")

      publish(
        local: false,
        current_user: creator,
        post_attrs: attrs,
        boundary: boundary,
        post_id: id
      )
    end
  end

  # TODO: rewrite to take a post instead of an activity?
  def indexing_object_format(post, _opts \\ []) do
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

  def count_total(), do: repo().one(select(Post, [u], count(u.id)))
end
