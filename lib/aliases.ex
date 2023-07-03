defmodule Bonfire.Social.Aliases do
  alias Bonfire.Data.Identity.Alias

  # alias Bonfire.Me.Boundaries
  alias Bonfire.Me.Characters
  alias Bonfire.Me.Users

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social.Integration
  alias Bonfire.Social.Follows

  alias Bonfire.Social.LivePush
  # alias Bonfire.Data.Identity.User
  # alias Ecto.Changeset
  # alias Pointers.Changesets
  import Bonfire.Boundaries.Queries
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Alias

  def federation_module,
    do: [
      "Move"
    ]

  # TODO: privacy
  def exists?(subject, target),
    # current_user: subject)
    do: Edges.exists?(__MODULE__, subject, target, skip_boundary_check: true)

  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  @doc """
  Alias someone/something. 
  """
  def add(user, target, opts \\ [])

  def add(%{} = user, %{} = target, opts) do
    with {:ok, result} <- do_add(user, target, opts) do
      # debug(result, "add or request result")
      {:ok, result}
    end
  end

  def add(%{} = user, target, opts) do
    with {:ok, target} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(target) do
      add(user, target, opts)
    end
  end

  # Notes for future refactor:
  # * Make it pay attention to options passed in
  # * When we start allowing to add things that aren't users, we might need to adjust the circles.
  # * Figure out how to avoid the advance lookup and ensuing race condition.
  defp do_add(%user_struct{} = user, %{} = target, opts) do
    repo().transact_with(fn ->
      case create(user, target, opts) do
        {:ok, add} ->
          # if info(opts[:incoming] != true, "Maybe outgoing add?"),
          #   do: Integration.maybe_federate_and_gift_wrap_activity(user, add),
          #   else: 
          {:ok, add}

        e ->
          error(e)
      end
    end)
  rescue
    e in Ecto.ConstraintError ->
      error(e)
      get(user, target, skip_boundary_check: true)
  end

  def remove(user, %{} = target) do
    if exists?(user, target) do
      Edges.delete_by_both(user, Alias, target)

      # TODO: update AP user?
      # Integration.maybe_federate(user, :remove, target)
      # ap_publish_activity(user, :update, target)
    else
      error("Does not exist")
    end
  end

  def remove(%{} = user, target) when is_binary(target) do
    with {:ok, target} <-
           Bonfire.Common.Pointers.get(target,
             current_user: user,
             skip_boundary_check: true
           ) do
      remove(user, target)
    end
  end

  # TODO: abstract the next few functions into Edges
  def all_by_subject(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :target)
    |> query([subject: user], ...)
    |> repo().many()
  end

  def all_objects_by_subject(user, opts \\ []) do
    all_by_subject(user, opts)
    |> Enum.map(&e(&1, :edge, :target, nil))
  end

  def all_by_object(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :subject)
    |> query([target: user], ...)
    |> repo().many()
  end

  def all_subjects_by_object(user, opts \\ []) do
    all_by_object(user, opts)
    |> Enum.map(&e(&1, :edge, :subject, nil))
  end

  defp query_base(filters, opts) do
    filters = e(opts, :filters, []) ++ filters

    Edges.query_parent(Alias, filters, opts)
    |> query_filter(Keyword.drop(filters, [:target, :subject]))

    # |> debug("follows query")
  end

  def query(filters, opts) do
    query_base(filters, opts)
  end

  def list_my_aliases(current_user, opts \\ []),
    do:
      list_aliases(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  def list_aliases(user, opts \\ []) do
    # TODO: configurable boundaries for follows
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :object]

    [subject: ulid(user), object_type: opts[:type]]
    |> query(opts)
    |> where([object: object], object.id not in ^e(opts, :exclude_ids, []))
    |> Integration.many(opts[:paginate], opts)
  end

  def list_my_aliased(current_user, opts \\ []),
    do:
      list_aliased(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  def list_aliased(user, opts \\ []) do
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :subject]

    [object: ulid(user), subject_type: opts[:type]]
    |> query(opts)
    |> where([subject: subject], subject.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_user_profile_only(opts)
    |> Integration.many(opts[:paginate], opts)
  end

  # defp maybe_with_user_profile_only(q, true),
  #   do: where(q, [user_profile: p], not is_nil(p.id))

  # defp maybe_with_user_profile_only(q, _), do: q

  # def changeset(:create, subject, target, boundary) do
  #   Changesets.cast(%Alias{}, %{}, [])
  #   |> Edges.put_assoc(subject, target, :add, boundary)
  # end

  defp create(%{} = user, target, opts) do
    insert(user, target, opts)
  end

  def insert(subject, object, options) do
    Edges.changeset_base(Alias, subject, object, options)
    |> Edges.insert(subject, object)
  end

  ### ActivityPub integration

  def move(subject, %ActivityPub.Actor{} = target) do
    target = repo().maybe_preload(target, :edge)

    with {:ok, actor} <-
           ActivityPub.Actor.get_cached(pointer: subject)
           |> debug("from actor") do
      ActivityPub.move(actor, target)
    else
      e ->
        error(e, "Could not federate")
        raise "Could not federate the move"
    end
  end

  def move(subject, %Alias{} = target) do
    target = repo().maybe_preload(target, :edge)

    move(
      subject || e(target, :edge, :subject, nil) || e(target, :edge, :subject_id, nil),
      e(target.edge, :object, nil) || e(target, :edge, :object_id, nil)
    )
  end

  def move(subject, target) do
    with {:ok, target} <-
           ActivityPub.Actor.get_cached(pointer: target)
           |> debug("aliased actor") do
      move(subject, target)
    end
  end

  def ap_publish_activity(subject, :move, target) do
    move(subject, target)
  end

  def ap_receive_activity(
        subject,
        %{data: %{"type" => "Move", "target" => target} = data} = _activity,
        origin_object
      ) do
    info(data, "Follows: attempt to process an incoming Move activity...")

    debug(origin_object, "origin")
    debug(target, "target")

    with {:ok, origin_character} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.fetch_character_by_ap_id(origin_object),
         true <- id(origin_character) == id(subject),
         [:ok] <- move_following(origin_character, target) |> Enum.uniq() do
      {:ok, :moved}
    else
      result when is_list(result) ->
        if result
           |> debug("move_result")
           |> Enum.uniq() == [:error],
           do: {:error, :move_failed},
           else: {:ok, :moved_partially}

      false ->
        error("Invalid move activity, subject and object don't match")
    end
  end

  def move_following(origin, target) do
    Follows.all_subjects_by_object(origin)
    # |> repo().maybe_preload(character: :peered)
    # |> Enum.filter(&Integration.is_local?/1)
    |> Enum.map(fn third_party_subject ->
      with {:ok, _} <- Follows.follow(third_party_subject, target),
           {:ok, _} <- Follows.unfollow(third_party_subject, origin) do
        :ok
      else
        e ->
          error(e)
          :error
      end
    end)
  end
end
