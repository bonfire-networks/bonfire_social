defmodule Bonfire.Social.Boosts do
  @moduledoc """
  Mutate, query, and federate boosts (re-sharing an activity or object).

  Boosts are implemented on top of the `Bonfire.Data.Edges.Edge` schema (see `Bonfire.Social.Edges` for shared functions)
  """

  # alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Data.Social.Activity
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social

  alias Bonfire.Social.Objects

  alias Bonfire.Data.Edges.Edge

  use Bonfire.Common.Repo,
    searchable_fields: [:booster_id, :boosted_id]

  # import Bonfire.Social
  use Bonfire.Common.Utils

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Boost
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Announce",
      {"Create", "Announce"},
      {"Undo", "Announce"},
      {"Delete", "Announce"}
    ]

  @doc """
  Checks if a user has boosted an object.

  ## Examples

      iex> Bonfire.Social.Boosts.boosted?(user, object)
      true

  """
  def boosted?(%{} = user, object),
    do: Edges.exists?(__MODULE__, user, object, skip_boundary_check: true)

  @doc """
  Counts boosts based on filters and options.

  ## Examples

      iex> Bonfire.Social.Boosts.count([subjects: user_id], [])
      5 # user made 5 boosts, across all objects

      iex> Bonfire.Social.Boosts.count(user, object)
      3 # user boosted object 3 times

      iex> Bonfire.Social.Boosts.count(object, [])
      10 # object was boosted 5 times, across all users

  """
  def count(filters \\ [], opts \\ [])

  def count(filters, opts) when is_list(filters) and is_list(opts) do
    Edges.count(__MODULE__, filters, opts)
  end

  def count(%{} = user, object) when is_struct(object) or is_binary(object),
    do: Edges.count_for_subject(__MODULE__, user, object, skip_boundary_check: true)

  def count(object, _) when is_struct(object),
    do: Edges.count(:boost, object, skip_boundary_check: true)

  @doc """
  Gets the date of the latest boost by a user for an object.

  ## Examples

      iex> Bonfire.Social.Boosts.date_last_boosted(user, object)
      ~U[2023-07-29 12:34:56Z]

  """
  def date_last_boosted(%{} = user, object),
    do: Edges.last_date(__MODULE__, user, object, skip_boundary_check: true)

  @doc """
  Retrieves a boost edge by subject and object.

  ## Examples

      iex> Bonfire.Social.Boosts.get(subject, object)
      {:ok, %Bonfire.Data.Social.Boost{}}

  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  @doc """
    Retrieves a boost edge, raising an error if not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  @doc """
  Boosts an object for a user.

  ## Examples

      iex> Bonfire.Social.Boosts.boost(user, object)
      {:ok, %Bonfire.Data.Social.Boost{}}

  """
  def boost(booster, boosted, opts \\ [])

  def boost(%{} = booster, %{} = object, opts) do
    if Bonfire.Boundaries.can?(booster, :boost, object) do
      maybe_boost(booster, object, opts)
    else
      error(l("Sorry, you cannot boost this"))
    end
  end

  def boost(%{} = booster, boosted, opts) when is_binary(boosted) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(
             boosted,
             opts ++
               [
                 current_user: booster,
                 verbs: [:boost]
               ]
           ) do
      # debug(liked)
      maybe_boost(booster, object, opts)
    else
      _ ->
        error(l("Sorry, you cannot boost this"))
    end
  end

  def maybe_boost(%{} = booster, %{} = boosted, opts \\ []) do
    with :ok <- reboost_check(booster, boosted) do
      do_boost(booster, boosted, opts)
    end
  end

  @doc """
  Whether another boost of an object by a user would be a duplicate now, by the rule `boost/3` applies: a first boost never is, a repeat is unless `can_reboost_after` allows it (never, always, or once that many seconds have passed since the last). Asked by federation (`Bonfire.Federate.ActivityPub.Adapter.activity_exists?/3`), so a boost from another instance is held to the same rule.

  ## Examples

      iex> Bonfire.Social.Boosts.duplicate?(user, object)
      false

  """
  def duplicate?(%{} = booster, %{} = boosted), do: reboost_check(booster, boosted) != :ok

  defp reboost_check(booster, boosted) do
    case Config.get([Bonfire.Social.Boosts, :can_reboost_after], false)
         |> debug("can_reboost_after?") do
      seconds when is_integer(seconds) ->
        # max 1 re-boost every X seconds
        case date_last_boosted(booster, boosted) do
          nil ->
            :ok

          date_last_boosted ->
            if DateTime.diff(DateTime.now!("Etc/UTC"), date_last_boosted, :second)
               |> debug("last boosted X seconds ago") >
                 seconds,
               do: :ok,
               else: {:error, l("You already boosted this recently.")}
        end

      true ->
        # unlimited re-boosts
        :ok

      _ ->
        # do not allow re-boosts
        if !boosted?(booster, boosted),
          do: :ok,
          else: {:error, :already_boosted}
    end
  end

  defp do_boost(%{} = booster, %{} = boosted, opts \\ []) do
    object_creator =
      opts[:object_creator] ||
        (
          boosted =
            Objects.preload_creator(boosted)
            |> debug("boosted object")

          Objects.object_creator(boosted)
        )

    # |> debug("the creator")

    # Use "public_remote" boundary for federated boosts
    boundary =
      if e(opts, :local, true) != false,
        do: "public",
        else: "public_remote"

    # |> debug("boundary")

    opts =
      opts
      |> Keyword.merge(
        # TODO: get the preset for boosting from config and/or user's settings
        boundary: boundary,
        # to_circles: [id(object_creator)], # NOTE: commented out to avoid creating per-object ACLs - preset is sufficient
        to_feeds:
          [outbox: booster] ++
            if(e(opts, :notify_creator, true),
              do: Feeds.maybe_creator_notification(booster, object_creator, opts),
              else: []
            )
        # |> debug("boost_to_feeds")
      )

    with {:ok, boost} <- create(booster, boosted, opts) do
      # livepush will need a list of feed IDs we published to
      feed_ids =
        for fp <- e(boost, :feed_publishes, []),
            do: e(fp, :feed_id, nil)

      # |> debug("published feed_ids")

      # Only notify the post creator (not the booster themselves)
      creator_notify_feeds =
        if e(opts, :notify_creator, true) and id(booster) != id(object_creator),
          do: [Feeds.feed_id(:notifications, object_creator)],
          else: []

      if !opts[:skip_live_push] do
        maybe_apply(Bonfire.Social.LivePush, :emit_live, [
          boost,
          feed_ids,
          [
            # shown as being about what was boosted, rather than about the boost
            object: Objects.preload_creator(boosted, force: true),
            push_to_thread: false,
            notify: creator_notify_feeds
          ]
        ])
      end

      if !opts[:skip_federation],
        do:
          Social.maybe_federate_and_gift_wrap_activity(booster, boost)
          |> debug("maybe_federated the boost"),
        else: {:ok, boost}
    end
  end

  @doc """
  Removes a boost from an object for a user, if one exists

  ## Examples

      iex> Bonfire.Social.Boosts.unboost(user, object)
      {:ok, _}

  """
  def unboost(booster, boosted, opts \\ [])

  def unboost(booster, %{} = boosted, opts) do
    # loaded before it goes, since federating its undo reads who boosted what off its edge
    boost =
      with {:ok, boost} <- get(booster, boosted, skip_boundary_check: true),
           do: repo().maybe_preload(boost, :edge)

    # delete the Boost
    Edges.delete_by_both(booster, Boost, boosted)
    # delete the boost activity & feed entries
    with {:ok, _} = deleted <- Activities.delete_by_subject_verb_object(booster, :boost, boosted) do
      # servers the boost reached keep showing it until told, by an `Undo{Announce}`
      if match?(%Boost{}, boost) and !opts[:skip_federation],
        do: Social.maybe_federate(booster, :delete, boost)

      deleted
    end
  end

  def unboost(booster, boosted, opts) when is_binary(boosted) do
    with {:ok, boosted} <-
           Bonfire.Common.Needles.get(boosted, opts ++ [current_user: booster]) do
      # debug(liked)
      unboost(booster, boosted, opts)
    end
  end

  @doc """
  Removes one exact boost after verifying its subject and object.

  The edge is locked and deleted by its recorded ID, so a later replacement boost between the same subject and object is never removed.
  """
  def unboost_by_id(boost_id, booster, boosted)
      when is_binary(boost_id) and (is_map(booster) or is_binary(booster)) and
             (is_map(boosted) or is_binary(boosted)) do
    booster_id = uid(booster)
    boosted_id = uid(boosted)
    boost_table_id = Bonfire.Common.Types.table_id(Boost)

    repo().transaction(fn ->
      from(edge in Edge,
        where:
          edge.id == ^boost_id and edge.subject_id == ^booster_id and
            edge.object_id == ^boosted_id and edge.table_id == ^boost_table_id,
        lock: "FOR UPDATE"
      )
      |> repo().one()
      |> case do
        %Edge{} = edge ->
          case repo().delete(edge) do
            {:ok, _edge} -> Activities.delete({:id, boost_id})
            {:error, reason} -> repo().rollback(reason)
          end

        nil ->
          repo().rollback(:not_found)
      end
    end)
  end

  def unboost_by_id(_boost_id, _booster, _boosted), do: {:error, :invalid_boost}

  @doc """
  Lists boosts by the current user.

  ## Examples

      iex> Bonfire.Social.Boosts.list_my(current_user: me)
      [%Bonfire.Data.Social.Boost{}, ...]

  """
  def list_my(opts) do
    list_by(current_user_required!(opts), opts)
  end

  @doc """
  Lists boosts by a specific user.

  ## Examples

      iex> Bonfire.Social.Boosts.list_by(user_id)
      [%Bonfire.Data.Social.Boost{}, ...]

  """
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    # query FeedPublish
    # [preload: [object: [created: [:creator]]]])
    list_paginated(
      [subjects: by_user],
      to_options(opts) ++ [preload: :object_with_creator, subject_user: by_user]
    )
  end

  @doc """
  Lists boosts of a specific object.

  ## Examples

      iex> Bonfire.Social.Boosts.list_of(object_id)
      [%Bonfire.Data.Social.Boost{}, ...]

  """
  def list_of(id, opts \\ []) when is_binary(id) or is_list(id) or is_map(id) do
    opts = to_options(opts)
    # query FeedPublish
    list_paginated([objects: id], opts ++ [preload: :subject])
  end

  @doc "A query of the ids of who boosted `object`. Not boundarised: for a caller that composes it."
  def query_booster_ids(object) do
    query([objects: uid(object)], skip_boundary_check: true)
    |> exclude(:preload)
    |> select([edge: edge], edge.subject_id)
  end

  @doc """
  Lists boosts with pagination.

  ## Examples

      iex> Bonfire.Social.Boosts.list_paginated([subjects: user_id], [limit: 10])
      %{edges: [%Bonfire.Data.Social.Boost{}, ...], page_info: %{...}}

  """
  def list_paginated(filters, opts \\ []) do
    filters
    |> query(opts)
    # |> debug()
    |> repo().many_maybe_paginated(opts[:paginate?], opts)
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Boost, filters, opts)

    # |> proload(edge: [
    #   # subject: {"booster_", [:profile, :character]},
    #   # object: {"boosted_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
  end

  def query([my: :boosts], opts),
    do: query([subjects: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp create(booster, boosted, opts) do
    Edges.insert(Boost, booster, :boost, boosted, opts)
  end

  @doc """
  Publishes a federated activity for a boost action.

  ## Examples

      iex> Bonfire.Social.Boosts.ap_publish_activity(subject, :create, boost)
      {:ok, _activity}

  """
  def ap_publish_activity(subject, :delete, boost) do
    with {:ok, booster} <-
           ActivityPub.Actor.get_cached(
             pointer: subject || e(boost.edge, :subject, nil) || e(boost.edge, :subject_id, nil)
           ),
         {:ok, object} <-
           ActivityPub.Object.get_cached(
             pointer: e(boost.edge, :object, nil) || e(boost.edge, :object_id, nil)
           ) do
      # only the booster's own instance can undo their boost, so an incoming `Undo` isn't sent back out as them; `== false` because `local` is nil on a tombstoned actor
      if booster.local == false,
        do: {:ignore, "Not our boost to undo, so nothing to federate"},
        else: ActivityPub.unannounce(%{actor: booster, object: object})
    else
      {:error, :not_found} ->
        :ignore

      e ->
        error(e)
    end
  end

  def ap_publish_activity(subject, _verb, boost) do
    boost = repo().maybe_preload(boost, :edge)

    boosted = e(boost, :edge, :object, nil) || e(boost, :edge, :object_id, nil)
    booster = subject || e(boost, :edge, :subject, nil) || e(boost, :edge, :subject_id, nil)

    with {:ok, booster} <-
           ActivityPub.Actor.get_cached(pointer: booster)
           |> tap(fn
             {:ok, _} -> nil
             _ -> warn(booster, "Not federating this boost: found no AP actor for the booster")
           end),
         # separated from the actor lookup so a miss says WHICH of the two is missing: they fail for entirely different reasons
         {:ok, object} <-
           ActivityPub.Object.get_cached(pointer: boosted)
           |> tap(fn
             {:ok, _} ->
               nil

             _ ->
               warn(
                 boosted,
                 "Not federating this boost: what was boosted has no AP object linked to it"
               )
           end),
         # an object not addressed to Public (eg. a post in a group that doesn't federate, capped to `nonfederated`, yet with an AP object addressed to the group) can't be announced (`ActivityPub.announce/2` checks the same): the boost stays local, which isn't an error
         true <- ActivityPub.Utils.public?(object.data) do
      # the BOOST's id: it is what the announce points back at, and what dates it
      id = Enums.id(boost)

      ActivityPub.announce(%{
        actor: booster,
        object: object,
        pointer: id,
        published:
          DatesTimes.date_from_pointer(id)
          |> DateTime.to_iso8601()
      })
    else
      # a miss here silently drops the whole Announce, which is indistinguishable from federation being switched off, so it says so rather than passing quietly. Which of the two was missing is said by whichever lookup failed, not guessed at here
      {:error, :not_found} ->
        :ignore

      false ->
        debug(boosted, "Not federating this boost: what was boosted isn't public")
        :ignore

      e ->
        error(e)
    end
  end

  @doc """
  Receives and processes a federated boost activity.

  ## Examples

      iex> Bonfire.Social.Boosts.ap_receive_activity(creator, activity, object)
      {:ok, _boost}

  """
  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Announce"} = data} = _activity,
        object
      ) do
    with {:ok, pointable} <-
           Utils.maybe_apply(
             Bonfire.Federate.ActivityPub.AdapterUtils,
             :return_pointable,
             [object, [current_user: creator, verbs: [:boost]]]
           ),
         {:ok, _} = boosted <- boost_or_existing(creator, pointable) do
      maybe_publish_in_announcing_group(creator, data, object, pointable)
      boosted
    end
  end

  def ap_receive_activity(
        creator,
        %{data: %{"type" => "Undo"}} = _activity,
        %{data: %{"object" => boosted_object}} = _object
      ) do
    with {:ok, object} <-
           ActivityPub.Object.get_cached(ap_id: boosted_object),
         {:ok, pointable} <-
           Utils.maybe_apply(
             Bonfire.Federate.ActivityPub.AdapterUtils,
             :return_pointable,
             [object, [current_user: creator, verbs: [:boost]]]
           ) do
      # the `Undo` being applied IS the federated one (from another server, or posted by a local actor through C2S), so applying it sends nothing more
      unboost(creator, pointable, skip_boundary_check: true, skip_federation: true)
    end
  end

  # A group announcing a post that it already boosted has nothing to add: that is how a community tells us it accepted what we published into it, after our own group copy boosted it when we did. The existing boost is the answer, not an error. `boost/3` still decides whether a repeat is allowed (`can_reboost_after`), and only when it refuses as `:already_boosted` do we return the one that is there.
  defp boost_or_existing(creator, pointable) do
    case boost(creator, pointable, local: false) do
      {:error, :already_boosted} -> get(creator, pointable)
      other -> other
    end
  end

  # A group announcing a post whose own `audience` names that group is relaying a post published in it: that is how a Bonfire group relays its members' posts, as a plain `Announce` of the post where the threadiverse wraps the `Create`. So it is published in the mirror, as a post the group relays as an activity is, and carries the group's moderators ACL that gives its moderators standing over it (eg. to lock it). Both halves are needed: an author naming a group does not put a post in it, and a group boosting a post that names another group (or none) only shares it
  defp maybe_publish_in_announcing_group(
         %{__struct__: Bonfire.Classify.Category} = group,
         %{"actor" => announcer},
         %{data: %{"audience" => audience}},
         pointable
       ) do
    if ActivityPub.Object.get_ap_id(announcer) in Enum.map(
         List.wrap(audience),
         &ActivityPub.Object.get_ap_id/1
       ) do
      # locality loaded here, as the `:tag` check `publish_existing_in/3` makes on the author requires
      author =
        Objects.object_creator(Objects.preload_creator(pointable))
        |> repo().maybe_preload(character: [:peered])

      Utils.maybe_apply(
        Bonfire.Classify,
        :publish_existing_in,
        [pointable, author, [group]],
        fallback_return: nil
      )
    end
  end

  defp maybe_publish_in_announcing_group(_group, _data, _object, _pointable), do: nil
end
