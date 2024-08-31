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

  # import Ecto.Query
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
    do: ["Pin", {"Create", "Pin"}, {"Undo", "Pin"}, {"Delete", "Pin"}]

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
      (opts ++ [subject: subject])
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
    do: (opts ++ [object: object]) |> query(opts) |> repo().many()

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
    if Bonfire.Boundaries.can?(pinner, :pin, :instance) do
      pin(instance_scope(), object, pinner, opts ++ [skip_boundary_check: true])
    else
      error(l("Sorry, you cannot pin to the instance"))
    end
  end

  def pin(pinner, %{} = object, scope, opts) do
    if Bonfire.Boundaries.can?(pinner, @boundary_verb, object) do
      do_pin(scope || pinner, object, opts)
    else
      error(l("Sorry, you cannot pin this"))
    end
  end

  def pin(pinner, object, scope, opts) when is_binary(object) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(object,
             current_user: pinner,
             verbs: [@boundary_verb]
           ) do
      # debug(object)
      do_pin(scope || pinner, object, opts)
    else
      _ ->
        error(l("Sorry, you cannot pin this"))
    end
  end

  defp do_pin(pinner, %{} = pinned, opts \\ []) do
    pinned = Objects.preload_creator(pinned)
    pinned_creator = Objects.object_creator(pinned)

    opts = [
      # TODO: make configurable
      boundary: "mentions",
      to_circles: [ulid(pinned_creator)],
      to_feeds: Feeds.maybe_creator_notification(pinner, pinned_creator, opts)
    ]

    case create(pinner, pinned, opts) do
      {:ok, pin} ->
        Social.maybe_federate_and_gift_wrap_activity(pinner, pin)

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
    if Bonfire.Boundaries.can?(user, :pin, :instance) do
      unpin(instance_scope(), object, user)
    else
      error(l("Sorry, you cannot pin to the instance"))
    end
  end

  def unpin(subject, %{} = pinned, _) do
    # delete the Pin
    Edges.delete_by_both(subject, Pin, pinned)
    # delete the pin activity & feed entries
    Activities.delete_by_subject_verb_object(subject, :pin, pinned)

    # Note: the pin count is automatically decremented by DB triggers
  end

  def unpin(subject, pinned, user) when is_binary(pinned) do
    with {:ok, pinned} <- Bonfire.Common.Needles.get(pinned, current_user: user || subject) do
      unpin(subject, pinned)
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
             scope_id: ulid(scope),
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
    do: query([subject: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp list_paginated(filters, opts) do
    query(filters, opts)
    |> Social.many(opts[:paginate?], opts)

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
    list_by(instance_scope(), Keyword.put(opts, :preload, :object_with_creator))
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
      |> Map.put(:subject, by_user),
      opts
      |> Keyword.put_new(:preload, :object)
      |> Keyword.put(:subject_user, :by_user)
    )

    # list_paginated(
    #   Edges.filters_from_opts(opts) |> Map.put(:subject, by_user),
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
      Edges.filters_from_opts(opts) |> Map.put(:object, object),
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

  @doc """
  Publishes an ActivityPub activity for a pin.

  ## Parameters

    - subject: The subject of the pin activity.
    - verb: The verb of the activity (not used - currently pins are federated out as likes)
    - pin: The `Pin` object.

  ## Examples

      iex> Bonfire.Social.Pins.ap_publish_activity(%User{id: "user123"}, :create, %Pin{})
      {:ok, %ActivityPub.Object{}}

  """
  def ap_publish_activity(subject, _verb, pin) do
    # info(pin)

    with {:ok, pinner} <-
           ActivityPub.Actor.get_cached(pointer: subject || pin.edge.subject_id),
         {:ok, object} <-
           ActivityPub.Object.get_cached(pointer: e(pin.edge, :object, nil) || pin.edge.object_id) do
      ActivityPub.like(%{actor: pinner, object: object, pointer: ulid(pin)})
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
