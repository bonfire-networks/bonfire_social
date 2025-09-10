defmodule Bonfire.Social.Feeds do
  @moduledoc """
  Helpers to create or query (though that's usually done through `Bonfire.Social.FeedActivities`) feeds.

  This is the [context](https://hexdocs.pm/phoenix/contexts.html) for `Bonfire.Data.Social.Feed`, a virtual schema with just one field:
  - id
  """

  use Bonfire.Common.Utils
  use Arrows
  use Untangle
  # import Ecto.Query
  import Bonfire.Social
  import Untangle
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.Social.Feed
  alias Bonfire.Social.Graph.Follows
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

  def feed_presets(opts) do
    if current_user = current_user(opts) do
      Settings.get([__MODULE__, :feed_presets], [],
        current_user: current_user,
        name: l("Feed Presets"),
        description: l("Predefined feed configurations.")
      )
    else
      Config.get([__MODULE__, :feed_presets], [],
        name: l("Feed Presets"),
        description: l("Predefined feed configurations available to users.")
      )
    end
  end

  def feed_presets_permitted(opts) do
    Bonfire.Social.Feeds.feed_presets(opts)
    |> Enum.filter(fn {_slug, preset} ->
      case check_feed_preset_permitted(preset, opts) |> debug(inspect(preset)) do
        true -> true
        _error -> false
      end
    end)
  end

  def feed_preset_if_permitted(%{feed_name: name}, opts) when is_atom(name) or is_binary(name) do
    feed_preset_if_permitted(name, opts)
  end

  def feed_preset_if_permitted(%{feed_name: {name, _}}, opts)
      when is_atom(name) or is_binary(name) do
    feed_preset_if_permitted(name, opts)
  end

  def feed_preset_if_permitted(name, opts)
      when not is_nil(name) and not is_boolean(name) and not is_struct(name) do
    presets = feed_presets(opts)

    case e(presets, Types.maybe_to_atom(name), nil) do
      nil ->
        flood(presets, "Feed `#{inspect(name)}` not found")
        {:error, :not_found}

      preset ->
        case check_feed_preset_permitted(preset, opts) do
          true -> {:ok, preset}
          other -> other
        end
    end
  end

  def feed_preset_if_permitted(other, _opts) do
    flood(other, "Feed preset name is not valid")
    {:error, :not_found}
  end

  defp check_feed_preset_permitted(nil, _opts), do: {:error, :not_found}

  defp check_feed_preset_permitted(preset, opts) do
    case preset do
      # NOTE: the order of these matters

      %{instance_permission_required: verbs} = feed_def ->
        Bonfire.Boundaries.can?(current_user(opts), verbs, :instance) || {:error, :not_permitted}

      %{current_user_required: true} = feed_def ->
        if !current_user(opts), do: {:error, :unauthorized}, else: true

      _ ->
        true
    end
  end

  @doc """
  Determines the feed IDs to publish based on the provided parameters.

  TODO: de-duplicate `feed_ids_to_publish/4` and `target_feeds/3`

  ## Examples

  ### When called with the `"admins"` boundary:

      iex> Bonfire.Social.Feeds.feed_ids_to_publish(nil, "admins", nil)
      [] # List of admin feed IDS

  ### When called with a different boundary and some optional feeds:

      > Bonfire.Social.Feeds.feed_ids_to_publish(me, "public", %{reply_to: true}, [some_feed_id])
      [] # List of feed IDs for the provided boundary
  """
  def feed_ids_to_publish(me, boundary, assigns, notify_feeds \\ nil)

  def feed_ids_to_publish(_me, "admins", _, _) do
    admins_notifications()
    |> debug("posting to admin feeds")
  end

  def feed_ids_to_publish(me, boundary, assigns, notify_feeds) do
    [
      e(assigns, :reply_to, :replied, :thread, :id, nil),
      maybe_my_outbox_feed_id(me, boundary),
      global_feed_ids(boundary),
      notify_feeds ||
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

  @doc """
  Returns the feed ID of the outbox depending on the boundary. 

  ## Examples

  ### When the boundary is `"public"`:

      > Bonfire.Social.Feeds.maybe_my_outbox_feed_id(me, "public")
      # Feed ID of the outbox

  ### When the boundary is `"mentions"` or `"admins"`:

      > Bonfire.Social.Feeds.maybe_my_outbox_feed_id(me, "mentions")
      nil
  """
  def maybe_my_outbox_feed_id(me, boundary) do
    if boundary != "admins" do
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

  @doc """
  Generates a list of notification feed IDs based on mentions and replies.

  ## Examples

  ### When there are mentions and a reply to creator:

      > Bonfire.Social.Feeds.reply_and_or_mentions_notifications_feeds(me, "public", ["mention1"], "creator_id")
      # List of notification feed IDs

  ### When no mentions and no reply to creator:

      > Bonfire.Social.Feeds.reply_and_or_mentions_notifications_feeds(me, "local", [], nil)
      # List of notification feed IDs for local boundary
  """
  def reply_and_or_mentions_notifications_feeds(
        me,
        boundary,
        mentions,
        reply_to_creator,
        to_circles \\ []
      ) do
    # my_notifications = feed_id(:notifications, me)

    filter_reply_and_or_mentions(me, reply_to_creator, mentions)
    |> users_to_notify(
      boundary,
      to_circles
    )
    |> notify_feeds()

    # avoid self-notifying
    # |> Enum.reject(&(&1 == my_notifications))
    # |> debug()
  end

  def reply_and_or_mentions_to_notify(
        me,
        boundary,
        mentions,
        reply_to_creator,
        to_circles \\ []
      ) do
    users =
      filter_reply_and_or_mentions(me, reply_to_creator, mentions)
      |> debug()
      |> users_to_notify(
        boundary,
        to_circles
      )

    %{
      notify_feeds: notify_feeds(users),
      notify_emails: notify_emails(users)
    }
    |> debug()
  end

  defp filter_reply_and_or_mentions(me, reply_to_creator, mentions) do
    my_id = Enums.id(me)

    ([reply_to_creator] ++ mentions)
    # avoid self-notifying
    |> Enum.reject(&(Enums.id(&1) == my_id))
  end

  defp users_to_notify(users, boundary, to_circles \\ []) do
    # debug(epic, act, users, "users going in")
    cond do
      boundary in ["public", "mentions"] ->
        users
        |> filter_empty([])
        |> repo().maybe_preload([:character, :settings])

      boundary == "local" ->
        users
        |> filter_empty([])
        |> repo().maybe_preload([:character, :peered, :settings])
        # notify only local users
        |> Enum.filter(&is_local?/1)

      true ->
        # we should only notify mentions & reply_to_creator IF they are included in the object's boundaries
        # TODO: check also if they can read the object otherwise (for example, by being member of an included circle)

        to_circles_ids = Enums.ids(to_circles)

        users
        |> filter_empty([])
        |> Enum.filter(&(id(&1) in to_circles_ids))
        |> repo().maybe_preload([:character, :settings])
    end
    |> debug()
  end

  defp notify_feeds(users) do
    users
    |> Enum.map(&feed_id(:notifications, &1))
    |> Enums.filter_empty([])
    |> Enum.uniq()
  end

  defp notify_emails(users) do
    users
    |> Enum.filter(
      &(Settings.get([:email_notifications, :reply_or_mentions], false,
          context: &1,
          name: l("Email on Mentions/Replies"),
          description: l("Get email notifications for replies or mentions.")
        )
        |> debug("notify_enabled?"))
    )
    |> repo().maybe_preload(accounted: [account: [:email]])
    |> Enum.map(&e(&1, :accounted, :account, :email, :email_address, nil))
    |> Enums.filter_empty([])
    |> Enum.uniq()
  end

  @doc """
  Determines the target feeds for a given changeset, creator, and options.

  TODO: de-duplicate `feed_ids_to_publish/4` and `target_feeds/3`

  ## Examples

  ### When given a changeset:

      > Bonfire.Social.Feeds.target_feeds(changeset, creator, opts)
      # List of target feed IDs based on the changeset

  ### When given an object:

      > Bonfire.Social.Feeds.target_feeds(object, creator, opts)
      # List of target feed IDs based on the object
  """
  def target_feeds(%Ecto.Changeset{} = changeset, creator, opts) do
    # debug(changeset)

    # maybe include people, tags or other characters that were mentioned/tagged
    # |> debug("mentions")
    mentions = e(changeset, :changes, :post_content, :changes, :mentions, [])

    # maybe include the creator of what we're replying to
    # |> debug("reply_to")
    reply_to_creator =
      e(changeset, :changes, :replied, :changes, :replying_to, :created, :creator, nil)

    # include the thread as feed, so it can be followed
    # |> debug("thread_id")
    thread_id =
      e(changeset, :changes, :replied, :changes, :thread_id, nil) ||
        e(changeset, :changes, :replied, :changes, :replying_to, :thread_id, nil)

    do_target_feeds(creator, opts, mentions, reply_to_creator, thread_id)
  end

  def target_feeds(%{} = object, creator, opts) do
    object =
      object
      |> repo().maybe_preload(replied: [reply_to: [created: :creator]])
      |> repo().maybe_preload(:tags)

    # maybe include people, tags or other characters that were mentioned/tagged
    # |> debug("mentions")
    tags = e(object, :tags, [])

    # maybe include the creator of what we're replying to
    # |> debug("reply_to")
    reply_to_creator = e(object, :replied, :reply_to, :created, :creator, nil)

    # include the thread as feed, so it can be followed
    # |> debug("thread_id")
    thread_id =
      e(object, :replied, :thread_id, nil) ||
        e(object, :replied, :reply_to, :thread_id, nil)

    do_target_feeds(creator, opts, tags, reply_to_creator, thread_id)
  end

  def target_feeds({_, %{} = object}, creator, opts),
    do: target_feeds(object, creator, opts)

  defp do_target_feeds(
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

  @doc """
  Retrieves custom feeds if specified in the options.

  ## Examples

  ### With custom feeds specified:

      iex> Bonfire.Social.Feeds.maybe_custom_feeds(to_feeds: ["custom_feed_id"])
      ["custom_feed_id"]
  """
  def maybe_custom_feeds(preset_and_custom_boundary),
    do:
      preset_and_custom_boundary
      # |> debug("preset_and_custom_boundary")
      |> maybe_from_opts(:to_feeds, [])

  def user_named_or_feed_id(name, opts) do
    if current_user = current_user(opts) do
      feed_id(name, current_user)
    end ||
      named_feed_id(name, opts)
  end

  @doc """
  Gets the feed ID for a named feed.

  ## Examples

  ### For an existing named feed:

      iex> Bonfire.Social.Feeds.named_feed_id(:notifications, [])
      # Feed ID for notifications

  ### For a binary name:

      iex> Bonfire.Social.Feeds.named_feed_id("notifications", [])
      # Feed ID for notifications
  """
  def named_feed_id(name, opts \\ [])
  def named_feed_id(:explore, _), do: nil
  def named_feed_id(:remote, _), do: named_feed_id(:activity_pub)

  def named_feed_id(:notifications, opts) do
    if current_user = current_user(opts) do
      my_feed_id(:notifications, current_user)
    end
  end

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

  @doc """
  Generates the home feed IDs for a user, including extra feeds if specified.

  ## Examples

  ### With socket options and extra feeds:

      > Bonfire.Social.Feeds.my_home_feed_ids(socket_or_opts, [extra_feed_id])
      # List of home feed IDs including extra feeds

  ### Without socket options:

      > Bonfire.Social.Feeds.my_home_feed_ids(_, [extra_feed_id])
      # List of home feed IDs including extra feeds
  """
  @decorate time()
  def my_home_feed_ids(socket_or_opts, extra_feeds \\ [])
  # TODO: make configurable if user wants notifications included in home feed

  def my_home_feed_ids(socket_or_opts, extra_feeds) do
    # debug(my_home_feed_ids_user: socket_or_opts)

    current_user = current_user(socket_or_opts)

    if current_user do
      # include my outbox
      # |> debug("my_outbox_id")
      my_outbox_id =
        if Bonfire.Common.Settings.get(
             [Bonfire.Social.Feeds, :include, :outbox],
             true,
             current_user: current_user,
             name: l("Include my content"),
             description: l("Include my own posts in your feed.")
           ),
           do: my_feed_id(:outbox, current_user)

      # include my notifications?
      my_notifications_id =
        if Bonfire.Common.Settings.get(
             [Bonfire.Social.Feeds, :include, :notifications],
             true,
             current_user: current_user,
             name: l("Include Notifications"),
             description: l("Include notifications in my main feed.")
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
                   current_user: current_user,
                   name: l("Include Followed Categories"),
                   description: l("Include content from categories you follow in your feed.")
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
    else
      # debug("no current user, just returning extra feeds")
      extra_feeds
    end

    # |> debug("final")
  end

  def my_home_feed_ids(_, extra_feeds), do: extra_feeds

  @doc """
  Retrieves the feed ID for a given type and subject.

  ## Examples

  ### For a user:

      > Bonfire.Social.Feeds.my_feed_id(:notifications, user)
      # Feed ID for notifications of the user
  """
  def my_feed_id(type, other) do
    case current_user(other) do
      nil ->
        error("no user found in #{inspect(other)}")
        nil

      current_user ->
        # debug(current_user, "looking up feed for user")
        feed_id(type, current_user)
    end
  end

  @doc """
  Retrieves a list of feed IDs based on the feed name and subjects.

  ## Examples

  ### For a list of subjects:

      > Bonfire.Social.Feeds.feed_ids(:notifications, [subject1, subject2])
      # List of notification feed IDs for the subjects

  ### For a single subject:

      > Bonfire.Social.Feeds.feed_ids(:notifications, subject)
      [feed_id]
  """
  def feed_ids(feed_name, for_subjects) when is_list(for_subjects) do
    for_subjects
    |> repo().maybe_preload([:character])
    |> Enum.map(&feed_id(feed_name, &1))
    |> List.flatten()
    |> filter_empty([])
  end

  def feed_ids(feed_name, for_subject), do: [feed_id(feed_name, for_subject)]

  @doc """
  Gets the feed ID for a given feed name and subject.

  ## Examples

  ### For a character:

      > Bonfire.Social.Feeds.feed_id(:notifications, character)
      # Feed ID for notifications of the character

  ### For a binary feed name:

      > Bonfire.Social.Feeds.feed_id("notifications", subject)
      # Feed ID for notifications
  """
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

  @doc """
  Gets the feed ID for a given feed name and subject, raising an error if not found.

  ## Examples

  ### For a valid feed:

      > Bonfire.Social.Feeds.feed_id!(:notifications, subject)
      # Feed ID for notifications

  ### For an invalid feed:

      > Bonfire.Social.Feeds.feed_id!(:invalid, subject)
      ** (RuntimeError) Expected feed name and user or character, got :invalid
  """
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

  defp feed_key(other) do
    debug(other, "Unknown feed key")
    nil
  end

  @doc """
  Checks if a creator notification should be sent for a subject.

  ## Examples

  ### When creator is different:

      > Bonfire.Social.Feeds.maybe_creator_notification(subject, other_creator)
      [{:notifications, other_creator}]

  ### When creator is the same:

      > Bonfire.Social.Feeds.maybe_creator_notification(subject, subject)
      []
  """
  def maybe_creator_notification(subject, object_creator, opts \\ []) do
    if is_nil(object_creator) do
      debug("Creator notification: no creator found, returning empty list")
      []
    else
      if id(subject) != id(object_creator) and
           (opts[:local] != false or Bonfire.Social.federating?(object_creator)) do
        debug("Creator notification: notifying creator #{inspect(id(object_creator))}")
        [notifications: object_creator]
      else
        debug("Creator notification: skipping (same user or federation check failed)")
        []
      end
    end
  end

  @doc """
  Gets the inbox feed ID of the creator of the given object.

  ## Examples

  ### For an object:

      > Bonfire.Social.Feeds.inbox_of_obj_creator(object)
      # Inbox feed ID of the object's creator
  """
  def inbox_of_obj_creator(object) do
    # |> debug
    Objects.preload_creator(object) |> Objects.object_creator() |> feed_id(:notifications, ...)
  end

  # def admins_inboxes(), do: Bonfire.Me.Users.list_admins() |> admins_inboxes()
  # def admins_inboxes(admins) when is_list(admins), do: Enum.map(admins, fn x -> admin_inbox(x) end)
  # def admin_inbox(admin) do
  #   admin = admin |> repo().maybe_preload([:character]) # |> debug
  #   #|> debug()
  #   e(admin, :character, :inbox_id, nil)
  #     || feed_id(:inbox, admin)
  # end

  @doc """
  Retrieves the notifications feed IDs for all admins.
  """
  def admins_notifications(),
    do:
      Bonfire.Me.Users.list_admins()
      |> repo().maybe_preload([:character])
      |> admins_notifications()

  @doc """
  Retrieves the notifications feed IDs for the provided admin(s).

  ## Examples

  ### For an admin:

      > Bonfire.Social.Feeds.admin_notifications(admin)
      # Notifications feed ID for the admin

  ### For a list of admins:

      > Bonfire.Social.Feeds.admins_notifications([admin1, admin2])
      # List of notifications feed IDs for the admins
  """
  def admins_notifications(admins) when is_list(admins),
    do: Enum.map(admins, fn x -> admin_notifications(x) end)

  def admin_notifications(admin) do
    e(admin, :character, :notifications_id, nil) ||
      feed_id(:notifications, admin)
  end

  @doc """
  Creates a feed for the given subject if it doesn't already exist.

  ## Examples

  ### For a new feed:

      > Bonfire.Social.Feeds.maybe_create_feed(:notifications, subject)
      {:ok, feed_id}

  ### For an existing feed:

      > Bonfire.Social.Feeds.maybe_create_feed(:notifications, existing_subject)
      {:ok, existing_feed_id}
  """
  def maybe_create_feed(type, for_subject) do
    with feed_id when is_binary(feed_id) <- create_box(type, for_subject) do
      # debug(for_subject)
      debug(
        "created new #{inspect(type)} with id #{inspect(feed_id)} for #{inspect(uid(for_subject))}"
      )

      feed_id
    else
      e ->
        error("could not find or create feed (#{inspect(e)}) for #{inspect(uid(for_subject))}")
        nil
    end
  end

  @doc """
  Creates an inbox or outbox for a character.

  ## Examples

      > Bonfire.Social.Feeds.create_box(:inbox, %Character{id: 1})
      {:ok, box_id}

      > Bonfire.Social.Feeds.create_box(:outbox, %Character{id: 2})
      {:ok, box_id}
  """
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
