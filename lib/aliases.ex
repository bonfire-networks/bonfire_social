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
    do: Edges.exists?(__MODULE__, subject, target, verbs: [:add], skip_boundary_check: true)

  @doc """
  Alias someone/something. 
  """
  def add(user, target, opts \\ [])

  def add(%{} = user, target, opts) do
    with {:ok, result} <- do_add(user, target, opts) do
      # debug(result, "add or request result")
      {:ok, result}
    end
  end

  # Notes for future refactor:
  # * Make it pay attention to options passed in
  # * When we start allowing to add things that aren't users, we might need to adjust the circles.
  # * Figure out how to avoid the advance lookup and ensuing race condition.
  defp do_add(%user_struct{} = user, %object_struct{} = target, opts) do
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

  def query([my: :target], opts),
    do: query([subject: current_user_required!(opts)], opts)

  def query([my: :aliases], opts),
    do: query([target: current_user_required!(opts)], opts)

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
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :target]

    [subject: ulid(user), object_type: opts[:type]]
    |> query(opts)
    |> where([target: target], target.id not in ^e(opts, :exclude_ids, []))
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

    [target: ulid(user), subject_type: opts[:type]]
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

  # def ap_publish_activity(subject, verb, add) do
  #   add = repo().maybe_preload(add, :edge)

  #   with {:ok, actor} <-
  #          ActivityPub.Actor.get_cached(
  #            pointer:
  #              subject || e(add, :edge, :subject, nil) || e(add, :edge, :subject_id, nil)
  #          )
  #          |> debug("aliasing actor"),
  #        {:ok, target} <-
  #          ActivityPub.Actor.get_cached(
  #            pointer: e(add.edge, :target, nil) || e(add, :edge, :object_id, nil)
  #          )
  #          |> debug("aliased actor") do
  #     ActivityPub.move(actor, target)
  #   else
  #     e ->
  #       error(e, "Could not federate")
  #       raise "Could not federate the add"
  #   end
  # end

  def ap_receive_activity(
        user,
        %{data: %{"type" => "Move"} = data} = _activity,
        target
      ) do
    info(data, "Follows: attempt to process an incoming move activity...")

    debug(target, "user")
    debug(target, "user")

    error("TODO")
    {:ok, "TODO"}

    # __MODULE__
    # |> join(:inner, [r], f in assoc(r, :user))
    # |> where(following_id: ^origin.id)
    # |> where([r, f], f.allow_following_move == true)
    # |> where([r, f], f.local == true)
    # |> limit(50)
    # |> preload([:user])
    # |> Repo.all()
    # |> Enum.map(fn following_relationship ->
    #   add(following_relationship.user, target)
    #   remove(following_relationship.user, origin)
    # end)
    # |> case do
    #   [] ->
    #     User.update_user_count(origin)
    #     :ok

    #   _ ->
    #     move_following(origin, target)
    # end
  end
end
