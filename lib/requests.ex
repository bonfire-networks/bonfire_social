defmodule Bonfire.Social.Requests do
  @moduledoc """
  Handles social requests (e.g. follows requests), including creating, accepting, ignoring, and managing requests.
  """

  alias Bonfire.Data.Social.Request
  # alias Bonfire.Me.Boundaries
  # alias Bonfire.Me.Characters
  # alias Bonfire.Me.Users

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  # alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social

  # alias Bonfire.Data.Identity.User
  # alias Ecto.Changeset
  # import Bonfire.Boundaries.Queries
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Request
  def query_module, do: Request

  # @behaviour Bonfire.Federate.ActivityPub.FederationModules
  # def federation_module, do: ["Accept", "Reject"]

  @doc """
  Checks if a request has been made.

  ## Examples

      iex> requested?(subject, type, object)
      true
  """
  def requested?(subject, type, object),
    do: exists?(subject, type, object, skip_boundary_check: true)

  @doc """
  Requests to do something, and federates it.

  ## Examples

      iex> request(subject, Follow, object)
      {:ok, request}
  """
  def request(user, type, object, opts \\ [])

  def request(%{} = requester, type, object, opts) do
    opts = Keyword.put_new(opts, :current_user, requester)

    object
    # |> check_request(requester, ..., opts) # TODO: check if allowed to request?
    ~> do_request(requester, type, ..., opts)
  end

  def accept_and_delete(request, type_module, opts) do
    debug(opts, "opts")

    repo().transact_with(fn ->
      with {:ok, %{edge: %{object: object, subject: subject}} = request} <-
             accept(request, opts)
             |> repo().maybe_preload(edge: [:subject, :object])
             |> debug("accepted"),
           # remove the Edge (helps so we can recreate one linked to the Follow, because of the unique key on subject/object/table_id)
           _ <- Edges.delete_by_both(subject, type_module, object),
           # remove the Request Activity from notifications
           _ <-
             Activities.delete_by_subject_verb_object(subject, :request, object) do
        {:ok, request}
      else
        e ->
          error(e, l("An error occurred while accepting the request"))
      end
    end)
  end

  @doc """
  Accepts a request.

  ## Examples

      iex> accept(request, opts)
      {:ok, request}
  """
  def accept(request, opts) do
    with {:ok, request} <- requested(request, opts) do
      Request.changeset(request, %{accepted_at: DateTime.now!("Etc/UTC")})
      |> repo().update()
    end
  end

  @doc """
  Ignores a request.

  ## Examples

      iex> ignore(request, opts)
      {:ok, request}
  """
  def ignore(request, opts) do
    # TODO: should we just delete it instead?
    with {:ok, request} <- requested(request, opts) do
      Request.changeset(request, %{ignored_at: DateTime.now!("Etc/UTC")})
      |> repo().update()
    end
  end

  @doc """
  Retrieves a request.

  ## Examples

      iex> get(subject, Follow, object, opts)
      {:ok, request}
  """
  def get(subject, type, object, opts \\ []),
    do: Edges.get({__MODULE__, type}, subject, object, opts)

  def get!(subject, type, object, opts \\ []),
    do: Edges.get!({__MODULE__, type}, subject, object, opts)

  @doc """
  Retrieves a request by filters.

  ## Examples

      iex> get(filters, opts)
      {:ok, request}
  """
  def get(filters, opts \\ []), do: Edges.get(__MODULE__, filters, opts)

  @doc """
  Checks if a request exists.

  ## Examples

      iex> exists?(subject, Follow, object, opts)
      true
  """
  def exists?(subject, type, object, opts \\ []) do
    # Edges.exists?({__MODULE__, type}, subject, object, opts)

    Edges.edge_query({__MODULE__, type}, subject, object, Keyword.put(opts, :preload, false))
    |> where([r], is_nil(r.ignored_at))
    |> debug()
    |> repo().exists?()
  end

  @doc """
  Retrieves a request.

  ## Examples

      iex> requested(request, current_user: me)
      {:ok, request}
  """
  def requested(request, opts \\ [])
  def requested(%Request{id: _} = request, _opts), do: {:ok, request}

  def requested(request, opts),
    do: get([id: uid(request), objects: current_user(opts)], opts ++ [skip_boundary_check: true])

  # TODO: abstract the next few functions into Edges

  @doc """
  Retrieves all requests by subject.

  ## Examples

      iex> all_by_subject(user, type, opts)
      [{:ok, request}]
  """
  def all_by_subject(user, type, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :object)
    |> query([subjects: user], type, ...)
    |> repo().many()
  end

  @doc """
  Retrieves all request objects by subject.

  ## Examples

      iex> all_objects_by_subject(user, type, opts)
      [object]
  """
  def all_objects_by_subject(user, type, opts \\ []) do
    all_by_subject(user, type, opts)
    |> Enum.map(&e(&1, :edge, :object, nil))
  end

  @doc """
  Retrieves all requests by object.

  ## Examples

      iex> all_by_object(user, type, opts)
      [{:ok, request}]
  """
  def all_by_object(user, type, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :subject)
    |> query([objects: user], type, ...)
    |> repo().many()
  end

  @doc """
  Retrieves all subjects by object.

  ## Examples

      iex> all_subjects_by_object(user, type, opts)
      [subject]
  """
  def all_subjects_by_object(user, type, opts \\ []) do
    all_by_object(user, type, opts)
    |> Enum.map(&e(&1, :edge, :subject, nil))
  end

  @doc """
  Retrieves all requested outboxes by user and type.

  ## Examples

      iex> all_requested_outboxes(user, type, opts)
      [outbox_id]
  """
  def all_requested_outboxes(user, type, opts \\ []) do
    all_objects_by_subject(user, type, opts)
    |> Enum.map(&e(&1, :character, :outbox_id, nil))
  end

  # defp query_base(filters, opts) do
  #   vis = filter_invisible(current_user(opts))
  #   from(f in Request, join: v in subquery(vis), on: f.id == v.object_id)
  #   |> proload(:edge)
  #   |> query_filter(filters)
  # end

  defp query_base(filters, type \\ nil, opts)

  defp query_base(filters, type, opts)
       when is_atom(type) and not is_nil(type) do
    (filters ++ [activity_types: type])
    |> query_base(opts)
  end

  defp query_base(filters, _, opts) do
    Edges.query_parent(Request, filters, opts)
    |> query_filter(Keyword.drop(filters, [:objects, :subjects, :activity_types]))

    # |> proload(:request)
  end

  @doc """
  Prepares a DB query based on filters and type.

  ## Examples

      iex> query(filters, type, opts)
      {:ok, query}
  """
  def query(filters, type \\ nil, opts)

  def query([my: :objects], type, opts),
    do: query([subjects: current_user_required!(opts)], type, opts)

  def query([my: :requesters], type, opts),
    do: query([objects: current_user_required!(opts)], type, opts)

  def query(filters, type, opts) do
    query_base(filters, type, opts)

    # |> info("requests query")
  end

  @doc """
  Lists all requests made by the current user.

  ## Examples

      iex> list_my_requested(opts)
      [{:ok, request}]
  """
  def list_my_requested(opts),
    do: list_requested(current_user_required!(opts), opts)

  @doc """
  Lists all requests made by the given user.

  ## Examples

      iex> list_requested(user, opts)
      [{:ok, request}]
  """
  def list_requested(
        %{id: user_id} = _user,
        opts \\ []
      )
      when is_binary(user_id) do
    opts = to_options(opts)

    query([subjects: user_id], opts[:type], opts)
    # Exclude ignored requests
    |> where([r], is_nil(r.ignored_at))
    |> many(opts)
  end

  @doc """
  Lists all requesters for the current user.

  ## Examples

      iex> list_my_requesters(opts)
      [{:ok, requester}]
  """
  def list_my_requesters(opts),
    do: list_requesters(current_user_required!(opts), opts)

  @doc """
  Lists all requesters for the given user.

  ## Examples

      iex> list_requesters(user, opts)
      [{:ok, requester}]
  """
  def list_requesters(
        %{id: user_id} = _user,
        opts \\ []
      )
      when is_binary(user_id) do
    opts = to_options(opts)

    query([objects: user_id], opts[:type], opts)
    # Exclude ignored requests
    |> where([r], is_nil(r.ignored_at))
    |> many(opts)
  end

  def many(query, opts), do: Social.many(query, opts[:paginate] || false, opts)

  # defp maybe_with_requester_profile_only(q, true),
  #   do: where(q, [requester_profile: p], not is_nil(p.id))

  # defp maybe_with_requester_profile_only(q, _), do: q

  # defp check_request(requester, object, opts) do
  #   skip? = skip_boundary_check?(opts, object)
  #   skip? = (:admins == skip? && Bonfire.Me.Accounts.is_admin?(requester)) || (skip? == true)
  #   opts = Keyword.put_new(opts, :verbs, [:request])

  #   if skip? do
  #     info("skip boundary check")
  #     {:ok, object}
  #   else
  #     case uid(object) do
  #       id when is_binary(id) ->
  #         Common.Needles.one(id, opts ++ [log_query: true])
  #         |> info("allowed to request ?")
  #       _ ->
  #         error(object, "no object ID, try with username")
  #         maybe_apply(Characters, :by_username, [object, opts])
  #     end
  #   end
  # end

  defp do_request(requester, type, object, opts) do
    opts =
      opts
      |> Keyword.put(:boundary, "mentions")
      |> Keyword.put_new(:to_circles, [id(object)])
      |> Keyword.put_new(:to_feeds, notifications: object)

    case create(requester, type, object, opts) do
      {:ok, request} ->
        if opts[:incoming] != true,
          do:
            Social.maybe_federate_and_gift_wrap_activity(
              current_user(opts) || requester,
              request,
              opts
            ),
          else: {:ok, request}

      e ->
        warn(e, "Could not create the request, checking if it was made already")
        maybe_already(requester, type, object, opts)
    end
  rescue
    e in Ecto.ConstraintError ->
      err(e, "Could not create the request, checking if it was made already")
      maybe_already(requester, type, object, opts)
  end

  defp maybe_already(requester, type, object, opts) do
    case get(requester, type, object, skip_boundary_check: true) do
      {:ok, request} ->
        if Social.is_local?(requester) and !Social.is_local?(object) do
          info(type, "was already requested, but will attempt re-federating the request")
          Social.maybe_federate_and_gift_wrap_activity(current_user(opts) || requester, request)
        else
          debug(type, "was already requested")
          {:ok, request}
        end

      e ->
        case Edges.get(type, requester, object, skip_boundary_check: true) do
          {:ok, object} ->
            debug("request was already approved")
            {:ok, object}

          e ->
            error(e, "Could not make the request")
        end
    end
  end

  def unrequest(requester, type, %{} = object) do
    with [_id] <- Edges.delete_by_both(requester, type, object) do
      # delete the like activity & feed entries
      Activities.delete_by_subject_verb_object(requester, :request, object)
    end
  end

  def unrequest(%{} = user, type, object) when is_binary(object) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(object, current_user: user) do
      unrequest(user, type, object)
    end
  end

  defp create(requester, type, object, opts) do
    Edges.insert({Request, type}, requester, :request, object, opts)
  end

  ###

  def ap_publish_activity(requester, {:accept_from, accept_from}, request) do
    request_id = uid(request)

    with false <- Social.is_local?(requester),
         {:ok, accept_from_actor} <-
           ActivityPub.Actor.get_cached(pointer: accept_from),
         {:ok, requester_actor} <-
           ActivityPub.Actor.get_cached(pointer: requester),
         {:ok, ap_object} <-
           ActivityPub.Object.get_cached(pointer: request_id) |> info(),
         {:ok, _} <-
           ActivityPub.accept(%{
             actor: accept_from_actor,
             to: [requester_actor.data],
             object: ap_object.data,
             local: true
           }) do
      :ok
    else
      true ->
        info("the subject is local")
        :ok

      e ->
        error(e, "Could not push the acceptation of request #{request_id}")
    end
  end

  # publish a follow request
  def ap_publish_activity(
        subject,
        verb,
        %{edge: %{table_id: "70110WTHE1EADER1EADER1EADE"}} = request
      ) do
    # info(request)
    Bonfire.Social.Graph.Follows.ap_publish_activity(subject, verb, request)
  end

  # publish a quote request
  def ap_publish_activity(
        subject,
        verb,
        %{edge: %{table_id: _}} = request
      ) do
    # TODO: better way to know what's a quote request vs other kinds
    Bonfire.Social.Quotes.ap_publish_activity(subject, verb, request)
  end

  def ap_publish_activity(_, _verb, request) do
    # TODO
    error(request, "unhandled request type")
  end
end
