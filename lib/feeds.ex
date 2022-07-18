defmodule Bonfire.Social.Feeds do
  use Bonfire.Common.Utils
  use Arrows
  import Where
  import Ecto.Query
  import Bonfire.Social.Integration
  import Where
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.Social.Feed
  alias Bonfire.Social.Follows
  alias Bonfire.Social.Objects
  alias Bonfire.Me.Characters
  alias Bonfire.Boundaries

  @global_feeds %{
    "public"    => [:guest, :local],
    "federated" => [:guest, :activity_pub],
    "local"     => [:local],
  }

  # def queries_module, do: Feed
  def context_module, do: Feed


  def feed_ids_to_publish(_me, "admins", _) do
    admins_notifications()
    |> debug("posting to admin feeds")
  end
  def feed_ids_to_publish(me, boundary, assigns) do
    my_notifications = feed_id(:notifications, me)

    [
      e(assigns, :reply_to, :replied, :thread, :id, nil),
      maybe_my_outbox_feed_id(me, boundary),
      global_feed_ids(boundary),
      mentions_feed_ids(assigns, boundary)
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&( &1 == my_notifications )) # avoid self-notifying
    |> Utils.filter_empty([])
  end

  def maybe_my_outbox_feed_id(me, boundary) do
    if boundary in ["public", "federated", "local"] do
      case my_feed_id(:outbox, me) do
        nil ->
          warn("Cannot find my outbox to publish!")
          nil
        id ->
          debug(boundary, "Publishing to my outbox, boundary")
          [id]
      end
    else
      debug(boundary, "Not publishing to my outbox, boundary")
      nil
    end
  end


  def global_feed_ids(boundary), do: Map.get(@global_feeds, boundary, []) |> Enum.map(&named_feed_id/1)

  def mentions_feed_ids(assigns, boundary) do
    # TODO: unravel the mentions parsing so we can deal with mentions properly
    mentions = Map.get(assigns, :mentions, [])
    reply_to_creator = e(assigns, :reply_to, :created, :creator, nil)
    user_notifications_feeds([reply_to_creator | mentions], boundary)
    |> debug("mentions notifications feeds")
  end

  def user_notifications_feeds(users, boundary) do
    # debug(epic, act, users, "users going in")
    cond do
      boundary in ["public", "mentions", "federated"] ->
        users
        |> filter_empty([])
        |> repo().maybe_preload([:character])
        |> Enum.map(&feed_id(:notifications, &1))
      boundary == "local" ->
        users
        |> filter_empty([])
        |> repo().maybe_preload([:character, :peered])
        |> Enum.filter(&is_local?/1) # only local
        |> Enum.map(&feed_id(:notifications, &1))
      true ->
        nil
    end
  end

