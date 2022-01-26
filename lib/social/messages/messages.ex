defmodule Bonfire.Social.Messages do
  use Arrows
  use Bonfire.Repo
  use Bonfire.Common.Utils

  alias Bonfire.Data.Social.{Message, PostContent, Replied}
  alias Bonfire.Social.{Activities, FeedActivities, Feeds, Objects}
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
    with {:ok, message} <- create(creator, attrs) do
      {:ok, message}
    end
  end

  def send(%{id: _} = creator, attrs, to \\ nil) do
    #IO.inspect(attrs)
    repo().transact_with(fn ->
      with to when is_list(to) and length(to) > 0 <- to || Utils.e(attrs, :to_circles, nil),
           {:ok, message} <- create(creator, attrs, to) do
        with {:ok, activity} <- FeedActivities.notificate(creator, :create, message, [cur) do
          {:ok, Activities.activity_under_object(activity)}
        else e ->
          IO.inspect(could_not_notify: e)
          {:ok, message}
        end
      else e ->
        debug(e)
        {:error, "Did not send the message. Make sure you indicate who to send it to."}
      end
    end)
  end


  defp create(%{id: creator_id} = creator, attrs, to \\ []) do
    # we attempt to avoid entering the transaction as long as possible.
    changeset = changeset(:create, attrs, creator, to)
    repo().transact_with(fn -> repo().insert(changeset) end)
  end

  def changeset(:create, attrs, creator, to) do

    preset_or_custom_boundary = [
      preset: "message",
      to_circles: ulid(to),
      to_feeds: Feeds.feed_ids(:inbox, to) |> debug()
    ]

    attrs
    # |> debug("attrs")
    |> Message.changeset(%Message{}, ...)
    |> PostContents.cast(attrs, creator, to) # process text (must be done before Objects.cast)
    |> Objects.cast(attrs, creator, to) # deal with threading, tagging, boundaries, activities, etc.
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
    # |> IO.inspect(label: "list message filters")
    |> list_paginated(current_user, cursor_after, preloads),
    else: list(current_user, nil, cursor_after, preloads)

  end

  def list(%{id: current_user_id} = current_user, _, cursor_after, preloads) do
    # all current_user's message

    [
      messages_involving: {current_user_id, &filter/3},
      # distinct: {:threads, &Bonfire.Social.Threads.filter/3}
    ]
    # |> IO.inspect(label: "my messages filters")
    |> list_paginated(current_user, cursor_after, preloads)
  end

  def list(_current_user, _with_user, _cursor_before, _preloads), do: []

  def list_paginated(filters, current_user \\ nil, cursor_after \\ nil, preloads \\ :all, query \\ Message) do

    query
      # add assocs needed in timelines/feeds
      # |> join_preload([:activity])
      # |> IO.inspect(label: "pre-preloads")
      |> Activities.activity_preloads(current_user, preloads)
      |> query_filter(filters)
      # |> IO.inspect(label: "message_paginated_post-preloads")
      |> Activities.as_permitted_for(current_user)
      # |> distinct([fp], [desc: fp.id, desc: fp.activity_id]) # not sure if/why needed... but possible fix for found duplicate ID for component Bonfire.UI.Social.ActivityLive in UI
      # |> order_by([fp], desc: fp.id)
      # |> IO.inspect(label: "post-permissions")
      # |> repo().many() # return all items
      |> Bonfire.Repo.many_paginated(before: cursor_after) # return a page of items (reverse chronological) + pagination metadata
      # |> IO.inspect(label: "feed")
  end

    #doc "List messages "
  def filter(:messages_involving, {user_id, current_user_id}, query) when is_binary(user_id) and is_binary(current_user_id) do
    verb_id = Verbs.get_id!(:create)

    query
    |> join_preload([:activity, :object, :message])
    |> join_preload([:activity, :object, :tags])
    |> where(
      [activity: activity, message: message, tags: tags],
      not is_nil(message.id)
      and activity.verb_id==^verb_id
      and (
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

  def filter(:messages_involving, _user_id, query) do # replies on boundaries to filter which messages to show
    verb_id = Verbs.get_id!(:create)

    query
    |> join_preload([:activity, :object, :message])
    |> where(
      [message: message],
      not is_nil(message.id) # and activity.verb_id==^verb_id
    )
  end

  def ap_publish_activity("create", message) do
    message = repo().preload(message, [activity: [:tags]])

    {:ok, actor} = ActivityPub.Adapter.get_actor_by_id(Utils.e(message, :created, :creator_id, nil))


    recipients =
      Enum.filter(message.activity.tags, fn tag -> tag.facet == "User" end)
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
