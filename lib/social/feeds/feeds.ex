defmodule Bonfire.Social.Feeds do
  use Bonfire.Common.Utils
  use Arrows
  require Logger
  import Ecto.Query
  import Bonfire.Me.Integration

  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.Social.Feed
  alias Bonfire.Social.Follows
  alias Bonfire.Social.Objects


  # def queries_module, do: Feed
  def context_module, do: Feed

  def target_feeds(changeset, creator, preset) do

    mentioned_inboxes = Utils.e(changeset, :changes, :post_content, :changes, :mentions, []) |> feed_ids(:inbox, ...)

    reply_to_inbox = Utils.e(changeset, :changes, :replied, :replying_to, []) |> feed_id(:inbox, ...)

    [my_feed_id(:outbox, creator)]
    ++ case preset do
      "public" -> # put in all reply_to creators and mentions inboxes + guest/local feeds
        mentioned_inboxes ++ [reply_to_inbox, named_feed_id(:guest), named_feed_id(:local)]

      "local" -> # TODO: put in reply_to creators and mentions inboxes, if they are local + local feed
        [named_feed_id(:local)]

      "activity_pub" -> # TODO: put in all reply_to creators and mentions inboxes (for now) + AP feed
        [named_feed_id(:activity_pub)]

      "mentions" ->
        mentioned_inboxes

      "admins" ->
        admins_inboxes()

      _ -> [] # default to nothing
    end
    |> Enum.filter(& &1)
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
    my_outbox_id = my_feed_id(:outbox, socket)

    # include my notifications?
    extra_feeds = extra_feeds ++ [my_outbox_id] ++
      if include_notifications?, do: [my_feed_id(:inbox, socket)], else: []

    # include outboxes of everyone I follow
    with current_user when not is_nil(current_user) <- current_user,
         followings when is_list(followings) <- Follows.list_follows_by_subject(current_user, skip_boundary_check: true) do
      debug(followings, "followings")
      extra_feeds ++ followings
    else
      _e ->
        #IO.inspect(e: e)
        extra_feeds
    end
  end

  def my_home_feed_ids(_, _, extra_feeds), do: extra_feeds

  def my_feed_id(type, %{character: character}) do
    my_feed_id(type, character)
  end
  def my_feed_id(type, %{id: id} = user_etc) when is_binary(id) do
    if is_ulid?(id), do: feed_id(type, user_etc)
  end
  def my_feed_id(type, other) do
    case current_user(other) do
      nil ->
        Logger.error("my_feed_id: no function matched for #{inspect other}")
        nil

      current_user ->
        feed_id(type, current_user)
    end
  end

  def feed_ids(type, for_subjects) when is_list(for_subjects) do
    for_subjects
    |> Enum.map(&feed_id(type, &1))
  end
  def feed_ids(type, for_subject), do: feed_id(type, for_subject)

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
      Logger.debug("Feeds: created new inbox for #{inspect ulid(for_subject)}")
      feed_id(type, character)
    else e ->
      Logger.error("Feeds.feed_id: could not create feed: #{inspect e}")
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
  def create_box(type, %{id: id}=_thing), do: create_box(type, id)
  def create_box(type, id) when is_binary(id) do
    # TODO: optimise using cast_assoc
    with {:ok, %{id: feed_id} = _feed} <- create() do
      save_box_feed(type, id, feed_id)
    end
  end
  def create_box(type, other) do
    Logger.error("Feeds: Could not create_box for #{inspect other}")
    nil
  end

  defp save_box_feed(:outbox, id, feed_id) do
    update_character(%{id: id, outbox_id: feed_id})
  end
  defp save_box_feed(:inbox, id, feed_id) do
    update_character(%{id: id, inbox_id: feed_id})
  end
  defp update_character(attrs) do
    repo().update(Character.changeset(attrs))
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



  @doc """
  Get or create feed for something
  """
  def feed_for(subject) do
    case maybe_feed_for(subject) do
      %Feed{} = feed -> feed
      _ ->
        with {:ok, feed} <- create(%{id: ulid(subject)}) do
          feed
        end
    end
  end


  @doc """
  Get a feed for something if any exists
  """
  def maybe_feed_for(%Feed{id: _} = feed), do: feed
  def maybe_feed_for(%{id: subject_id}), do: maybe_feed_for(subject_id)
  def maybe_feed_for(subject_id) when is_binary(subject_id) do
    with {:ok, feed} <- repo().single(feed_for_id_query(subject_id)) do
      feed
    else _ -> nil
    end
  end
  def maybe_feed_for(_), do: nil


  def feed_for_id_query(subject_id) do
    from f in Feed,
     where: f.id == ^subject_id
  end


end
