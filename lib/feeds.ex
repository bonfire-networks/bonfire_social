defmodule Bonfire.Social.Feeds do
  use Bonfire.Common.Utils
  use Arrows
  use Untangle
  # import Ecto.Query
  import Bonfire.Social.Integration
  import Untangle
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.Social.Feed
  alias Bonfire.Social.Follows
  alias Bonfire.Social.Objects
  alias Bonfire.Me.Characters
  alias Bonfire.Boundaries

  @global_feeds %{
    "public" => [:guest, :local],
    "public_remote" => [:guest, :activity_pub],
    "local" => [:local]
  }

  @behaviour Bonfire.Common.ContextModule
  @behaviour Bonfire.Common.QueryModule
  def schema_module, do: Feed

  ## TODO: de-duplicate feed_ids_to_publish/3 and target_feeds/4 ##
  def feed_ids_to_publish(_me, "admins", _) do
    admins_notifications()
    |> debug("posting to admin feeds")
  end

  def feed_ids_to_publish(me, boundary, assigns, reply_and_or_mentions_notifications_feeds \\ nil) do
    [
      e(assigns, :reply_to, :replied, :thread, :id, nil),
      maybe_my_outbox_feed_id(me, boundary),
      global_feed_ids(boundary),
      reply_and_or_mentions_notifications_feeds ||
        reply_and_or_mentions_notifications_feeds(
          me,
          boundary,
          e(assigns, :mentions, []),
          e(assigns, :reply_to, :created, :creator, nil)
        )
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> Enums.filter_empty([])
    |> debug()
  end

  def maybe_my_outbox_feed_id(me, boundary) do
    if boundary not in ["mentions", "admins"] do
      case my_feed_id(:outbox, me) do
        nil ->
          warn("Cannot find my outbox to publish!")
          nil

        id ->
          debug(boundary, "Publishing to my outbox, boundary")
          id
      end
    else
      debug(boundary, "Not publishing to my outbox, boundary")
      nil
    end
  end

  defp global_feed_ids(boundary),
    do: Map.get(@global_feeds, boundary, []) |> Enum.map(&named_feed_id/1)

  def reply_and_or_mentions_notifications_feeds(
        me,
        boundary,
        mentions,
        reply_to_creator,
        to_circles \\ []
      ) do
    my_notifications = feed_id(:notifications, me)

    (user_notifications_feeds([reply_to_creator], boundary) ++
       user_notifications_feeds(
         mentions,
         boundary,
         to_circles
       ))
    |> Enums.filter_empty([])
    |> Enum.uniq()
    # avoid self-notifying
    |> Enum.reject(&(&1 == my_notifications))
    |> debug()
  end

  defp user_notifications_feeds(users, boundary, to_circles \\ []) do
    # debug(epic, act, users, "users going in")
    cond do
      boundary in ["public", "mentions"] ->
        users
        |> debug()
        |> filter_empty([])
        |> repo().maybe_preload([:character])
        |> Enum.map(&feed_id(:notifications, &1))

      boundary == "local" ->
        users
        |> debug()
        |> filter_empty([])
        |> repo().maybe_preload([:character, :peered])
        # only local
        |> Enum.filter(&is_local?/1)
        |> Enum.map(&feed_id(:notifications, &1))

      true ->
        # we should only notify mentions & reply_to_creator IF they are included in the object's boundaries

        to_circles_ids = Enums.ids(to_circles)

        users
        |> filter_empty([])
        |> Enum.filter(&(id(&1) in to_circles_ids))
        |> repo().maybe_preload([:character])
        |> debug()
        # only local
        |> Enum.map(&feed_id(:notifications, &1))
    end
  end

  ## TODO: de-duplicate feed_ids_to_publish/3 and target_feeds/4 ##
  def target_feeds(%Ecto.Changeset{} = changeset, creator, opts) do
    # debug(changeset)

    # maybe include people, tags or other characters that were mentioned/tagged
    # |> debug("mentions")
    mentions = Utils.e(changeset, :changes, :post_content, :changes, :mentions, [])

    # maybe include the creator of what we're replying to
    # |> debug("reply_to")
    reply_to_creator =
      Utils.e(changeset, :changes, :replied, :changes, :replying_to, :created, :creator, nil)

    # include the thread as feed, so it can be followed
    # |> debug("thread_id")
    thread_id =
      Utils.e(changeset, :changes, :replied, :changes, :thread_id, nil) ||
        Utils.e(changeset, :changes, :replied, :changes, :replying_to, :thread_id, nil)

    do_target_feeds(creator, opts, mentions, reply_to_creator, thread_id)
  end

  def target_feeds(%{} = object, creator, opts) do
    object =
      object
      |> repo().maybe_preload(replied: [reply_to: [created: :creator]])
      |> repo().maybe_preload(:tags)

    # maybe include people, tags or other characters that were mentioned/tagged
    # |> debug("mentions")
    tags = Utils.e(object, :tags, [])

    # maybe include the creator of what we're replying to
    # |> debug("reply_to")
    reply_to_creator = Utils.e(object, :replied, :reply_to, :created, :creator, nil)

    # include the thread as feed, so it can be followed
    # |> debug("thread_id")
    thread_id =
      Utils.e(object, :replied, :thread_id, nil) ||
        Utils.e(object, :replied, :reply_to, :thread_id, nil)

    do_target_feeds(creator, opts, tags, reply_to_creator, thread_id)
  end

  def target_feeds({_, %{} = object}, creator, opts),
    do: target_feeds(object, creator, opts)

  def do_target_feeds(
        creator,
        opts,
        mentions \\ [],
        reply_to_creator \\ nil,
        thread_id \\ nil
      ) do
    creator_notifications =
      feed_id(:notifications, creator)
      |> debug("creator_notifications")

    # include any extra feeds specified in opts
    to_feeds_custom =
      maybe_custom_feeds(opts) ||
        []
        |> debug("to_feeds_custom")

    ([] ++
       [to_feeds_custom] ++
       case Boundaries.preset_name(
              maybe_from_opts(opts, :boundary, opts),
              true
            ) do
         # put in all reply_to creators and mentions inboxes + guest/local feeds
         "public" ->
           # put in inboxes (notifications) of any users we're replying to and mentions
           ([
              named_feed_id(:guest),
              named_feed_id(:local),
              thread_id,
              my_feed_id(:outbox, creator)
            ] ++
              (([reply_to_creator] ++
                  mentions)
               |> feed_ids(:notifications, ...)))
           |> debug("notify reply_to creator and/or mentions")

         # like public but put in remote/federated feed instead of guest and local
         "public_remote" ->
           # put in inboxes (notifications) of any users we're replying to and mentions
           [
             named_feed_id(:guest),
             named_feed_id(:activity_pub),
             thread_id,
             my_feed_id(:outbox, creator)
           ] ++
             (([reply_to_creator] ++
                 mentions)
              |> feed_ids(:notifications, ...))

         "local" ->
           # put in local instance feed
           # put in inboxes (notifications) of any local users we're replying to and local mentions
           [
             named_feed_id(:local),
             # thread feed
             thread_id,
             # author outbox
             my_feed_id(:outbox, creator)
           ] ++
             (([reply_to_creator] ++
                 mentions)
              |> Enum.filter(&is_local?/1)
              |> feed_ids(:notifications, ...))

         "mentions" ->
           mentions
           |> feed_ids(:notifications, ...)

         "admins" ->
           admins_notifications()

         # defaults for custom boundaries with none of the presets selected
         _ ->
           # TODO: we should notify mentions & reply_to_creator IF they are included in the object's boundaries
           # thread feed
           [
             thread_id,
             # author outbox
             my_feed_id(:outbox, creator)
           ]
       end)
    |> debug("pre-target feeds")
    |> List.flatten()
    |> Enum.uniq()
    # avoid self-notifying
    |> Enum.reject(&(&1 == creator_notifications))
    |> Enums.filter_empty([])
    |> debug("target feeds")
  end

  def maybe_custom_feeds(preset_and_custom_boundary),
    do: maybe_from_opts(preset_and_custom_boundary, :to_feeds, [])

  def named_feed_id(name, opts \\ [])
  def named_feed_id(:explore, _), do: nil
  def named_feed_id(:fediverse, _), do: named_feed_id(:activity_pub)
  def named_feed_id(:notifications, opts), do: my_feed_id(:notifications, current_user(opts))

  def named_feed_id(name, _) when is_atom(name) and not is_nil(name),
    do: Bonfire.Boundaries.Circles.get_id(name) || name

  def named_feed_id(name, _) when is_binary(name) do
    case maybe_to_atom(name) do
      named when is_atom(named) ->
        named_feed_id(named)

      _ ->
        warn("Feed: doesn't seem to be a named feed: #{inspect(name)}")
        nil
    end
  end

  @decorate time()
  def my_home_feed_ids(socket_or_opts, extra_feeds \\ [])
  # TODO: make configurable if user wants notifications included in home feed

  def my_home_feed_ids(socket_or_opts, extra_feeds) do
    # debug(my_home_feed_ids_user: socket_or_opts)

    current_user = current_user(socket_or_opts)

    # include my outbox
    # |> debug("my_outbox_id")
    my_outbox_id =
      if Bonfire.Common.Settings.get(
           [Bonfire.Social.Feeds, :include, :outbox],
           true,
           socket_or_opts
         ),
         do: my_feed_id(:outbox, current_user)

    # include my notifications?
    my_notifications_id =
      if Bonfire.Common.Settings.get(
           [Bonfire.Social.Feeds, :include, :notifications],
           true,
           socket_or_opts
         ),
         do: my_feed_id(:notifications, current_user)

    extra_feeds = extra_feeds ++ [my_outbox_id] ++ [my_notifications_id]

    # include outboxes of everyone I follow
    with _ when not is_nil(current_user) <- current_user,
         followings when is_list(followings) <-
           Follows.all_followed_outboxes(current_user,
             include_followed_categories:
               Bonfire.Common.Settings.get(
                 [Bonfire.Social.Feeds, :include, :followed_categories],
                 true,
                 socket_or_opts
               ),
             skip_boundary_check: true
           ) do
      # debug(followings, "followings")
      extra_feeds ++ followings
    else
      _e ->
        # debug(e: e)
        extra_feeds
    end
    |> Enums.filter_empty([])
    |> Enum.uniq()

    # |> debug("all")
  end

  def my_home_feed_ids(_, extra_feeds), do: extra_feeds

  def my_feed_id(type, other) do
    case current_user(other) do
      nil ->
        error("no user found in #{inspect(other)}")
        nil

      current_user ->
        debug(current_user, "looking up feed for user")
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

  def feed_id(type, %{character: _} = object),
    do: object |> repo().maybe_preload(:character) |> e(:character, nil) |> feed_id(type, ...)

  def feed_id(feed_name, for_subject) do
    cond do
      is_binary(for_subject) ->
        with {:ok, character} <- Characters.get(for_subject) do
          feed_id(feed_name, character)
        else
          e ->
            error(e, "character not found, so no feed")
            nil
        end

      is_atom(feed_name) and is_map(for_subject) ->
        # debug(for_subject, "subject before looking for feed")

        # |> debug()
        feed_key(feed_name)
        |> e(for_subject, ..., nil)

      # || maybe_create_feed(feed_name, for_subject) # shouldn't be needed because feeds are cast into Character changeset

      # is_list(feed_name) ->
      #   Enum.map(feed_name, &feed_id!(user, &1))
      #   |> Enum.reject(&is_nil/1)

      is_binary(feed_name) ->
        case maybe_to_atom(feed_name) do
          feed_name when is_atom(feed_name) ->
            feed_id(feed_name, for_subject)

          _ ->
            error(for_subject, "Could not get #{inspect(feed_name)} feed_id for")
            nil
        end

      true ->
        error(for_subject, "Could not get #{inspect(feed_name)} feed_id for")
        nil
    end
  end

  def feed_id!(feed_name, for_subject) do
    feed_id(feed_name, for_subject) ||
      raise "Expected feed name and user or character, got #{inspect(feed_name)}"
  end

  @typedoc "Names a predefined feed attached to a user"
  @type feed_name :: :inbox | :outbox | :notifications

  defp feed_key(:my), do: :inbox_id
  defp feed_key(:inbox), do: :inbox_id
  defp feed_key(:outbox), do: :outbox_id
  defp feed_key(:notifications), do: :notifications_id
  # just in case
  defp feed_key(:notification), do: :notifications_id
  defp feed_key(other), do: raise("Unknown feed name: #{inspect(other)}")

  def maybe_creator_notification(subject, object_creator, opts \\ []) do
    if id(subject) != id(object_creator) and
         (opts[:local] != false or Bonfire.Social.Integration.federating?(object_creator)) do
      [notifications: object_creator]
    else
      []
    end
  end

  def inbox_of_obj_creator(object) do
    # |> IO.inspect
    Objects.preload_creator(object) |> Objects.object_creator() |> feed_id(:notifications, ...)
  end

  # def admins_inboxes(), do: Bonfire.Me.Users.list_admins() |> admins_inboxes()
  # def admins_inboxes(admins) when is_list(admins), do: Enum.map(admins, fn x -> admin_inbox(x) end)
  # def admin_inbox(admin) do
  #   admin = admin |> repo().maybe_preload([:character]) # |> IO.inspect
  #   #|> debug()
  #   e(admin, :character, :inbox_id, nil)
  #     || feed_id(:inbox, admin)
  # end

  def admins_notifications(),
    do:
      Bonfire.Me.Users.list_admins()
      |> repo().maybe_preload([:character])
      |> admins_notifications()

  def admins_notifications(admins) when is_list(admins),
    do: Enum.map(admins, fn x -> admin_notifications(x) end)

  def admin_notifications(admin) do
    e(admin, :character, :notifications_id, nil) ||
      feed_id(:notifications, admin)
  end

  def maybe_create_feed(type, for_subject) do
    with feed_id when is_binary(feed_id) <- create_box(type, for_subject) do
      # debug(for_subject)
      debug(
        "created new #{inspect(type)} with id #{inspect(feed_id)} for #{inspect(ulid(for_subject))}"
      )

      feed_id
    else
      e ->
        error("could not find or create feed (#{inspect(e)}) for #{inspect(ulid(for_subject))}")
        nil
    end
  end

  # @doc "Create an inbox or outbox for an existing Pointable (eg. User)"
  defp create_box(type, %Character{id: _} = character) do
    # TODO: optimise using cast_assoc?
    with {:ok, %{id: feed_id} = _feed} <- create(),
         {:ok, _character} <- save_box_feed(type, character, feed_id) do
      feed_id
    else
      e ->
        debug(e, "could not create_box")
        nil
    end
  end

  defp create_box(_type, other) do
    debug(other, "no clause match for function create_box")
    nil
  end

  defp save_box_feed(:outbox, character, feed_id) do
    Characters.update(character, %{outbox_id: feed_id})
  end

  defp save_box_feed(:inbox, character, feed_id) do
    Characters.update(character, %{inbox_id: feed_id})
  end

  defp save_box_feed(:notifications, character, feed_id) do
    Characters.update(character, %{notifications_id: feed_id})
  end

  # @doc "Create a new generic feed"
  defp create() do
    do_create(%{})
  end

  # @doc "Create a new feed with a specific ID"
  # defp create(%{id: id}) do
  #   do_create(%{id: id})
  # end

  defp do_create(attrs) do
    repo().put(changeset(attrs))
  end

  defp changeset(activity \\ %Feed{}, %{} = attrs) do
    Feed.changeset(activity, attrs)
  end
end