## TODO: de-duplicate feed_ids_to_publish/3 and target_feeds/4 ##

  def target_feeds(%Ecto.Changeset{} = changeset, creator, preset_or_custom_boundary) do
    # debug(changeset)

    # maybe include people, tags or other characters that were mentioned/tagged
    mentions = Utils.e(changeset, :changes, :post_content, :changes, :mentions, []) #|> debug("mentions")

    # maybe include the creator of what we're replying to
    reply_to_creator = Utils.e(changeset, :changes, :replied, :changes, :replying_to, :created, :creator, nil) #|> debug("reply_to")

    # include the thread as feed, so it can be followed
    thread_id = Utils.e(changeset, :changes, :replied, :changes, :thread_id, nil) || Utils.e(changeset, :changes, :replied, :changes, :replying_to, :thread_id, nil) #|> debug("thread_id")

    do_target_feeds(creator, preset_or_custom_boundary, mentions, reply_to_creator, thread_id)
  end

  def target_feeds(%{} = object, creator, preset_or_custom_boundary) do
    object = object
            |> repo().maybe_preload(replied: [reply_to: [created: :creator]])
            |> repo().maybe_preload(:tags)

    # maybe include people, tags or other characters that were mentioned/tagged
    tags = Utils.e(object, :tags, []) #|> debug("mentions")

    # maybe include the creator of what we're replying to
    reply_to_creator = Utils.e(object, :replied, :reply_to, :created, :creator, nil) #|> debug("reply_to")

    # include the thread as feed, so it can be followed
    thread_id = Utils.e(object, :replied, :thread_id, nil) || Utils.e(object, :replied, :reply_to, :thread_id, nil) #|> debug("thread_id")

    do_target_feeds(creator, preset_or_custom_boundary, tags, reply_to_creator, thread_id)
  end

  def target_feeds({_, %{}= object}, creator, preset_or_custom_boundary), do: target_feeds(object, creator, preset_or_custom_boundary)

  def do_target_feeds(creator, preset_or_custom_boundary, mentions \\ [], reply_to_creator \\ nil, thread_id \\ nil) do

    creator_notifications = feed_id(:notifications, creator)
    |> debug("creator_notifications")

    # include any extra feeds specified in opts
    to_feeds_custom = maybe_custom_feeds(preset_or_custom_boundary) || []
    |> debug("to_feeds_custom")

    []
    ++ [to_feeds_custom]
    ++ case Boundaries.preset_name(maybe_from_opts(preset_or_custom_boundary, :boundary, preset_or_custom_boundary)) do

      "public" -> # put in all reply_to creators and mentions inboxes + guest/local feeds
        [ named_feed_id(:guest),
          named_feed_id(:local),
          thread_id,
          my_feed_id(:outbox, creator)
        ]
        ++ # put in inboxes (notifications) of any users we're replying to and mentions
          (([reply_to_creator]
           ++ mentions)
          |> feed_ids(:notifications, ...))

      "federated" -> # like public but put in federated feed instead of local (FIXME: is this right?)
        [ named_feed_id(:guest),
          named_feed_id(:activity_pub),
          thread_id,
          my_feed_id(:outbox, creator)
        ]
        ++ # put in inboxes (notifications) of any users we're replying to and mentions
        (
          (
            [reply_to_creator]
            ++ mentions
          )
          |> feed_ids(:notifications, ...)
        )

      "local" ->

        [named_feed_id(:local)] # put in local instance feed - TODO: is this necessary?
        ++
        [
          thread_id, # thread feed
          my_feed_id(:outbox, creator) # author outbox
        ]
        ++ # put in inboxes (notifications) of any local users we're replying to and local mentions
        (
          (
            [reply_to_creator]
            ++ mentions
          )
          |> Enum.filter(&is_local?/1)
          |> feed_ids(:notifications, ...)
        )

      "mentions" ->
        mentions
        |> feed_ids(:notifications, ...)

      "admins" ->
        admins_notifications()

      _ -> [] # default to none except any custom ones
    end
    |> debug("pre-target feeds")
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&( &1 == creator_notifications )) # avoid self-notifying
    |> Utils.filter_empty([])
    |> debug("target feeds")
  end

  def maybe_custom_feeds(preset_and_custom_boundary), do: maybe_from_opts(preset_and_custom_boundary, :to_feeds, [])

  def named_feed_id(name) when is_atom(name), do: Bonfire.Boundaries.Circles.get_id(name)
  def named_feed_id(name) when is_binary(name) do
    case maybe_to_atom(name) do
      named when is_atom(named) -> named_feed_id(named)
      _ ->
        warn("Feed: doesn't seem to be a named feed: #{inspect name}")
        nil
    end
  end

  def my_home_feed_ids(socket_or_opts, extra_feeds \\ [])
  # TODO: make configurable if user wants notifications included in home feed

  def my_home_feed_ids(socket_or_opts, extra_feeds) do
    # debug(my_home_feed_ids_user: socket_or_opts)

    current_user = current_user(socket_or_opts)

    # include my outbox
    my_outbox_id = if Bonfire.Me.Settings.get([Bonfire.Social.Feeds, :my_feed_includes, :outbox], true, socket_or_opts), do: my_feed_id(:outbox, current_user) #|> debug("my_outbox_id")

    # include my notifications?
    my_notifications_id = if Bonfire.Me.Settings.get([Bonfire.Social.Feeds, :my_feed_includes, :notifications], true, socket_or_opts), do: my_feed_id(:notifications, current_user)

    extra_feeds = extra_feeds ++ [my_outbox_id] ++ [my_notifications_id]

    # include outboxes of everyone I follow
    with _ when not is_nil(current_user) <- current_user,
         followings when is_list(followings) <- Follows.all_followed_outboxes(current_user, skip_boundary_check: true) do
      # debug(followings, "followings")
      extra_feeds ++ followings
    else
      _e ->
        #debug(e: e)
        extra_feeds
    end
    |> Utils.filter_empty([])
    |> Enum.uniq()
    # |> debug("all")
  end

  def my_home_feed_ids(_, extra_feeds), do: extra_feeds

  def my_feed_id(type, other) do
    case current_user(other) do
      nil ->
        error("no user found in #{inspect other}")
        nil

      current_user ->
        # debug(current_user, "looking up feed for user")
        feed_id(type, current_user)
    end
  end

  def feed_ids(feed_name, for_subjects) when is_list(for_subjects) do
    for_subjects
    |> repo().maybe_preload([:character])
    |> Enum.map(&feed_id(feed_name, &1))
    |> List.flatten()
    |> filter_empty([])
  end
  def feed_ids(feed_name, for_subject), do: [feed_id(feed_name, for_subject)]


  # def feed_id(type, for_subjects) when is_list(for_subjects), do: feed_ids(type, for_subjects)

  def feed_id(type, %{character: _} = object), do: object |> repo().maybe_preload(:character) |> e(:character, nil) |> feed_id(type, ...)

  def feed_id(feed_name, for_subject) do
    cond do
      is_binary(for_subject) ->
        Characters.get(for_subject)
        ~> feed_id(feed_name, ...)

      is_atom(feed_name) and is_map(for_subject) ->
        # debug(for_subject, "subject before looking for feed")

        (feed_key(feed_name) #|> debug()
          |> e(for_subject, ..., nil))
        # || maybe_create_feed(feed_name, for_subject) # shouldn't be needed because feeds are cast into Character changeset

      # is_list(feed_name) ->
      #   Enum.map(feed_name, &feed_id!(user, &1))
      #   |> Enum.reject(&is_nil/1)

      is_binary(feed_name) ->
        case maybe_to_atom(feed_name) do
          feed_name when is_atom(feed_name) ->
            feed_id(feed_name, for_subject)

          _ ->
            error(for_subject, "Could not get #{inspect feed_name} feed_id for")
            nil
        end

      true ->
        error(for_subject, "Could not get #{inspect feed_name} feed_id for")
        nil
    end
  end
  def feed_id!(feed_name, for_subject) do
    feed_id(feed_name, for_subject) || raise "Expected feed name and user or character, got #{inspect(feed_name)}"
  end

  @typedoc "Names a predefined feed attached to a user"
  @type feed_name :: :inbox | :outbox | :notifications

  defp feed_key(:inbox),  do: :inbox_id
  defp feed_key(:outbox), do: :outbox_id
  defp feed_key(:notifications), do: :notifications_id
  defp feed_key(:notification), do: :notifications_id # just in case
  defp feed_key(other), do: raise "Unknown user feed name: #{inspect(other)}"

  def maybe_creator_notification(subject, object_creator) do
    if ulid(subject) != ulid(object_creator), do: [notifications: object_creator], else: []
  end

  def inbox_of_obj_creator(object) do
    Objects.preload_creator(object) |> Objects.object_creator() |> feed_id(:notifications, ...) #|> IO.inspect
  end

  # def admins_inboxes(), do: Bonfire.Me.Users.list_admins() |> admins_inboxes()
  # def admins_inboxes(admins) when is_list(admins), do: Enum.map(admins, fn x -> admin_inbox(x) end)
  # def admin_inbox(admin) do
  #   admin = admin |> Bonfire.Common.Repo.maybe_preload([:character]) # |> IO.inspect
  #   #|> debug()
  #   e(admin, :character, :inbox_id, nil)
  #     || feed_id(:inbox, admin)
  # end

  def admins_notifications(), do:
    Bonfire.Me.Users.list_admins()
    |> Bonfire.Common.Repo.maybe_preload([:character])
    |> admins_notifications()
  def admins_notifications(admins) when is_list(admins), do: Enum.map(admins, fn x -> admin_notifications(x) end)
  def admin_notifications(admin) do
    e(admin, :character, :notifications_id, nil)
    || feed_id(:notifications, admin)
  end

  def maybe_create_feed(type, for_subject) do
    with feed_id when is_binary(feed_id) <- create_box(type, for_subject) do
      # debug(for_subject)
      debug("created new #{inspect type} with id #{inspect feed_id} for #{inspect ulid(for_subject)}")
      feed_id
    else e ->
      error("could not find or create feed (#{inspect e}) for #{inspect ulid(for_subject)}")
      nil
    end
  end

  @doc """
  Create an inbox or outbox for an existing Pointable (eg. User)
  """
  defp create_box(type, %Character{id: _}=character) do
    # TODO: optimise using cast_assoc?
    with {:ok, %{id: feed_id} = _feed} <- create(),
         {:ok, character} <- save_box_feed(type, character, feed_id) do
      feed_id
    else e ->
      debug("Social.Feeds: could not create_box for #{inspect character}")
      nil
    end
  end
  defp create_box(_type, other) do
    debug("Social.Feeds: no clause match for function create_box with #{inspect other}")
    nil
  end

  defp save_box_feed(:outbox, character, feed_id) do
    update_character(character, %{outbox_id: feed_id})
  end
  defp save_box_feed(:inbox, character, feed_id) do
    update_character(character, %{inbox_id: feed_id})
  end
  defp save_box_feed(:notifications, character, feed_id) do
    update_character(character, %{notifications_id: feed_id})
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
