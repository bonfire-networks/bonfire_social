defmodule Bonfire.Social.Feeds do
  use Bonfire.Common.Utils
  use Arrows
  require Logger
  import Ecto.Query
  import Bonfire.Social.Integration

  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.Social.Feed
  alias Bonfire.Social.Follows
  alias Bonfire.Social.Objects
  alias Bonfire.Me.Characters
  alias Bonfire.Me.Boundaries


  # def queries_module, do: Feed
  def context_module, do: Feed

  def target_feeds(%Ecto.Changeset{} = changeset, creator, preset_or_custom_boundary) do

    # maybe include people, tags or other characters that were mentioned/tagged
    mentions = Utils.e(changeset, :changes, :post_content, :changes, :mentions, []) #|> debug("mentions")

    # maybe include the creator of what we're replying to
    reply_to_creator = Utils.e(changeset, :changes, :replied, :changes, :replying_to, :created, :creator, nil) #|> debug("reply_to")

    # include the thread as feed, so it can be followed
    thread_id = Utils.e(changeset, :changes, :replied, :changes, :thread_id, nil) || Utils.e(changeset, :changes, :replied, :changes, :replying_to, :thread_id, nil) |> debug("thread_id")

    do_target_feeds(creator, preset_or_custom_boundary, mentions, reply_to_creator, thread_id)
  end

  def target_feeds(object, creator, preset_or_custom_boundary) when is_struct(object) do

    # FIXME: maybe include people, tags or other characters that were mentioned/tagged
    # mentions = Utils.e(object, :post_content, :mentions, []) #|> debug("mentions")

    # maybe include the creator of what we're replying to
    reply_to_creator = Utils.e(object, :replied, :reply_to, :created, :creator, nil) #|> debug("reply_to")

    # include the thread as feed, so it can be followed
    thread_id = Utils.e(object, :replied, :thread_id, nil) || Utils.e(object, :replied, :reply_to, :thread_id, nil) |> debug("thread_id")

    do_target_feeds(creator, preset_or_custom_boundary, [], reply_to_creator, thread_id)
  end

  def do_target_feeds(creator, preset_or_custom_boundary, mentions \\ [], reply_to_creator \\ nil, thread_id \\ nil) do
    mentioned_inboxes = (mentions |> feed_ids(:inbox, ...)) || []
    reply_to_inbox = reply_to_creator |> feed_id(:inbox, ...)

    # include any extra feeds specified in opts
    extra_feeds = Boundaries.maybe_custom_feeds(preset_or_custom_boundary) || []

    []
    ++ extra_feeds
    ++ case Boundaries.preset(preset_or_custom_boundary) do
      "public" -> # put in all reply_to creators and mentions inboxes + guest/local feeds
        [ named_feed_id(:guest),
          named_feed_id(:local),
          reply_to_inbox,
          thread_id,
          my_feed_id(:outbox, creator)
        ]
        ++ mentioned_inboxes

      "local" ->

        [named_feed_id(:local)] # put in local instance feed
        ++
        ( # put in inboxes (notifications) of any local reply_to creators and mentions
          ([reply_to_creator]
           ++ mentions)
          |> Enum.filter(&check_local/1)
          |> feed_id(:inbox, ...)
        ) ++ [
          thread_id,
          my_feed_id(:outbox, creator)
        ]

      "mentions" ->
        mentioned_inboxes

      "admins" ->
        admins_inboxes()

      _ -> [] # default to none except creator, thread, and any custom ones
    end
    |> Utils.filter_empty([])
    |> Enum.uniq()
    |> debug("target feeds")
  end

  def named_feed_id(name) when is_atom(name), do: Bonfire.Boundaries.Circles.get_id(name)
  def named_feed_id(name) when is_binary(name) do
    case maybe_str_to_atom(name) do
      named when is_atom(named) -> named_feed_id(named)
      _ ->
        Logger.warn("Feed: doesn't seem to be a named feed: #{inspect name}")
        nil
    end
  end

  def my_home_feed_ids(socket, include_notifications? \\ true, extra_feeds \\ [])

  def my_home_feed_ids(socket, include_notifications?, extra_feeds) do
    # IO.inspect(my_home_feed_ids_user: user)

    current_user = current_user(socket)

    # include my outbox
    my_outbox_id = my_feed_id(:outbox, socket) |> debug("my_outbox_id")

    # include my notifications?
    extra_feeds = extra_feeds ++ [my_outbox_id] ++
      if include_notifications?, do: [my_feed_id(:inbox, socket) |> debug("my_inbox_id")], else: []

    # include outboxes of everyone I follow
    with current_user when not is_nil(current_user) <- current_user,
         followings when is_list(followings) <- Follows.all_followed_outboxes(current_user, skip_boundary_check: true) do
      debug(followings, "followings")
      extra_feeds ++ followings
    else
      _e ->
        #IO.inspect(e: e)
        extra_feeds
    end
    |> Utils.filter_empty([])
    |> Enum.uniq()
    |> debug("all")
  end

  def my_home_feed_ids(_, _, extra_feeds), do: extra_feeds

  def my_feed_id(type, %{character: %{id: _} = character}) do
    my_feed_id(type, character)
  end
  def my_feed_id(type, other) do
    case current_user(other) do
      nil ->
        Logger.error("my_feed_id: no function matched for #{inspect other}")
        nil

      current_user ->
        # debug(current_user, "looking up feed for user")
        feed_id(type, current_user)
    end
  end

  def feed_ids(type, for_subjects) when is_list(for_subjects) do
    for_subjects
    |> Enum.map(&feed_id(type, &1))
  end
  def feed_ids(type, for_subject), do: feed_id(type, for_subject)

  def feed_id(type, for_subjects) when is_list(for_subjects), do: feed_ids(type, for_subjects)

  def feed_id(type, %{character: _} = for_subject) do
    for_subject
    |> Bonfire.Repo.maybe_preload(:character)
    #|> IO.inspect(label: "inbox_feed_id")
    |> e(:character, nil)
    |> feed_id(type, ...)
  end

  def feed_id(:outbox, %{outbox_id: feed_id}), do: feed_id
  def feed_id(:outbox, %{outbox: %{id: feed_id}}), do: feed_id

  def feed_id(:inbox, %{inbox_id: feed_id}), do: feed_id
  def feed_id(:inbox, %{inbox: %{id: feed_id}}), do: feed_id

  def feed_id(type, for_subject) do
    with %{id: id} = character <- create_box(type, for_subject) do
      # IO.inspect(for_subject)
      Logger.debug("Feeds: created new #{inspect type} for #{inspect ulid(for_subject)}")
      feed_id(type, character)
    else e ->
      Logger.error("Feeds.feed_id: could not find or create feed (#{inspect e}) for #{inspect ulid(for_subject)}")
      nil
    end
  end

  def inbox_of_obj_creator(object) do
    Objects.preload_creator(object) |> Objects.object_creator() |> feed_id(:inbox, ...) #|> IO.inspect
  end

  def admins_inboxes(), do: Bonfire.Me.Users.list_admins() |> admins_inboxes()
  def admins_inboxes(admins) when is_list(admins), do: Enum.map(admins, fn x -> admin_inbox(x) end)
  def admin_inbox(admin) do
    admin = admin |> Bonfire.Repo.maybe_preload([:character]) # |> IO.inspect
    # Logger.warn("admins_inbox: #{inspect admin}")
    e(admin, :character, :inbox, :feed_id, nil)
      || feed_id(:inbox, admin)
  end

  @doc """
  Create an inbox or outbox for an existing Pointable (eg. User)
  """
  defp create_box(type, id) when is_binary(id), do: create_box(type, Characters.get(id))
  defp create_box(type, %{character: _} = object), do: repo().maybe_preload(object, :character) |> e(:character, nil) |> create_box(type, ...)
  defp create_box(type, %Character{id: _}=character) do
    # TODO: optimise using cast_assoc?
    with {:ok, %{id: feed_id} = _feed} <- create() do
      save_box_feed(type, character, feed_id)
    end
  end
  defp create_box(type, other) do
    Logger.debug("Feeds: no matching function create_box for #{inspect other}")
    nil
  end

  defp save_box_feed(:outbox, character, feed_id) do
    update_character(character, %{outbox_id: feed_id})
  end
  defp save_box_feed(:inbox, character, feed_id) do
    update_character(character, %{inbox_id: feed_id})
  end
  defp update_character(%Character{} = character, attrs) do
    repo().update(Character.changeset(character, attrs, :update))
  end


  @doc """
  Create a new generic feed
  """
  defp create() do
    do_create(%{})
  end

  @doc """
  Create a new feed with a specific ID
  """
  defp create(%{id: id}) do
    do_create(%{id: id})
  end

  defp do_create(attrs) do
    repo().put(changeset(attrs))
  end

  defp changeset(activity \\ %Feed{}, %{} = attrs) do
    Feed.changeset(activity, attrs)
  end

end
