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
  alias Bonfire.Boundaries.Verbs


  # def queries_module, do: Message
  def context_module, do: Message

  def federation_module, do: [{"Create", "ChatMessage"}, {"Delete", "ChatMessage"}]

  def draft(creator, attrs) do
    # TODO: create as private
    with {:ok, message} <- create(creator, attrs, "message") do
      {:ok, message}
    end
  end

  def send(%{id: _} = creator, attrs, to \\ nil) do

    # debug(attrs)
    repo().transact_with(fn ->
      with to when is_list(to) and length(to) > 0 <- to || Utils.e(attrs, :to_circles, nil),
           {:ok, to_characters} <- Characters.get(to),
           preset_or_custom_boundary <- [
              boundary: "message",
              to_circles: to_characters,
              to_feeds: Feeds.feed_ids(:inbox, to) #|> debug()
            ],
          {:ok, message} <- create(creator, Map.put(attrs, :tags, to_characters), preset_or_custom_boundary) do
        # with {:ok, activity} <- FeedActivities.notificate(creator, :create, message, preset_or_custom_boundary) do
        with {:ok, activity} <- FeedActivities.notify_feeds(creator, :create, message, preset_or_custom_boundary[:to_feeds]) do
          {:ok, Activities.activity_under_object(activity)}
        else e ->
          debug(e, "Could not notify")
          {:ok, message}
        end
      else e ->
        debug(e)
        {:error, "Oops, could not send the message."}
      end
    end)
  end


  defp create(%{id: creator_id} = creator, attrs, preset_or_custom_boundary \\ []) do
    # we attempt to avoid entering the transaction as long as possible.
    changeset = changeset(:create, attrs, creator, preset_or_custom_boundary)
    repo().transact_with(fn -> repo().insert(changeset) end)
  end

  def changeset(:create, attrs, creator, preset_or_custom_boundary \\ []) do

    attrs
    # |> debug("attrs")
    |> Message.changeset(%Message{}, ...)
    |> PostContents.cast(attrs, creator, preset_or_custom_boundary) # process text (must be done before Objects.cast)
    |> Objects.cast(attrs, creator, preset_or_custom_boundary) # deal with threading, tagging, boundaries, activities, etc.
  end

  def read(message_id, socket_or_current_user) when is_binary(message_id) do

    current_user = Utils.current_user(socket_or_current_user)

    with {:ok, message} <- Message |> query_filter(id: message_id)
      |> Activities.read(socket_or_current_user) do

        {:ok, message}
      end
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list(current_user, with_user \\ nil, cursor_after \\ nil, preloads \\ :all)

  def list(%{id: current_user_id} = current_user, with_user, cursor_after, preloads) when ( is_binary(with_user) or is_list(with_user) or is_map(with_user) ) and with_user != current_user_id and with_user != current_user do
    # all messages between two people

    with_user_id = Utils.ulid(with_user)

    if with_user_id && with_user_id != current_user_id, do: [
      messages_involving: {{with_user_id, current_user_id}, &filter/3},
      # distinct: {:threads, &Bonfire.Social.Threads.filter/3}
    ]
    # |> debug(label: "list message filters")
    |> list_paginated(current_user, cursor_after, preloads),
    else: list(current_user, nil, cursor_after, preloads)

  end

  def list(%{id: current_user_id} = current_user, _, cursor_after, preloads) do
    # all current_user's message

    [
      messages_involving: {current_user_id, &filter/3},
      # distinct: {:threads, &Bonfire.Social.Threads.filter/3}
    ]
    # |> debug(label: "my messages filters")
    |> list_paginated(current_user, cursor_after, preloads)
  end

  def list(_current_user, _with_user, _cursor_before, _preloads), do: []

  def list_paginated(filters, current_user \\ nil, cursor_after \\ nil, preloads \\ :all, query \\ Message) do

    query
      # add assocs needed in timelines/feeds
      # |> join_preload([:activity])
      # |> debug(label: "pre-preloads")
      |> Activities.activity_preloads(current_user, preloads)
      |> query_filter(filters)
      # |> debug(label: "message_paginated_post-preloads")
      |> Activities.as_permitted_for(current_user, [:see])
      # |> distinct([fp], [desc: fp.id, desc: fp.activity_id]) # not sure if/why needed... but possible fix for found duplicate ID for component Bonfire.UI.Social.ActivityLive in UI
      # |> order_by([fp], desc: fp.id)
      # |> debug(label: "post-permissions")
      # |> repo().many() # return all items
      |> Bonfire.Repo.many_paginated(before: cursor_after) # return a page of items (reverse chronological) + pagination metadata
      # |> debug(label: "feed")
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
        "type" => "ChatMessage",
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
