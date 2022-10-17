defmodule Bonfire.Social.Pins do
  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Pin
  # alias Bonfire.Data.Social.PinCount
  alias Bonfire.Boundaries.Verbs

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Integration
  alias Bonfire.Social.Objects

  alias Bonfire.Social.Edges
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds

  # import Ecto.Query
  alias Bonfire.Social.Integration
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  # TODO: check for :pin boundary verb instead?
  @boundary_verb :boost

  def queries_module, do: Pin
  def context_module, do: Pin

  def federation_module,
    do: ["Pin", {"Create", "Pin"}, {"Undo", "Pin"}, {"Delete", "Pin"}]

  defp instance_scope,
    do: Bonfire.Boundaries.Circles.get_id(:local) || "3SERSFR0MY0VR10CA11NSTANCE"

  def pinned?(:instance, object),
    do: not is_nil(get!(instance_scope(), object, skip_boundary_check: true))

  def pinned?(user, object),
    do: not is_nil(get!(user, object, skip_boundary_check: true))

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  def by_pinner(%{} = subject, opts \\ []),
    do: (opts ++ [subject: subject]) |> query([current_user: subject] ++ opts) |> repo().many()

  def by_pinned(%{} = object, opts \\ []),
    do: (opts ++ [object: object]) |> query(opts) |> repo().many()

  def pin(pinner, object, scope \\ nil)

  def pin(pinner, %{} = object, :instance) do
    if Integration.is_admin?(pinner) or Bonfire.Boundaries.can?(pinner, :pin, :instance) do
      do_pin(instance_scope(), object)
    else
      error(l("Sorry, you cannot pin to the instance"))
    end
  end

  def pin(%{} = pinner, %{} = object, _) do
    if Bonfire.Boundaries.can?(pinner, @boundary_verb, object) do
      do_pin(pinner, object)
    else
      error(l("Sorry, you cannot pin this"))
    end
  end

  def pin(%{} = pinner, pinned, _) when is_binary(pinned) do
    with {:ok, object} <-
           Bonfire.Common.Pointers.get(pinned,
             current_user: pinner,
             verbs: [@boundary_verb]
           ) do
      # debug(pinned)
      do_pin(pinner, object)
    else
      _ ->
        error(l("Sorry, you cannot pin this"))
    end
  end

  defp do_pin(pinner, %{} = pinned) do
    pinned = Objects.preload_creator(pinned)
    pinned_creator = Objects.object_creator(pinned)

    opts = [
      # TODO: make configurable
      boundary: "mentions",
      to_circles: [ulid(pinned_creator)],
      to_feeds: Feeds.maybe_creator_notification(pinner, pinned_creator)
    ]

    case create(pinner, pinned, opts) do
      {:ok, pin} ->
        Integration.ap_push_activity(ulid(pinner), pin)
        {:ok, pin}

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
    if Integration.is_admin?(user) or Bonfire.Boundaries.can?(user, :pin, :instance) do
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
    with {:ok, pinned} <- Bonfire.Common.Pointers.get(pinned, current_user: user || subject) do
      unpin(subject, pinned)
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
    do: query([subject: current_user_required(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  defp list_paginated(filters, opts \\ []) do
    query(filters, opts)
    # |> Activities.query_object_preload_activity(:pin, :pinned_id, opts)
    # |> Activities.as_permitted_for(opts, [:see])
    # |> debug()
    |> Bonfire.Common.Repo.many_paginated(opts)
  end

  @doc "List the current user's pins"
  def list_my(opts) when is_list(opts) do
    list_by(current_user_required(opts), opts)
  end

  def list_instance_pins(opts) when is_list(opts) do
    list_by(instance_scope(), opts)
  end

  @doc "List pins by a user"
  def list_by(by_user, opts \\ [])
      when is_binary(by_user) or is_list(by_user) or is_map(by_user) do
    opts = to_options(opts)
    list_paginated(opts ++ [subject: by_user], opts ++ [preload: :object])
  end

  @doc "List pinners of something(s)"
  def list_of(object, opts \\ [])
      when is_binary(object) or is_list(object) or is_map(object) do
    opts = to_options(opts)
    list_paginated(opts ++ [object: object], opts ++ [preload: :subject])
  end

  defp create(pinner, pinned, opts) do
    Edges.changeset(Pin, pinner, :pin, pinned, opts)
    |> Changeset.unique_constraint([:subject_id, :object_id, :table_id])
    |> repo().insert()

    # |> repo().maybe_preload(edge: [:object])
  end

  def ap_publish_activity("create", pin) do
    info(pin)

    with {:ok, pinner} <-
           ActivityPub.Actor.get_cached_by_local_id(pin.edge.subject_id),
         object when not is_nil(object) <-
           Bonfire.Federate.ActivityPub.Utils.get_object(pin.edge.object) do
      ActivityPub.like(pinner, object)
    end
  end

  # def ap_publish_activity("delete", pin) do
  #   with {:ok, pinner} <-
  #          ActivityPub.Actor.get_cached_by_local_id(pin.edge.subject_id),
  #        object when not is_nil(object) <-
  #          Bonfire.Federate.ActivityPub.Utils.get_object(pin.edge.object) do
  #     ActivityPub.unlike(pinner, object)
  #   end
  # end

  # def ap_receive_activity(
  #       creator,
  #       %{data: %{"type" => "Pin"}} = _activity,
  #       object
  #     ) do
  #   with {:ok, pinned} <-
  #          Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator) do
  #     pin(creator, pinned)
  #   end
  # end

  # def ap_receive_activity(
  #       creator,
  #       %{data: %{"type" => "Undo"}} = _activity,
  #       %{data: %{"object" => pinned_object}} = _object
  #     ) do
  #   with object when not is_nil(object) <-
  #          ActivityPub.Object.get_cached_by_ap_id(pinned_object),
  #        {:ok, pinned} <-
  #          Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator),
  #        [id] <- unpin(creator, pinned) do
  #     {:ok, id}
  #   end
  # end
end
