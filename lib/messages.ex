defmodule Bonfire.Social.Messages do
  use Arrows
  use Bonfire.Common.Repo
  use Bonfire.Common.Utils
  import Untangle

  alias Bonfire.Data.Social.Message
  alias Bonfire.Data.Social.PostContent
  alias Bonfire.Data.Social.Replied

  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Objects

  alias Bonfire.Me.Characters
  # alias Bonfire.Boundaries.Verbs
  alias Ecto.Changeset
  # import Bonfire.Boundaries.Queries
  alias Bonfire.Social.Threads
  alias Bonfire.Social.PostContents
  alias Bonfire.Social.Tags
  alias Bonfire.Boundaries
  alias Bzonfire.Boundaries.Verbs
  alias Bonfire.Social.LivePush

  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Message

  def federation_module,
    do: [{"Create", "ChatMessage"}, {"Delete", "ChatMessage"}]

  def draft(creator, attrs) do
    # TODO: create as private
    with {:ok, message} <- create(creator, attrs, "message") do
      {:ok, message}
    end
  end

  # attempts to get the optional parameter `to` first, falls back to the attributes
  defp get_tos(nil, to_circles) when is_list(to_circles),
    do: clean_tos(to_circles)

  defp get_tos(nil, to_circles) when is_binary(to_circles),
    do: String.split(to_circles, ",") |> clean_tos()

  defp get_tos(to, _), do: clean_tos(to)

  defp clean_tos(tos), do: List.wrap(tos) |> filter_empty(nil)

  @doc """
  TODO: check boundaries, right now anyone can message anyone :/
  """
  def send(%{id: creator_id} = creator, attrs, to \\ nil) do
    opts = [current_user: creator]

    to =
      get_tos(to, Utils.e(attrs, :to_circles, nil))
      |> debug("tos")
      |> Boundaries.load_pointers(opts ++ [verb: :message])
      |> repo().maybe_preload(:character)

    # TODO: if not allowed to message, request to message?
    # |> debug("to pointers")

    if is_list(to) and length(to) > 0 do
      attrs = Map.put(attrs, :tags, to)
      # |> debug("message attrs")
      opts = [
        boundary: "message",
        verbs_to_grant: Config.get([:verbs_to_grant, :message]),
        to_circles: to,
        to_feeds: [inbox: to]
      ]

      repo().transact_with(fn ->
        with {:ok, message} <- create(creator, attrs, opts) do
          # debug(message)
          LivePush.notify_of_message(creator, :message, message, to)
          Bonfire.Social.Integration.ap_push_activity(creator.id, message)
          {:ok, message}
        end
      end)
    else
      error("Could not find recipient.")
    end
  end

  defp create(%{id: creator_id} = creator, attrs, opts \\ []) do
    # we attempt to avoid entering the transaction as long as possible.
    changeset = changeset(:create, attrs, creator, opts)
    # |> info
    repo().transact_with(fn -> repo().insert(changeset) end)
  end

  def changeset(:create, attrs, creator, opts \\ []) do
    attrs
    # |> debug("attrs")
    |> Message.changeset(%Message{}, ...)
    # before PostContents since we only want to tag `to` users, not mentions
    |> Tags.cast(attrs, creator, opts)
    # process text (must be done before Objects.cast)
    |> PostContents.cast(attrs, creator, "message", opts)
    |> Objects.cast_creator_caretaker(creator)
    # record replies & threads. preloads data that will be checked by `Acls`
    |> Threads.cast(attrs, creator, opts)
    # apply boundaries on all objects, note that ORDER MATTERS, as it uses data preloaded by `Threads` and `PostContents`
    |> Objects.cast_acl(creator, opts)
    |> Activities.put_assoc(:create, creator)
    # messages go in inbox feeds so we can easily count unread (TODO: switch to querying from inbox as well?)
    |> FeedActivities.put_feed_publishes(Keyword.get(opts, :to_feeds, []))

    # |> info()
  end

  def read(message_id, opts) when is_binary(message_id) do
    query_filter(Message, id: message_id)
    |> Activities.read(opts ++ [preload: [:posts]])
    # load audience list
    |> repo().maybe_preload(activity: [tags: [:character, profile: :icon]])
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list(current_user, with_user \\ nil, opts \\ [])

  def list(%{id: current_user_id} = current_user, with_user, opts)
      when (is_binary(with_user) or is_list(with_user) or is_map(with_user)) and
             with_user != current_user_id and with_user != current_user do
    # all messages between two people

    opts =
      to_options(opts)
      # TODO: only loads reply_to when displaying flat threads
      |> Keyword.put(
        :preload,
        if(opts[:latest_in_threads],
          do: [:posts, :with_seen],
          else: [:posts_with_reply_to, :with_seen]
        )
      )
      |> debug("opts")

    with_user_id = Utils.ulid(with_user)

    if with_user_id && with_user_id != current_user_id do
      # |> debug("list message filters")
      list_paginated(
        [
          {
            :messages_involving,
            {{with_user_id, current_user_id}, &filter/3}
          }
        ],
        current_user,
        opts
      )
    else
      list(current_user, nil, opts)
    end
  end

  def list(%{id: current_user_id} = current_user, _, opts) do
    # all current_user's message

    opts =
      to_options(opts)
      |> Keyword.put_new(:preload, [:posts, :with_seen])

    # |> debug("my messages filters")
    list_paginated(
      [
        {
          :messages_involving,
          {current_user_id, &filter/3}
        }
      ],
      current_user,
      opts
    )
  end

  def list(_current_user, _with_user, _cursor_before, _preloads), do: []

  defp list_paginated(
         filters,
         current_user \\ nil,
         opts \\ [],
         query \\ Message
       ) do
    opts =
      to_options(opts)
      |> Keyword.put(:current_user, current_user)

    if opts[:latest_in_threads] do
      list_threads_paginated(filters, current_user, opts, query)
    else
      list_messages_paginated(filters, current_user, opts, query)
    end
  end

  defp list_messages_paginated(
         filters,
         current_user \\ nil,
         opts \\ [],
         query \\ Message
       ) do
    query
    # add assocs needed in timelines/feeds
    # |> proload([:activity])
    # |> debug("pre-preloads")
    |> Activities.activity_preloads(opts)
    |> query_filter(filters)
    # |> debug("message_paginated_post-preloads")
    |> Activities.as_permitted_for(current_user, [:see, :read])
    |> debug("post preloads & permissions")
    # |> repo().many() # return all items
    # return a page of items (reverse chronological) + pagination metadata
    |> Bonfire.Common.Repo.many_paginated(opts)

    # |> debug("result")
  end

  defp list_threads_paginated(
         filters,
         current_user \\ nil,
         opts \\ [],
         query \\ Message
       ) do
    # paginate = if opts[:paginate], do: Keyword.new(opts[:paginate]), else: opts

    # opts = opts
    # |> Keyword.put(:paginate, paginate
    #                           |> Keyword.put(:cursor_fields, [{:thread_id, :desc}])
    #   )
    # debug(opts)

    filters = filters ++ [distinct: {:threads, &Threads.filter/3}]

    query
    # add assocs needed in timelines/feeds
    # |> proload([:activity])
    # |> debug("pre-preloads")
    # |> Activities.activity_preloads(opts)
    |> query_filter(filters)
    # |> debug("message_paginated_post-preloads")
    |> Activities.as_permitted_for(current_user, [:see, :read])
    |> Threads.re_order_using_subquery(opts)
    # |> debug("post preloads & permissions")
    # |> repo().many() # return all items
    # return a page of items (reverse chronological) + pagination metadata
    |> Bonfire.Common.Repo.many_paginated(opts)
    # |> Threads.maybe_re_order_result(opts)
    |> Activities.activity_preloads(opts)

    # |> debug("result")
  end

  def filter(:messages_involving, {user_id, _current_user_id}, query)
      when is_binary(user_id) do
    # messages between current user & someone else

    query
    |> reusable_join(:left, [root], assoc(root, :activity), as: :activity)
    |> reusable_join(:left, [activity: activity], assoc(activity, :tagged), as: :tagged)
    |> where(
      [activity: activity, tagged: tagged],
      # and activity.subject_id == ^current_user_id # shouldn't be needed if boundaries does the filtering
      tagged.tag_id == ^user_id or activity.subject_id == ^user_id

      # and tags.id == ^current_user_id # shouldn't be needed if boundaries does the filtering
    )
  end

  def filter(:messages_involving, _user_id, query) do
    # current_user's messages
    # relies only on boundaries to filter which messages to show so no other filtering needed
    query
  end

  def ap_publish_activity("create", message) do
    message = repo().preload(message, activity: [:tags])

    {:ok, actor} =
      ActivityPub.Adapter.get_actor_by_id(Utils.e(message, :created, :creator_id, nil))

    # debug(message.activity.tags)

    # TODO: extensible
    recipient_types = [Bonfire.Data.Identity.User.__pointers__(:table_id)]

    recipients =
      Enum.filter(message.activity.tags, fn tag ->
        tag.table_id in recipient_types
      end)
      |> Enum.map(fn tag -> ActivityPub.Actor.get_by_local_id!(tag.id) end)
      |> Enum.map(fn actor -> actor.ap_id end)

    object = %{
      # "ChatMessage", # TODO: use ChatMessage with peers that support it?
      "type" => "Note",
      "actor" => actor.ap_id,
      "content" => Utils.e(message, :post_content, :html_body, nil),
      "to" => recipients
    }

    attrs = %{
      actor: actor,
      context: ActivityPub.Utils.generate_context_id(),
      object: object,
      to: recipients
    }

    ActivityPub.create(attrs, message.id)
  end

  def ap_receive_activity(creator, activity, object) do
    with {:ok, messaged} <- Bonfire.Me.Users.by_ap_id(hd(activity.data["to"])) do
      attrs = %{
        to_circles: [messaged.id],
        post_content: %{html_body: object.data["content"]}
      }

      Bonfire.Social.Messages.send(creator, attrs)
    end
  end
end
