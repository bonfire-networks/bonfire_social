defmodule Bonfire.Social.Pins do
  @moduledoc """
  Mutate or query pins (which make an activity or object appear at the beginning of feeds or other lists).

  This module provides functionality to manage and query pins, including creating, deleting, and listing pins.

  Pins are implemented on top of the `Bonfire.Data.Edges.Edge` schema (see `Bonfire.Social.Edges` for shared functions)
  """

  # alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Pin
  # alias Bonfire.Data.Social.PinCount
  # alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social
  alias Bonfire.Social.Objects

  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  import Ecto.Query
  alias Bonfire.Social
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  # TODO: check for :pin boundary verb instead?
  @boundary_verb :boost

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Pin
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Pin",
      {"Create", "Pin"},
      {"Undo", "Pin"},
      {"Delete", "Pin"},
      # owns the Mastodon-compatible `featured` collection (a user's pinned objects):
      # served via collection_items/collection_total, mutated via Add/Remove
      {:collection, "featured"},
      {"Add", "featured"},
      {"Remove", "featured"}
    ]

  defp instance_scope,
    do: Bonfire.Boundaries.Circles.get_id(:local) || "3SERSFR0MY0VR10CA11NSTANCE"

  @doc "Subject id for instance-wide pins (the local instance circle, or a fallback constant)."
  def instance_scope_id, do: instance_scope()

  defp pins_ranked_query(subjects, scope) do
    from(p in Pin,
      join: e in Bonfire.Data.Edges.Edge,
      as: :edge,
      on: e.id == p.id,
      left_join: r in Bonfire.Data.Assort.Ranked,
      as: :ranked,
      on: r.item_id == e.object_id and r.scope_id == ^scope,
      where: e.subject_id in ^List.wrap(subjects)
    )
  end

  @doc "Instance-pinned object ids, in admin order (`rank_pin(_, :instance, pos)`), unranked last."
  def instance_pinned_object_ids do
    scope = instance_scope()

    pins_ranked_query([scope], scope)
    |> order_by([edge: e, ranked: r], asc_nulls_last: r.rank, asc: e.id)
    |> select([edge: e], e.object_id)
    |> repo().many()
    |> Enum.uniq()
  end

  @doc """
  Ordered object ids for a user's groups sidebar, fetched in ONE query: instance-pinned groups first
  (admin order via `rank_pin`), then the user's own pins (newest first). No boundary check.
  """
  def sidebar_pinned_object_ids(user) do
    scope = instance_scope()
    subjects = Enum.uniq(Enum.reject([scope, uid(user)], &is_nil/1))

    {instance, user_rows} =
      pins_ranked_query(subjects, scope)
      |> select([edge: e, ranked: r], {e.subject_id, e.object_id, r.rank, e.id})
      |> repo().many()
      |> Enum.split_with(fn {subject_id, _, _, _} -> subject_id == scope end)

    instance_ids =
      instance
      |> Enum.sort_by(fn {_, _, rank, edge_id} -> {is_nil(rank), rank, edge_id} end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()

    instance_set = MapSet.new(instance_ids)

    user_ids =
      user_rows
      |> Enum.sort_by(fn {_, _, _, edge_id} -> edge_id end, :desc)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(instance_set, &1))

    instance_ids ++ user_ids
  end

  # category pins are a local sidebar concern, not the Mastodon `featured` (posts) collection — never federate them
  defp skip_federation?(pinned), do: is_struct(pinned, Bonfire.Classify.Category)

  @doc """
  Checks if an object is pinned by the instance.

  ## Parameters

    - scope: The scope to check for pinning (eg. `:instance` or a user)
    - object: The object to check for pinning.

  ## Examples

      iex> Bonfire.Social.Pins.pinned?(:instance, %Post{id: "post123"})
      true

      iex> Bonfire.Social.Pins.pinned?(%User{id: "user123"}, %Post{id: "post456"})
      false
  """
  def pinned?(:instance, object),
    do: Edges.exists?(__MODULE__, instance_scope(), object, skip_boundary_check: true)

  def pinned?(scope, object),
    do: Edges.exists?(__MODULE__, scope, object, skip_boundary_check: true)

  @doc """
  Retrieves a Pin edge between a subject and an object.

  ## Parameters

    - subject: The subject (usually a user) of the Pin edge.
    - object: The object that was pinned.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Pins.get(%User{id: "user123"}, %Post{id: "post456"})
      {:ok, %Pin{}}

  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  @doc """
    Similar to `get/3`, but raises an error if the Pin edge is not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  @doc """
  Lists pins by a specific subject.

  ## Parameters

    - subject: The subject (usually a user) who created the pins.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Pins.by_pinner(%User{id: "user123"})
      [%Pin{}, ...]

  """
  def by_pinner(%{} = subject, opts \\ []),
    do:
      (opts ++ [subjects: subject])
      |> query([current_user: subject] ++ List.wrap(opts))
      |> repo().many()

  @doc """
  Lists pins of a specific object.

  ## Parameters

    - object: The object that was pinned.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Pins.by_pinned(%Post{id: "post456"})
      [%Pin{}, ...]

  """
  def by_pinned(%{} = object, opts \\ []),
    do: (opts ++ [objects: object]) |> query(opts) |> repo().many()

  @doc """
  Creates a pin for an object.

  ## Parameters

    - pinner: The user creating the pin.
    - object: The object to be pinned.
    - scope: The scope of the pin (eg. `:instance`, optional).
    - opts: Additional options for creating the pin (optional).

  ## Examples

      iex> Bonfire.Social.Pins.pin(%User{id: "user123"}, %Post{id: "post456"})
      {:ok, %Pin{}}

      iex> Bonfire.Social.Pins.pin(%User{id: "user123"}, %Post{id: "post456"}, :instance)
      {:ok, %Pin{}}

  """
  def pin(pinner, object, scope \\ nil, opts \\ [])

  def pin(pinner, object, :instance, opts) do
    if Bonfire.Boundaries.can?(pinner, :mediate, :instance) do
      pin(instance_scope(), object, nil, opts ++ [skip_boundary_check: true, to_feeds: []])
    else
      error(l("Sorry, you cannot pin to the instance"))
    end
  end

  def pin(pinner, %{} = object, scope, opts) do
    # pinning a Category you can reach to your own sidebar never needs the `:boost` verb
    if opts[:skip_boundary_check] || is_struct(object, Bonfire.Classify.Category) ||
         Bonfire.Boundaries.can?(pinner, @boundary_verb, object) do
      do_pin(scope || pinner, object, opts)
    else
      error(l("Sorry, you cannot pin this"))
    end
  end

  def pin(pinner, object, scope, opts) when is_binary(object) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(object,
             current_user: pinner,
             verbs: [@boundary_verb],
             skip_boundary_check: opts[:skip_boundary_check]
           ) do
      do_pin(scope || pinner, object, opts)
    else
      _ ->
        error(l("Sorry, you cannot pin this"))
    end
  end

  defp do_pin(pinner, %{} = pinned, opts \\ []) do
    skip_federation? = skip_federation?(pinned)

    object_creator =
      opts[:object_creator] ||
        (
          pinned = Objects.preload_creator(pinned)
          Objects.object_creator(pinned)
        )

    opts = [
      # TODO: make configurable
      boundary: "mentions",
      to_circles: [uid(object_creator)],
      # category pins are private sidebar markers — don't notify the group creator
      to_feeds:
        opts[:to_feeds] ||
          if(skip_federation?,
            do: [],
            else: Feeds.maybe_creator_notification(pinner, object_creator, opts)
          )
    ]

    case create(pinner, pinned, opts) do
      {:ok, pin} when skip_federation? ->
        {:ok, pin}

      {:ok, pin} ->
        # preload pinner + object `:peered` for federation's locality check
        Social.maybe_federate_and_gift_wrap_activity(
          repo().maybe_preload(pinner, character: [:peered]),
          repo().maybe_preload(pin,
            edge: [object: [:peered, created: [creator: [character: [:peered]]]]]
          )
        )

      {:error, e} ->
        case get(pinner, pinned) do
          {:ok, pin} ->
            debug(pin, "the user already pinned this object")
            {:ok, pin}

          _ ->
            error(e)
            {:error, e}
        end
    end
  rescue
    e in Ecto.ConstraintError ->
      case get(pinner, pinned) do
        {:ok, pin} ->
          debug(pin, "the user already pinned this object")
          {:ok, pin}

        _ ->
          error(e)
      end
  end

  @doc """
  Removes a pin for an object.

  ## Parameters

    - user: The user removing the pin.
    - object: The object to be unpinned.
    - scope: The scope of the pin (eg. `:instance`, optional).

  ## Examples

      iex> Bonfire.Social.Pins.unpin(%User{id: "user123"}, %Post{id: "post456"})
      {:ok, nil}

      iex> Bonfire.Social.Pins.unpin(%User{id: "user123"}, %Post{id: "post456"}, :instance)
      {:ok, nil}

  """
  def unpin(user, object, scope \\ nil)

  def unpin(user, object, :instance) do
    if Bonfire.Boundaries.can?(user, :mediate, :instance) do
      unpin(instance_scope(), object, nil)
    else
      error(l("Sorry, you cannot pin to the instance"))
    end
  end

  def unpin(subject, %{} = pinned, scope) do
    scope = scope || subject

    # federate a `Remove` from the owner's `featured` collection *before* deleting locally — the
    # Remove activity is built synchronously from the pin, so the pin row is safe to delete
    # afterwards. We force the Pins federation module and use `:remove` (not `:delete`, which
    # `Outgoing` intercepts into a generic object-`Delete` instead of a collection `Remove`).
    # category pins never federate, so skip the `Remove`
    with false <- skip_federation?(pinned),
         {:ok, pin} <- get(scope, pinned) do
      # federate as the pinner (like `do_pin`), not `scope` which may be a bare container id (not a
      # valid AP actor); preload actor + object `:peered` for the locality check
      Social.maybe_federate(
        repo().maybe_preload(subject, character: [:peered]),
        :remove,
        repo().maybe_preload(pin,
          edge: [object: [:peered, created: [creator: [character: [:peered]]]]]
        ),
        nil,
        federation_module: __MODULE__
      )
    end

    # delete the Pin
    Edges.delete_by_both(scope, Pin, pinned)
    # delete the pin activity & feed entries
    Activities.delete_by_subject_verb_object(scope, :pin, pinned)

    # Note: the pin count is automatically decremented by DB triggers
  end

  def unpin(subject, pinned, scope) when is_binary(pinned) do
    # removing a pin doesn't need a read-boundary check on the object, and `subject` may be the
    # instance scope (a circle id, not a real user) which would otherwise fail the load.
    with {:ok, pinned} <-
           Bonfire.Common.Needles.get(pinned, current_user: subject, skip_boundary_check: true) do
      unpin(subject, pinned, scope)
    end
  end

  @doc """
  Sets the rank/position of a pinned thing within a scope (idempotent upsert).

  `item` is the id you want to order and MUST match what the reader joins on — the groups sidebar
  ranks by the pinned OBJECT id (`Pins.instance_pinned_object_ids/0` joins `Ranked.item_id ==
  edge.object_id`), so pass the object id, not the Pin edge id.
  """
  def rank_pin(pin, :instance, position) do
    rank_pin(pin, instance_scope(), position)
  end

  def rank_pin(pin, scope, position) do
    scope_id = uid(scope)
    alias Bonfire.Data.Assort.Ranked

    # Ordering is keyed by `scope_id` (here the instance circle, or a user) with `rank_type_id` left
    # nil — the same convention `bonfire_poll` uses (it scopes by the question id). Distinct scope_ids
    # never share an ordering, so sidebar-pin order can't collide with other ranked features.
    #
    # Upsert: update the existing rank for this (item, scope) if present, else insert. Matching the
    # `[item_id, scope_id, rank_type_id]` unique index exactly needs an explicit `is_nil` (a keyword
    # `get_by(rank_type_id: nil)` would emit `= NULL`, which matches nothing). The old "poor man's
    # upsert" re-`update`d a pkey-less changeset on conflict → NoPrimaryKeyValueError.
    existing =
      repo().one(
        from(r in Ranked,
          where: r.item_id == ^pin and r.scope_id == ^scope_id and is_nil(r.rank_type_id)
        )
      )

    case existing do
      nil ->
        Ranked.changeset(%{item_id: pin, scope_id: scope_id, rank_set: position})
        |> repo().insert()

      existing ->
        Ranked.changeset(existing, %{rank_set: position}) |> repo().update()
    end
  end

  defp query_base(filters, opts) do
    Edges.query_parent(Pin, filters, opts)

    # |> proload(edge: [
    #   # subject: {"pinner_", [:profile, :character]},
    #   # object: {"pinned_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
  end

  def query([my: :pins], opts),
    do: query([subjects: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp list_paginated(filters, opts) do
    query(filters, opts)
    |> repo().many_maybe_paginated(opts[:paginate?], opts)

    # |> Activities.query_object_preload_activity(:pin, :pinned_id, opts)
    # |> Activities.as_permitted_for(opts, [:see])
    # |> debug()
    # |> repo().many_paginated(opts)
    # |> maybe_load_pointer(opts[:load_pointer])
  end

  defp maybe_load_pointer(data, true),
    do: repo().maybe_preload(data, [edge: [:object]], skip_boundary_check: true)

  defp maybe_load_pointer(data, _), do: data

  @doc """
  Lists pins for the current user.

  ## Parameters

    - opts: Additional options for the query.

  ## Examples

      iex> Bonfire.Social.Pins.list_my(current_user: %User{id: "user123"})
      %{edges: [%Pin{}, ...], page_info: %{}}

  """
  def list_my(opts) do
    list_by(current_user_required!(opts), opts)
  end

  @doc """
  Lists pins for the instance.

  ## Parameters

    - opts: Additional options for the query.

  ## Examples

      iex> Bonfire.Social.Pins.list_instance_pins(limit: 10)
      %{edges: [%Pin{}, ...], page_info: %{}}

  """
  def list_instance_pins(opts) when is_list(opts) do
    opts = to_options(opts)

    list_by(
      instance_scope(),
      Keyword.put(opts, :preload, [:object_with_creator, :object_post_content])
    )
  end

  @doc """
  Lists the original activities for instance-pinned objects.

  Returns full activity structs (with preloaded subject, object, etc.) suitable
  for rendering with `ActivityLive`, rather than pin edge structs.

  ## Examples

      iex> Bonfire.Social.Pins.list_instance_pins_activities(current_user: %User{})
      %{edges: [%Activity{}, ...], page_info: %{}}

  """
  def list_instance_pins_activities(opts) when is_list(opts) do
    opts = to_options(opts)

    object_ids =
      from(p in Pin,
        join: e in Bonfire.Data.Edges.Edge,
        on: e.id == p.id,
        where: e.subject_id in ^List.wrap(instance_scope()),
        select: e.object_id
      )
      |> repo().many()

    case object_ids do
      [] ->
        %{edges: [], page_info: %{}}

      ids ->
        create_verb_id = Activities.verb_id(:create)

        # Plain query on Activity, then postload associations on the results
        # (read_query is designed for object-base queries, not Activity-base)
        limit = opts[:limit] || 5

        from(a in Bonfire.Data.Social.Activity,
          where: a.object_id in ^ids,
          where: a.verb_id == ^create_verb_id,
          order_by: [desc: a.id],
          limit: ^limit
        )
        |> repo().many()
        |> Activities.activity_preloads(
          [:default, :with_object_more, :with_subject, :with_media],
          opts ++ [skip_boundary_check: true]
        )
        |> List.wrap()
        |> Enum.map(&%{activity: &1})
        |> then(&%{edges: &1, page_info: %{}})
    end
  end

  @doc """
  Lists pins by a specific user.

  ## Parameters

    - by_user: The user whose pins to list.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Pins.list_by(%User{id: "user123"})
      %{edges: [%Pin{}, ...], page_info: %{}}

  """
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts)
      |> Map.put(:subjects, by_user),
      opts
      |> Keyword.put_new(:preload, :object)
      |> Keyword.put(:subject_user, :by_user)
    )

    # list_paginated(
    #   Edges.filters_from_opts(opts) |> Map.put(:subjects, by_user),
    #   opts ++ [preload: [object: [created: [creator: [:profile, :character]]]]]
    # )

    # edges =
    #   for %{edge: %{} = edge} <- e(feed, :edges, []),
    #       do: edge |> Map.put(:verb, %{verb: "Pin"})

    # %{page_info: e(feed, :page_info, []), edges: edges}
  end

  @doc """
  Lists pinners of a specific object or objects.

  ## Parameters

    - object: The object or objects to find pinners for.
    - opts: Additional options for the query (optional).

  ## Examples

      iex> Bonfire.Social.Pins.list_of(%Post{id: "post456"})
      %{edges: [%Pin{}, ...], page_info: %{}}

  """
  def list_of(object, opts \\ [])
      when is_binary(object) or is_list(object) or is_map(object) do
    opts = to_options(opts)

    list_paginated(
      Edges.filters_from_opts(opts) |> Map.put(:objects, object),
      opts ++ [preload: :subject]
    )
  end

  defp create(pinner, pinned, opts) do
    Edges.insert(Pin, pinner, :pin, pinned, opts)
  end

  # def ap_publish_activity(subject, :delete, pin) do
  #   with {:ok, pinner} <-
  #          ActivityPub.Actor.get_cached(pointer: subject || pin.edge.subject_id),
  #        {:ok, object} <-
  #  ActivityPub.Object.get_cached(pointer: e(pin.edge, :object, nil)) do
  #     ActivityPub.unlike(%{actor: pinner, object: object})
  #   end
  # end

  # MLS-over-AP / Mastodon `featured`: this module owns the `featured` collection type. The generic
  # adapter routes `collection_items`/`collection_total` here by type (see
  # `Bonfire.Federate.ActivityPub.Adapter`). We return the owner's pinned objects' **pointer ids**;
  # the AP lib resolves ids → ap_ids/objects when serving (so no per-item lookups here).

  @doc "Member refs (pointer ids) of a user's `featured` collection — their pinned objects. Supports `limit:`/`offset:`."
  def collection_items(collection, opts \\ []) do
    pinned_object_ids(collection, opts) || []
  end

  @doc "`totalItems` for a `featured` collection."
  def collection_total(collection, _opts \\ []) do
    case featured_pins_subject(collection) do
      subject when is_binary(subject) -> pins_query(subject) |> repo().aggregate(:count)
      _ -> nil
    end
  end

  defp pinned_object_ids(collection, opts) do
    case featured_pins_subject(collection) do
      subject when is_binary(subject) ->
        pins_query(subject)
        |> select([_p, e], e.object_id)
        |> order_by([_p, e], desc: e.id)
        |> maybe_limit(opts[:limit])
        |> maybe_offset(opts[:offset])
        |> repo().many()

      _ ->
        nil
    end
  end

  # the `featured` collection id encodes the owner actor's id as its uuid → the pins subject.
  # The service/Application actor's featured maps to instance-wide pins (subject = instance scope).
  defp featured_pins_subject(collection) do
    with %{data: %{"id" => id}} <- collection,
         {:ok, "featured", uuid} <- ActivityPub.Utils.parse_collection_ap_id(id) do
      case ActivityPub.Utils.service_actor() do
        {:ok, %{id: ^uuid}} -> instance_scope()
        _ -> uuid
      end
    else
      _ -> nil
    end
  end

  defp pins_query(uuid) do
    from(p in Pin,
      join: e in Bonfire.Data.Edges.Edge,
      on: e.id == p.id,
      where: e.subject_id == ^uuid
    )
  end

  defp maybe_limit(query, limit) when is_integer(limit), do: limit(query, ^limit)
  defp maybe_limit(query, _), do: query
  defp maybe_offset(query, offset) when is_integer(offset), do: offset(query, ^offset)
  defp maybe_offset(query, _), do: query

  @doc """
  Publishes an ActivityPub activity for a pin: an `Add` (pin) or `Remove` (unpin) against the
  pinner's `featured` collection (MLS-over-AP / Mastodon featured).

  ## Examples

      iex> Bonfire.Social.Pins.ap_publish_activity(%User{id: "user123"}, :create, %Pin{})
      {:ok, %ActivityPub.Object{}}
  """
  def ap_publish_activity(subject, verb, pin) do
    # user pins federate on the user's `featured`; instance-wide pins (subject = instance scope) on
    # the instance's service/Application actor's `featured`
    with {:ok, pinner} <- pin_federating_actor(subject || pin.edge.subject_id) do
      # preload locality at the binding so `canonical_url` classifies without an on-demand raise
      # (pinned objects vary — superset pruned per schema; no-op when we only have the id)
      object =
        (e(pin.edge, :object, nil) || pin.edge.object_id)
        |> repo().maybe_preload([character: [:peered], created: [:peered]], prune: true)

      object_ap_id = Bonfire.Common.URIs.canonical_url(object)

      target = ActivityPub.Utils.collection_ap_id("featured", uid(pinner))
      remove? = verb in [:remove, :delete, :undo, :unpin]

      params = %{
        actor: pinner,
        object: object_ap_id,
        target: target,
        # only the Add (pin creation) is anchored to the Pin's pointer; a Remove (unpin) isn't a
        # persistent object and must not reuse the pin's pointer (unique `ap_object.pointer_id`)
        pointer: if(remove?, do: nil, else: uid(pin)),
        local: true
      }

      if remove?, do: ActivityPub.remove(params), else: ActivityPub.add(params)
    end
  end

  defp pin_federating_actor(subject_id) do
    if subject_id == instance_scope(),
      do: ActivityPub.Utils.service_actor(),
      else: ActivityPub.Actor.get_cached(pointer: subject_id)
  end

  @doc """
  Receives an incoming `Add`/`Remove` to an actor's `featured` collection (MLS-over-AP / Mastodon
  featured) and reflects it as a (remote-originated) pin/unpin by that actor. Routed here by
  `incoming.ex` via the `{activity_type, "featured"}` federation_module key. `local: false` so it is
  not re-federated.
  """
  def ap_receive_activity(creator, %{data: %{"type" => type}}, object)
      when type in ["Add", "Remove"] do
    with object_id when is_binary(object_id) <-
           e(object, :pointer_id, nil) || e(object, :pointer, :id, nil),
         {:ok, pinned} <-
           Bonfire.Common.Needles.get(object_id, current_user: creator, skip_boundary_check: true) do
      if type == "Add",
        do: pin(creator, pinned, nil, local: false),
        else: unpin(creator, pinned)
    end
  end

  # def ap_receive_activity(
  #       creator,
  #       %{data: %{"type" => "Pin"}} = _activity,
  #       object
  #     ) do
  #   with {:ok, pinned} <-
  #          Bonfire.Common.Needles.get(object.pointer_id, current_user: creator) do
  #     pin(creator, pinned, local: false)
  #   end
  # end

  # def ap_receive_activity(
  #       creator,
  #       %{data: %{"type" => "Undo"}} = _activity,
  #       %{data: %{"object" => pinned_object}} = _object
  #     ) do
  #   with {:ok, object} <-
  #          ActivityPub.Object.get_cached(ap_id: pinned_object),
  #        {:ok, pinned} <-
  #          Bonfire.Common.Needles.get(object.pointer_id, current_user: creator),
  #        [id] <- unpin(creator, pinned) do
  #     {:ok, id}
  #   end
  # end
end
