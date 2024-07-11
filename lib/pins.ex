defmodule Bonfire.Social.Pins do
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

  def pinned?(:instance, object),
    do: Edges.exists?(__MODULE__, instance_scope(), object, skip_boundary_check: true)

  def pinned?(scope, object),
    do: Edges.exists?(__MODULE__, scope, object, skip_boundary_check: true)

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  def by_pinner(%{} = subject, opts \\ []),
    do:
      (opts ++ [subject: subject])
      |> query([current_user: subject] ++ List.wrap(opts))
      |> repo().many()

  def by_pinned(%{} = object, opts \\ []),
    do: (opts ++ [object: object]) |> query(opts) |> repo().many()

  def pin(pinner, object, scope \\ nil, opts \\ [])

  def pin(pinner, object, :instance, opts) do
    if Bonfire.Boundaries.can?(pinner, :pin, :instance) do
      pin(instance_scope(), object, pinner, opts)
    else
      error(l("Sorry, you cannot pin to the instance"))
    end
  end

  def pin(pinner, %{} = object, user, opts) do
    if Bonfire.Boundaries.can?(user || pinner, @boundary_verb, object) do
      do_pin(pinner, object, opts)
    else
      error(l("Sorry, you cannot pin this"))
    end
  end

  def pin(pinner, pinned, user, opts) when is_binary(pinned) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(pinned,
             current_user: user || pinner,
             verbs: [@boundary_verb]
           ) do
      # debug(pinned)
      do_pin(pinner, object, opts)
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

  @doc "List the current user's pins"
  def list_my(opts) do
    list_by(current_user_required!(opts), opts)
  end

  def list_instance_pins(opts) when is_list(opts) do
    opts = to_options(opts)
    list_by(instance_scope(), Keyword.put(opts, :preload, :object_with_creator))
  end

  @doc "List pins by a user"
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

  @doc "List pinners of something(s)"
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

  def ap_publish_activity(subject, _verb, pin) do
    info(pin)

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
