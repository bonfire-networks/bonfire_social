defmodule Bonfire.Social.Feeds do

  require Logger
  alias Bonfire.Data.Social.{Feed, Inbox}
  alias Bonfire.Social.Follows
  alias Bonfire.Social.Objects
  import Ecto.Query
  import Bonfire.Me.Integration
  import Bonfire.Common.Utils

  # def queries_module, do: Feed
  def context_module, do: Feed

  def instance_feed_id, do: Bonfire.Boundaries.Circles.circles[:local]
  def fediverse_feed_id, do: Bonfire.Boundaries.Circles.circles[:activity_pub]

  def my_feed_ids(socket, include_notifications? \\ true, extra_feeds \\ [])

  def my_feed_ids(socket, include_notifications?, extra_feeds) do
    # IO.inspect(my_feed_ids_user: user)

    current_user = current_user(socket)
    my_outbox_id = ulid(current_user) || ulid(current_account(socket))

    extra_feeds = if include_notifications?, do: extra_feeds ++ [my_outbox_id, my_inbox_feed_id(socket)],
    else: extra_feeds ++ [my_outbox_id]

    with current_user when not is_nil(current_user) <- current_user,
         following_ids when is_list(following_ids) <- Follows.by_follower(current_user) do
      #IO.inspect(subs: following_ids)
      extra_feeds ++ following_ids
    else
      _e ->
        #IO.inspect(e: e)
        extra_feeds
    end
  end

  def my_feed_ids(_, _, extra_feeds), do: extra_feeds

  def my_inbox_feed_id(%{current_user: user, current_account: account} = _assigns) when not is_nil(user) and not is_nil(account) do
    [my_inbox_feed_id(user), my_inbox_feed_id(account)]
  end
  def my_inbox_feed_id(%{character: %{inbox: %{feed_id: feed_id}}}) when is_binary(feed_id) do
    feed_id
  end
  def my_inbox_feed_id(%{inbox: %{feed_id: feed_id}}) when is_binary(feed_id) do
    feed_id
  end
  def my_inbox_feed_id(%{current_user: user} = _assigns) when not is_nil(user) do
    my_inbox_feed_id(user)
  end
  def my_inbox_feed_id(%{current_account: account} = _assigns) when not is_nil(account) do
    my_inbox_feed_id(account)
  end
  def my_inbox_feed_id(%{__context__: context}) do
    my_inbox_feed_id(context)
  end
  def my_inbox_feed_id(%{assigns: assigns}) do
    my_inbox_feed_id(assigns)
  end
  def my_inbox_feed_id(%{id: id} = user) when is_binary(id) do
    if is_ulid?(id), do: inbox_feed_ids(user)
  end
  def my_inbox_feed_id(other) do
    Logger.error("my_inbox_feed_id: no function matched for #{inspect other}")
    nil
  end

  def inbox_feed_ids(for_subjects) when is_list(for_subjects) do
    for_subjects
    |> Enum.map(&inbox_feed_ids/1)
  end
  def inbox_feed_ids(%{character: _} = for_subject) do
    for_subject
    |> Bonfire.Repo.maybe_preload(character: [:inbox])
    |> e(:character, nil)
    |> inbox_feed_ids()
  end
  def inbox_feed_ids(%{inbox: %{feed_id: feed_id}}), do: feed_id
  def inbox_feed_ids(for_subject) do
    with %{feed_id: feed_id} = _inbox <- create_inbox(for_subject) do
      Logger.info("created new inbox #{inspect feed_id} for #{inspect ulid(for_subject)}")
      feed_id
    else e ->
      IO.inspect(inbox_feed_ids: e)
      nil
    end
  end

  def inbox_of_obj_creator(object) do
    Objects.preload_creator(object) |> Objects.object_creator() |> inbox_feed_ids() #|> IO.inspect
  end

  def tags_inbox_feeds(tags) when is_list(tags), do: Enum.map(tags, fn x -> tags_inbox_feeds(x) end)
  def tags_inbox_feeds(%{} = tag) do
    # Logger.warn("tags_inbox_feeds: #{inspect tag}")
    inbox_feed_ids(tag)
  end
  def tags_inbox_feeds(_) do
    nil
  end

  def admins_inbox(), do: Bonfire.Me.Users.list_admins() |> admins_inbox()
  def admins_inbox(admins) when is_list(admins), do: Enum.map(admins, fn x -> admins_inbox(x) end)
  def admins_inbox(admin) do
    admin = admin |> Bonfire.Repo.maybe_preload([character: [:inbox]]) # |> IO.inspect
    # Logger.warn("admins_inbox: #{inspect admin}")
    e(admin, :character, :inbox, :feed_id, nil)
      || inbox_feed_ids(admin)
  end


  @doc """
  Create a OUTBOX feed for an existing Pointable (eg. User)
  """
  def create(%{id: id}=_thing) do
    do_create(%{id: id})
  end

  @doc """
  Create a INBOX feed for an existing Pointable (eg. User)
  """
  def create_inbox(%{id: id}=_thing), do: create_inbox(id)
  def create_inbox(id) when is_binary(id) do
    with {:ok, %{id: feed_id} = _feed} <- create() do
      #IO.inspect(feed: feed)
      save_inbox_feed(%{id: id, feed_id: feed_id})
    end
  end

  @doc """
  Create a new generic feed
  """
  def create() do
    do_create(%{})
  end

  defp do_create(attrs) do
    repo().put(changeset(attrs))
  end

  def changeset(activity \\ %Feed{}, %{} = attrs) do
    Feed.changeset(activity, attrs)
  end

  defp save_inbox_feed(attrs) do
    repo().upsert(Inbox.changeset(attrs))
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
