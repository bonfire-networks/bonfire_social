defmodule Bonfire.Social.Posts do

  use Arrows
  alias Bonfire.Data.Social.{Post, PostContent, Replied, Activity}
  alias Bonfire.Social.{Activities, FeedActivities, Objects}
  alias Bonfire.Boundaries.{Circles, Verbs}
  alias Bonfire.Social.{Integration, PostContents, Tags, Threads}
  alias Ecto.Changeset

  use Bonfire.Repo,
      schema: Post,
      searchable_fields: [:id],
      sortable_fields: [:id]

  import Bonfire.Common.Utils

  # import Bonfire.Boundaries.Queries

  def queries_module, do: Post
  def context_module, do: Post
  def federation_module, do: [{"Create", "Note"}, {"Update", "Note"}, {"Create", "Article"}, {"Update", "Article"}]

  def draft(creator, attrs) do
    # TODO: create as private
    # with {:ok, post} <- create(creator, attrs) do
    #   {:ok, post}
    # end
  end

  def publish(%{id: _} = creator, attrs, preset_boundary \\ nil) do
    # we attempt to avoid entering the transaction as long as possible.
    changeset = changeset(:create, attrs, creator, preset_boundary)
    repo().transact_with(fn -> repo().insert(changeset) ~>
      FeedActivities.publish(creator, :create, ..., preset_boundary) ~> # TODO: move to changeset, at least for DB publishing
      maybe_index()
    end)
  end


  # def reply(creator, attrs) do
  #   with  {:ok, published} <- publish(creator, attrs),
  #         {:ok, r} <- get_replied(published.post.id) do
  #     reply = Map.merge(r, published)
  #     # |> IO.inspect

  #     pubsub_broadcast(e(reply, :thread_id, nil), {{Bonfire.Social.Posts, :new_reply}, reply}) # push to online users

  #     {:ok, reply}
  #   end
  # end

  def changeset(:create, attrs, creator \\ nil, preset \\ nil) do
    creator_id = e(creator, :id, nil)

    attrs
    |> if(is_nil(creator_id), do: ..., else: Map.put(..., :created, %{creator_id: creator_id}))
    # |> IO.inspect(label: "Posts.changeset:attrs")
    |> Post.changeset(%Post{}, ...)
    |> if(is_nil(creator_id), do: ..., else: Changeset.cast_assoc(..., :created))
    |> PostContents.cast(attrs, creator, preset)
    |> Threads.cast(attrs, creator, preset)
    |> Tags.cast(attrs, creator, preset)
    |> Bonfire.Me.Acls.cast(creator, preset)
    # |> Activities.cast(creator, :create, preset) # TODO
    # |> FeedActivities.cast(creator, :create, preset) # TODO
  end

  def read(post_id, opts_or_socket_or_current_user \\ [], preloads \\ :all) when is_binary(post_id) do
    with {:ok, post} <- base_query([id: post_id], opts_or_socket_or_current_user, preloads)
      |> Activities.read(opts_or_socket_or_current_user) do
        {:ok, Activities.activity_under_object(post) }
      end
  end

  @doc """
  For internal use only (doesn't check permissions). Use `read` instead.
  """
  def get(id) when is_binary(id), do: repo().single(get_query(id))

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, opts_or_current_user \\ [], preloads \\ :all) do

    # query FeedPublish
    [feed_id: by_user, posts_by: {ulid(by_user), &filter/3}]
    |> list_paginated(opts_or_current_user, preloads)
  end

  @doc "List posts with pagination"
  def list_paginated(filters, opts_or_current_user \\ [], preloads \\ :all)
  def list_paginated(filters, opts_or_current_user, preloads) when is_list(filters) do
    filters
    # |> IO.inspect(label: "Posts.list_paginated:filters")
    |> query_paginated(opts_or_current_user, preloads)
    |> FeedActivities.feed_paginated(opts_or_current_user, filters, preloads)
  end

  @doc "Query posts with pagination"
  def query_paginated(filters, opts_or_current_user \\ [], preloads \\ :all)
  def query_paginated(filters, opts_or_current_user, preloads) when is_list(filters) do
    filters
    # |> IO.inspect(label: "Posts.query_paginated:filters")
    |> Keyword.drop([:paginate])
    |> FeedActivities.query_paginated(opts_or_current_user, filters, preloads)
  end
  def query_paginated({a,b}, opts_or_current_user, preloads), do: query_paginated([{a,b}], opts_or_current_user, preloads)

  def query(filters \\ [], opts_or_current_user \\ nil, preloads \\ :all)

  def query(filters, opts_or_current_user, preloads) when is_list(filters) or is_tuple(filters) do

    q = base_query(filters, opts_or_current_user, preloads)
        |> join_preload([:post_content])

    maybe_apply(Bonfire.Boundaries.Queries, :object_only_visible_for, [q, opts_or_current_user], q)
  end

  defp base_query(filters, opts_or_current_user, preloads) when is_list(filters) or is_tuple(filters) do
    (from p in Post, as: :main_object)
    |> query_filter(filters, nil, nil)
  end

  #doc "List posts created by the user and which are in their outbox, which are not replies"
  def filter(:posts_by, user_id, query) when is_binary(user_id) do
    verb_id = Verbs.get_id!(:create)
    query
    |> proload(activity: [object: {"object_", [:post, :created, :replied]}])
    |> where(
      [activity: activity, object_post: post, object_created: created, object_replied: replied],
      is_nil(replied.reply_to_id) and not is_nil(post.id)
      and activity.verb_id==^verb_id and created.creator_id == ^user_id
    )
  end

  def get_query(id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     left_join: re in assoc(p, :replied),
     left_join: rt in assoc(re, :reply_to),
     where: p.id == ^id,
     preload: [post_content: pc, created: cr, replied: {re, [reply_to: rt]}]
  end

  defp by_user(user_id), do: repo().many(by_user_query(user_id))

  defp by_user_query(user_id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     where: cr.creator_id == ^user_id,
     preload: [post_content: pc, created: cr]
  end

  def ap_publish_activity("create", post) do

    post = post
    |> repo().maybe_preload([:created, :replied, :post_content])
    |> Activities.object_preload_create_activity()
    # |> IO.inspect(label: "ap_publish_activity post")

    {:ok, actor} = ActivityPub.Adapter.get_actor_by_id(e(post, :activity, :subject_id, nil) || e(post, :created, :creator_id, nil))

    #FIXME only publish to public URI if in a public enough cirlce
    #Everything is public atm
    to =
      # if Bonfire.Boundaries.Circles.circles[:guest] in Bonfire.Social.FeedActivities.feeds_for_activity(post.activity) do
        ["https://www.w3.org/ns/activitystreams#Public"]
      # else
      #  []
      # end

    # TODO: find a better way of deleting non actor entries from the list
    # (or represent them in AP)
    direct_recipients =
      Bonfire.Social.FeedActivities.feeds_for_activity(post.activity)
      |> List.delete(e(post, :activity, :subject_id, nil) || e(post, :created, :creator_id, nil))
      |> List.delete(Bonfire.Boundaries.Circles.circles[:guest])
      |> Enum.map(fn id -> ActivityPub.Actor.get_by_local_id!(id) end)
      |> Enum.filter(fn x -> not is_nil(x) end)
      |> Enum.map(fn actor -> actor.ap_id end)

    cc = [actor.data["followers"]]

    object = %{
      "type" => "Note",
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "name" => (e(post, :post_content, :name, nil)),
      "summary" => (e(post, :post_content, :summary, nil)),
      "content" => (e(post, :post_content, :html_body, nil)),
      "to" => to ++ direct_recipients,
      "cc" => cc
    }
      |> Enum.filter(fn {_, v} -> not is_nil(v) end)
      |> Enum.into(%{})

    object =
      if e(post, :replied, :reply_to_id, nil) do
        ap_object = ActivityPub.Object.get_cached_by_pointer_id(post.replied.reply_to_id)
        Map.put(object, "inReplyTo", ap_object.data["id"])
      else
        object
      end

    attrs = %{
      actor: actor,
      context: ActivityPub.Utils.generate_context_id(),
      object: object,
      to: to ++ direct_recipients,
      additional: %{
        "cc" => cc
      }
    }

    ActivityPub.create(attrs, post.id)
  end

  @doc """
  record an incoming post
  """
  def ap_receive_activity(creator, activity, object, circles \\ [])

  def ap_receive_activity(creator, activity, %{public: true} = object, []) do
    ap_receive_activity(creator, activity, object, [:guest])
  end

  def ap_receive_activity(creator, %{data: _activity_data} = _activity, %{data: post_data} = _object, circles) do # record an incoming post
    # IO.inspect(activity: activity)
    # IO.inspect(creator: creator)
    # IO.inspect(object: object)

    direct_recipients = post_data["to"] || []

    direct_recipients =
      direct_recipients
      |> List.delete(Bonfire.Federate.ActivityPub.Utils.public_uri())
      |> Enum.map(fn ap_id -> Bonfire.Me.Users.by_ap_id!(ap_id) end)
      |> Enum.filter(fn x -> not is_nil(x) end)
      |> Enum.map(fn user -> user.id end)

    attrs = %{
      local: false, # FIXME?
      canonical_url: nil, # TODO, in a mixin?
      to_circles: circles ++ direct_recipients,
      post_content: %{
        name: post_data["name"],
        html_body: post_data["content"]
      },
      created: %{
        date: post_data["published"] # FIXME
      }
    }

    attrs =
      if post_data["inReplyTo"] do
        case ActivityPub.Object.get_cached_by_ap_id(post_data["inReplyTo"]) do
          nil -> attrs
          object -> Map.put(attrs, :reply_to_id, object.pointer_id)
        end
      else
        attrs
      end

    with {:ok, post} <- publish(creator, attrs, "public") do
      # IO.inspect(remote_post: post)
      {:ok, post}
    end
  end


  def indexing_object_format(feed_activity_or_activity, object \\ nil)
  def indexing_object_format(%{subject: %{profile: subject_profile, character: subject_character}} = activity, %{id: id, post_content: post_content} = post) do

    # IO.inspect(obj)

    %{
      "id" => id,
      "index_type" => "Bonfire.Data.Social.Post",
      # "url" => path(post),
      "post_content" => PostContents.indexing_object_format(post_content),
      "creator" => Bonfire.Me.Integration.indexing_format(subject_profile, subject_profile),
      "tag_names" => Tags.indexing_format_tags(activity)
    } #|> IO.inspect
  end
  def indexing_object_format(%{activity: %{object: object} = activity}, nil), do: indexing_object_format(activity, object)
  def indexing_object_format(%Activity{object: object} = activity, nil), do: indexing_object_format(activity, object)
  def indexing_object_format(a, b) do
    Logger.error("Posts: could not indexing_object_format")
    IO.inspect(a)
    IO.inspect(b)
    nil
  end

  def maybe_index(object) do
    indexing_object_format(object) |> Bonfire.Social.Integration.maybe_index()
    {:ok, object}
  end


end
