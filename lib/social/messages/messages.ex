defmodule Bonfire.Social.Messages do
  use Arrows
  use Bonfire.Repo
  use Bonfire.Common.Utils
  import Where

  alias Bonfire.Data.Social.{Message, PostContent, Replied}
  alias Bonfire.Social.{Activities, FeedActivities, Feeds, Objects}
  alias Bonfire.Me.Characters
  # alias Bonfire.Boundaries.Verbs
  alias Ecto.Changeset
  # import Bonfire.Boundaries.Queries
  alias Bonfire.Social.Threads
  alias Bonfire.Social.PostContents
  alias Bonfire.Boundaries
  alias Bzonfire.Boundaries.Verbs
  alias Bonfire.Social.LivePush

  # def queries_module, do: Message
  def context_module, do: Message

  def federation_module, do: [{"Create", "ChatMessage"}, {"Delete", "ChatMessage"}]

  def draft(creator, attrs) do
    # TODO: create as private
    with {:ok, message} <- create(creator, attrs, "message") do
      {:ok, message}
    end
  end

  # attempts to get the optional parameter `to` first, falls back to the attributes
  defp get_tos(to, attrs), do: with(nil <- get_to(to), do: get_to(Utils.e(attrs, :to_circles, nil)))

  defp get_to(tos), do: List.wrap(tos) |> filter_empty(nil) |> debug

  @doc """
  TODO: check boundaries, right now anyone can message anyone :/
  """
  def send(%{id: _} = creator, attrs, to \\ nil) do
    debug(attrs)
    opts = [current_user: creator]

    to = get_tos(to, attrs)
    |> debug("tos")
    |> Boundaries.load_pointers(opts ++ [verb: :message])
    |> debug("to pointers")

    if is_list(to) and length(to)>0 do
      opts = [
        boundary: "message",
        verbs_to_grant: Config.get(:verbs_eyes_only_reply) |> debug(),
        to_circles: to,
        to_feeds: [inbox: to]
      ]
      attrs = Map.put(attrs, :tags, to)
      repo().transact_with fn ->
        with {:ok, message} <- create(creator, attrs, opts) do
          LivePush.notify(creator, "message", message, opts[:to_feeds])
          Bonfire.Social.Integration.ap_push_activity(creator.id, message)
          {:ok, message}
        end
      end
    else
      error("Could not find recipient.")
    end
  end

  defp create(%{id: creator_id} = creator, attrs, opts \\ []) do
    # we attempt to avoid entering the transaction as long as possible.
    changeset = changeset(:create, attrs, creator, opts)
    |> info
    repo().transact_with(fn -> repo().insert(changeset) end)
  end

  def changeset(:create, attrs, creator, opts \\ []) do
    attrs
    # |> debug("attrs")
    |> Message.changeset(%Message{}, ...)
    |> PostContents.cast(attrs, creator, opts) # process text (must be done before Objects.cast)
    |> Objects.cast(attrs, creator, opts) # threading, tagging, boundaries, creator, caretaker
    |> Activities.put_assoc(:create, creator)
    |> FeedActivities.put_feed_publishes(Keyword.get(opts, :to_feeds, []))
    # |> dump
  end

  def read(message_id, opts) when is_binary(message_id) do
    query_filter(Message, id: message_id)
    |> Activities.read(opts)
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list(current_user, with_user \\ nil, opts \\ [])

  def list(%{id: current_user_id} = current_user, with_user, opts)
    when ( is_binary(with_user) or is_list(with_user) or is_map(with_user) )
    and with_user != current_user_id and with_user != current_user do
    # all messages between two people
    with_user_id = Utils.ulid(with_user)
    if with_user_id && with_user_id != current_user_id, do: [
      messages_involving: {{with_user_id, current_user_id}, &filter/3},
    ]
    # |> debug("list message filters")
    |> list_paginated(current_user, opts),
    else: list(current_user, nil, opts)
  end

  def list(%{id: current_user_id} = current_user, _, opts) do
    # all current_user's message
    [
      messages_involving: {current_user_id, &filter/3},
    ]
    # |> debug("my messages filters")
    |> list_paginated(current_user, opts)
  end

  def list(_current_user, _with_user, _cursor_before, _preloads), do: []

  defp list_paginated(filters, current_user \\ nil, opts \\ [], query \\ Message) do
    query
      # add assocs needed in timelines/feeds
      # |> join_preload([:activity])
      # |> debug("pre-preloads")
      |> Activities.activity_preloads([current_user: current_user], :all)
      |> query_filter(filters ++ [distinct: {:threads, &Bonfire.Social.Threads.filter/3}])
      # |> debug("message_paginated_post-preloads")
      |> Activities.as_permitted_for(current_user, [:see, :read])
      # |> distinct([fp], [desc: fp.id, desc: fp.activity_id]) # not sure if/why needed... but possible fix for found duplicate ID for component Bonfire.UI.Social.ActivityLive in UI
      # |> order_by([fp], desc: fp.id)
      # |> debug("post-permissions")
      # |> repo().many() # return all items
      |> Bonfire.Repo.many_paginated(opts) # return a page of items (reverse chronological) + pagination metadata
      # |> debug("feed")
  end

    #doc "List messages "
  def filter(:messages_involving, {user_id, _current_user_id}, query) when is_binary(user_id) do
    # messages between current user & someone else

    query
    |> join_preload([:activity, :object, :tags])
    |> where(
      [activity: activity, tags: tags],
      (
        (
          tags.id == ^user_id
          # and activity.subject_id == ^current_user_id # shouldn't be needed if boundaries does the filtering
        ) or (
          activity.subject_id == ^user_id
          # and tags.id == ^current_user_id # shouldn't be needed if boundaries does the filtering
        )
      )
    )
  end

  def filter(:messages_involving, _user_id, query) do
    # current_user's messages
    # relies only on boundaries to filter which messages to show so no other filtering needed
    query
  end

  def ap_publish_activity("create", message) do
    message = repo().preload(message, [activity: [:tags]])
    {:ok, actor} = ActivityPub.Adapter.get_actor_by_id(Utils.e(message, :created, :creator_id, nil))
    # debug(message.activity.tags)
    recipients =
      Enum.filter(message.activity.tags, fn tag -> tag.table_id == "5EVSER1S0STENS1B1YHVMAN01D" end)
      |> Enum.map(fn tag -> ActivityPub.Actor.get_by_local_id!(tag.id) end)
      |> Enum.map(fn actor -> actor.ap_id end)

    object = %{
      "type" => "Note", #"ChatMessage", # TODO: use ChatMessage with peers that support it?
      "actor" => actor.ap_id,
      "content" => (Utils.e(message, :post_content, :html_body, nil)),
      "to" => recipients
    }
    attrs = %{
      actor: actor,
      context: ActivityPub.Utils.generate_context_id(),
      object: object,
      to: recipients,
    }
    ActivityPub.create(attrs, message.id)
  end

  def ap_receive_activity(creator, activity, object) do
    with {:ok, messaged} <- Bonfire.Me.Users.by_ap_id(hd(activity.data["to"])) do
      attrs = %{to_circles: [messaged.id], post_content: %{html_body: object.data["content"]}}
      Bonfire.Social.Messages.send(creator, attrs)
    end
  end
end
