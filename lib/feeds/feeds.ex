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

  @doc """
  Normalizes string and legacy atom feed names for comparison.

  ## Examples

      iex> normalize_feed_name("  Test ")
      "test"

      iex> normalize_feed_name(:test)
      "test"

      iex> normalize_feed_name(nil)
      nil
  """
  def normalize_feed_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
  end

  def normalize_feed_name(nil), do: nil

  def normalize_feed_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> normalize_feed_name()
  end

  def normalize_feed_name(_name), do: nil

  def feed_presets_permitted(opts) do
    Bonfire.Social.Feeds.feed_presets(opts)
    |> Enum.filter(fn {_slug, preset} ->
      case check_feed_preset_permitted(preset, opts) |> debug(inspect(preset)) do
        true -> true
        _error -> false
      end
    end)
    |> localise_tree(__MODULE__)
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
        debug(presets, "Feed `#{inspect(name)}` not found")
        {:error, :not_found}

      preset ->
        case check_feed_preset_permitted(preset, opts) do
          true -> {:ok, localise_tree(preset, __MODULE__)}
          other -> other
        end
    end
  end

  def feed_preset_if_permitted(other, _opts) do
    debug(other, "Feed preset name is not valid")
    {:error, :not_found}
  end

  # Preset `name`/`description` and the `assigns` display keys (`page_title`/`feed_title`/`feedback_*`)
  # use `l/1` in `RuntimeConfig.config/0`, so they're frozen to the boot locale. `localise_tree/3`
  # re-translates them per-request against the `bonfire_social` domain — the single point of
  # translation, applied at both preset-fetch chokepoints above.

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
    fan_out_feed_ids(
      me,
      boundary,
      e(assigns, :mentions, []),
      e(assigns, :reply_to, :created, :creator, nil),
      e(assigns, :reply_to, :replied, :thread, :id, nil),
      notify_feeds: notify_feeds
    )
  end

  @doc """
  THE single source of truth for "boundary + context → feed ids". Both `feed_ids_to_publish/4`
  (the Epic Act path, from the epic's `assigns`) and `target_feeds/3` (the publish/federation-ingest
  path, from a changeset or object) extract their context — mentions, reply_to_creator, thread_id —
  and delegate here, so the two can never drift apart again (plan: local-remote-feeds.md Phase 0).

  `boundary` is a boundary preset name. `opts` may carry `:notify_feeds` (precomputed notify feeds
  that OVERRIDE the computed ones — the Act passes these) and `:to_feeds` (extra custom feeds, via
  `maybe_custom_feeds/1`). The notify pipeline is `reply_and_or_mentions_notifications_feeds/4`
  (boundary-aware `users_to_notify` filtering + uniform user resolution), and the creator's own
  notifications feed is always dropped (no self-notify).
  """
  def fan_out_feed_ids(
        creator,
        boundary,
        mentions \\ [],
        reply_to_creator \\ nil,
        thread_id \\ nil,
        opts \\ []
      )

  def fan_out_feed_ids(_creator, "admins", _mentions, _reply_to_creator, _thread_id, _opts),
    do: admins_notifications()

  def fan_out_feed_ids(creator, boundary, mentions, reply_to_creator, thread_id, opts) do
    [
      maybe_custom_feeds(opts) || [],
      # thread feed (TODO: so the thread can be followed)
      # thread_id,
      # author's timeline
      maybe_my_outbox_feed_id(creator, boundary),
      # guest/local/federated instance feeds for this boundary class (origin-aware when addressed)
      global_feed_ids(creator, boundary, opts),
      # notifications of reply_to creator + mentions (boundary-filtered), unless the caller
      # precomputed them (the Act passes `notify[:notify_feeds]`)
      opts[:notify_feeds] ||
        reply_and_or_mentions_notifications_feeds(creator, boundary, mentions, reply_to_creator),
      # when the caller sets `notify_to_circles` (e.g. a deliberate share), also ping the explicit
      # `to_circles` recipients — their notifications feed, which also surfaces in their home feed
      if(opts[:notify_to_circles],
        do: feed_ids(:notifications, maybe_from_opts(opts, :to_circles, [])),
        else: []
      )
    ]
    |> List.flatten()
    |> Enum.uniq()
    # avoid self-notifying (do_target_feeds did this explicitly; the Act relied on filter_reply_and_or_mentions)
    |> Enum.reject(&(&1 == feed_id(:notifications, creator)))
    |> Enums.filter_empty([])
    |> debug("fan-out feed ids")
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

  defp global_feed_ids(creator, boundary, opts) do
    if opts[:feed_addressing] || Config.get([__MODULE__, :feed_addressing], false) do
      addressed_feed_ids(creator, boundary, opts)
    else
      Config.get([__MODULE__, :global_feeds], @global_feeds)
      |> Map.get(boundary, [])
      |> Enum.map(&named_feed_id/1)
    end
  end

  # origin×boundary bucket for a NEW write. Public/local/public_remote are origin-determined by the
  # boundary preset itself; only the custom catch-all needs the author's origin (`is_local?`) to split
  # `local_custom` vs `remote_custom` — a remote non-public ingest also gets a custom boundary, and the
  # fetcher service character classifies as remote, so this routes remote content to the remote bucket.
  defp addressed_feed_ids(_creator, "public", _opts), do: [named_feed_id(:local_public)]
  defp addressed_feed_ids(_creator, "local", _opts), do: [named_feed_id(:local_instance_only)]
  defp addressed_feed_ids(_creator, "public_remote", _opts), do: [named_feed_id(:remote_public)]
  defp addressed_feed_ids(_creator, "admins", _opts), do: []

  defp addressed_feed_ids(creator, _custom, opts) do
    # config `:addressing_origin_by` picks whose locality decides for mixed-locality activities (boosts/quotes): `:subject` (the actor's feed) or `:object` (the referenced content's origin). Falls back to the subject when `:object` is set but no object was passed.
    origin_thing =
      case opts[:addressing_origin_by] || Config.get([__MODULE__, :addressing_origin_by], :object) do
        :object -> maybe_from_opts(opts, :object, nil) || creator
        _ -> creator
      end

    if is_local?(origin_thing),
      do: [named_feed_id(:local_custom)],
      else: [named_feed_id(:remote_custom)]
  end

  @doc """
  The feed NAMES (atoms) that make up each multi-bucket feed concept. 

  Note the singular `named_feed_id` gives the ONE legacy id for a name (`named_feed_id(:local)` = 3SERS), so it and `feed_names(:local)` (= all local buckets) are complementary, not the same thing.

    * `:local` — legacy `:local` ∪ local buckets
    * `:remote` — legacy `:activity_pub` ∪ remote buckets
    * `:public` — guest-visible: legacy `:guest` ∪ the public buckets
    * `:custom_boundaries` — custom content, both origins (local `to_circles`/`mentions` ∪ non-public remote ingests)
    * `:explore` — all activities: guest ∪ local ∪ remote
  """
  def feed_names(:local), do: [:local, :local_public, :local_instance_only]
  def feed_names(:remote), do: [:activity_pub, :remote_public]
  def feed_names(:public), do: [:guest, :local_public, :remote_public]
  def feed_names(:custom_boundaries), do: [:local_custom, :remote_custom]
  def feed_names(:explore), do: [:guest | feed_names(:local) ++ feed_names(:remote)]

  @doc """
  The origin×boundary bucket ids that the origin filter (`Activities.maybe_filter/3` `:origin`) covers.

  When a feed query carries BOTH an `origin` filter and an explicit feed-id list, these ids are stripped
  from the list (the origin filter already scopes locality), leaving only non-locality ids (e.g. a group
  outbox) to apply alongside the origin filter. See `FeedLoader.feed_query/3`.
  """
  def locality_feed_ids, do: named_feed_ids(:local) ++ named_feed_ids(:remote)

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
      |> debug("filtered")
      |> users_to_notify(
        boundary,
        to_circles
      )
      |> debug("users to notify")

    %{
      notify_feeds: notify_feeds(users),
      notify_emails: notify_emails(users)
    }
    |> debug("to notify")
  end

  defp filter_reply_and_or_mentions(me, reply_to_creator, mentions) do
    my_id = Enums.id(me)

    ([reply_to_creator] ++ mentions)
    # avoid self-notifying
    |> Enum.reject(&(Enums.id(&1) == my_id))
  end

  defp users_to_notify(users, boundary, to_circles \\ []) do
    # Drop unresolved entries: a mention can be a bare id string rather than a user struct
    # (e.g. a group posts to itself via `mentions: [group_id]`, which drives tagging/auto-boost
    # into the group feed but is not a user to notify). Passing a bare id to `maybe_preload`
    # raises `BadMapError`, so reject them here — as the `public_remote` branch already did.
    users = Enum.reject(users, &(is_nil(&1) || is_binary(&1)))

    # debug(epic, act, users, "users going in")
    cond do
      boundary in ["public", "mentions"] ->
        users
        |> filter_empty([])
        |> repo().maybe_preload([:character, :settings])

      boundary in ["public_remote"] ->
        users
        |> repo().maybe_preload([:character, :settings])

      boundary == "local" ->
        users
        |> filter_empty([])
        |> repo().maybe_preload([:character, :peered, :settings])
        # notify only local users
        |> Enum.filter(&is_local?/1)

      true ->
        # for custom boundaries we should only notify mentions & reply_to_creator IF they are included in the object's boundaries
        # TODO: check also if they can read the object otherwise (for example, by being member of an included circle)

        to_circles_ids = Enums.ids(to_circles)

        users
        |> filter_empty([])
        |> Enum.filter(&(id(&1) in to_circles_ids))
        |> repo().maybe_preload([:character, :settings])
    end

    # |> debug()
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

  ## Examples

  ### When given a changeset:

      > Bonfire.Social.Feeds.target_feeds(changeset, creator, opts)
      # List of target feed IDs based on the changeset

  ### When given an object:

      > Bonfire.Social.Feeds.target_feeds(object, creator, opts)
      # List of target feed IDs based on the object
  """
  def target_feeds(%Ecto.Changeset{} = changeset, creator, opts) do
    # extract context from the (not-yet-inserted) changeset, then delegate to the shared interpreter
    mentions = e(changeset, :changes, :post_content, :changes, :mentions, [])

    reply_to_creator =
      e(changeset, :changes, :replied, :changes, :replying_to, :created, :creator, nil)

    thread_id =
      e(changeset, :changes, :replied, :changes, :thread_id, nil) ||
        e(changeset, :changes, :replied, :changes, :replying_to, :thread_id, nil)

    fan_out_feed_ids(
      creator,
      maybe_from_opts(opts, :boundary, opts),
      mentions,
      reply_to_creator,
      thread_id,
      opts
    )
  end

  def target_feeds(%{} = object, creator, opts) do
    object =
      object
      |> repo().maybe_preload([replied: [reply_to: [created: :creator]]], prune: true)
      |> repo().maybe_preload(:tags, prune: true)

    tags = e(object, :tags, [])
    reply_to_creator = e(object, :replied, :reply_to, :created, :creator, nil)

    thread_id =
      e(object, :replied, :thread_id, nil) ||
        e(object, :replied, :reply_to, :thread_id, nil)

    # carry the published object so the `:addressing_origin_by == :object` policy can classify a
    # boost/ingest by the boosted/referenced object's locality (for original posts object==subject)
    opts = if(Keyword.keyword?(opts), do: Keyword.put(opts, :object, object), else: opts)

    fan_out_feed_ids(
      creator,
      maybe_from_opts(opts, :boundary, opts),
      tags,
      reply_to_creator,
      thread_id,
      opts
    )
  end

  def target_feeds({_, %{} = object}, creator, opts),
    do: target_feeds(object, creator, opts)

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
  Resolve the PubSub topic(s) for a `feedActivity` GraphQL subscription, given the
  subscription args (`%{feed_name: ...}` or `%{thread_id: ...}`) and the current
  user. Returns a list of feed/thread ids matching what `LivePush` broadcasts to:

    * a `thread_id` → that thread's topic
    * `feed_name: "my"` → the viewer's home feeds (`my_home_feed_ids/1`)
    * any other `feed_name` (`notifications`, `local`, `remote`, …) → its feed id

  Empty list when nothing resolves (e.g. a user feed requested without a user).
  """
  def subscription_topics(args, current_user) do
    cond do
      is_binary(args[:thread_id]) ->
        # Only subscribe to a thread the viewer can actually read — otherwise a
        # client could receive replies to a private/DM thread just by knowing its
        # id (the subscription delivers what LivePush publishes to the topic, with
        # no later per-activity boundary check). Empty = no topic = denied.
        case Objects.read(args[:thread_id], current_user: current_user) do
          {:ok, _} -> [args[:thread_id]]
          _ -> []
        end

      is_binary(args[:feed_name]) ->
        case Bonfire.Common.Types.maybe_to_atom(args[:feed_name]) do
          :my ->
            if(current_user, do: my_home_feed_ids(current_user: current_user), else: [])

          other ->
            user_named_or_feed_id(other, current_user: current_user) |> List.wrap()
        end

      true ->
        []
    end
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
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

  # origin×boundary feed buckets: the `_custom` buckets reuse the legacy feed ids (no separate pointer)
  def named_feed_id(:local_custom, _), do: named_feed_id(:local)
  def named_feed_id(:remote_custom, _), do: named_feed_id(:activity_pub)

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
  The plural of `named_feed_id/2`: resolves a feed NAME to its feed id(s), use it for feeds that map to a list of buckets (e.g. `:local` → `[:local, :local_public, :local_instance_only]`). Returns a list of feed ids or an empty list if none are found.
  """
  def named_feed_ids(feed_name, opts \\ [])

  def named_feed_ids(concept, _opts)
      when concept in [:local, :remote, :public, :custom_boundaries, :explore],
      do: Enum.map(feed_names(concept), &named_feed_id/1)

  def named_feed_ids(feed_name, opts) when is_atom(feed_name) and not is_nil(feed_name) do
    case named_feed_id(feed_name, opts) || my_feed_id(feed_name, opts) do
      feed when is_binary(feed) or is_list(feed) ->
        feed

      itself when itself == feed_name ->
        my_feed_id(feed_name, opts)

      e ->
        error(e, "not a known feed: `#{inspect(feed_name)}`")
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
        debug(other, "no user found")
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
