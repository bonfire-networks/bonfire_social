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
    if opts[:skip_boundary_check] || Bonfire.Boundaries.can?(pinner, @boundary_verb, object) do
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
    object_creator =
      (opts[:object_creator] ||
         (
           pinned =
             Objects.preload_creator(pinned)
             |> debug("pinned object")

           Objects.object_creator(pinned)
         ))
      |> debug("the creator")

    opts = [
      # TODO: make configurable
      boundary: "mentions",
      to_circles: [uid(object_creator)],
      to_feeds: opts[:to_feeds] || Feeds.maybe_creator_notification(pinner, object_creator, opts)
    ]

    case create(pinner, pinned, opts) do
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
    with {:ok, pin} <- get(scope, pinned) do
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
    with {:ok, pinned} <- Bonfire.Common.Needles.get(pinned, current_user: subject) do
      unpin(subject, pinned, scope)
    end
  end

  @doc """
  Sets the rank/position of a pin within a specific scope.

  ## Parameters

    - pin: The pin to be ranked.
    - scope: The scope for ranking (eg. `:instance`).
    - position: The desired position/rank for the pin.

  ## Examples

      iex> Bonfire.Social.Pins.rank_pin("pin123", :instance, 1)
      {:ok, %Bonfire.Data.Assort.Ranked{}}

      iex> Bonfire.Social.Pins.rank_pin("pin123", %User{id: "user456"}, 2)
      {:ok, %Bonfire.Data.Assort.Ranked{}}

  """
  def rank_pin(pin, :instance, position) do
    rank_pin(pin, instance_scope(), position)
  end

  def rank_pin(pin, scope, position) do
    with {:ok, %Ecto.Changeset{valid?: true} = cs} <-
           Bonfire.Data.Assort.Ranked.changeset(%{
             item_id: pin,
             scope_id: uid(scope),
             rank_set: position
           })
           |> Ecto.Changeset.unique_constraint([:item_id, :scope_id],
             name: :bonfire_data_ranked_unique_per_scope
           )
           |> dump(),
         {:ok, ins} <- repo().insert(cs) do
      {:ok, ins}
    else
      # poor man's upsert - TODO fix drag and drop ordering and make better and generic
      {:error, %Ecto.Changeset{} = cs} ->
        repo().update(cs, [:rank])

      %Ecto.Changeset{} = cs ->
        repo().upsert(cs, [:rank])

      e ->
        error(e)
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
      object_ap_id =
        Bonfire.Common.URIs.canonical_url(e(pin.edge, :object, nil) || pin.edge.object_id)

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
