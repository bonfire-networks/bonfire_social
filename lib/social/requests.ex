
defmodule Bonfire.Social.Requests do

  alias Bonfire.Data.Social.Request
  alias Bonfire.Me.{Boundaries, Characters, Users}
  alias Bonfire.Social.{Activities, APActivities, Edges, FeedActivities, Feeds, Integration}
  alias Bonfire.Data.Identity.User
  alias Ecto.Changeset
  import Bonfire.Boundaries.Queries
  import Where
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo

  def queries_module, do: Request
  def context_module, do: Request
  # def federation_module, do: ["Accept", "Reject"]

  def requested?(subject, type, object), do: not is_nil(get!(subject, type, object, skip_boundary_check: true))


  @doc """
  Request someone/something, and federate it
  """
  def request(user, type, object, opts \\ [])
  def request(%{}=requester, type, object, opts) do
    opts = Keyword.put_new(opts, :current_user, requester)
    object
    # |> check_request(requester, ..., opts) # TODO: check if allowed to request?
    ~> do_request(requester, type, ..., opts)
  end


  @doc """
  Request someone/something, and federate it
  """
  def accept(request, opts) do
    requested(request, opts)
    ~> Request.changeset(%{accepted_at: DateTime.now!("Etc/UTC")})
    |> repo().update()
    # |> dump
  end

  def ignore(request, opts) do
    requested(request, opts)
    ~> Request.changeset(%{ignored_at: DateTime.now!("Etc/UTC")})
    |> repo().update()
    # |> dump
  end

  def get(subject, type, object, opts \\ []), do: Edges.get({__MODULE__, type}, subject, object, opts)
  def get!(subject, type, object, opts \\ []), do: Edges.get!({__MODULE__, type}, subject, object, opts)

  def get(filters, opts \\ []), do: Edges.get(__MODULE__, filters, opts)

  def requested(request, opts \\ [])
  def requested(%Request{id: _} = request, _opts), do: {:ok, request}
  def requested(request, opts), do: get([id: ulid(request)], opts)

  # TODO: abstract the next few functions into Edges
  def all_by_subject(user, type, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :object)
    |> query([subject: user], type, ...)
    |> repo().many()
  end

  def all_objects_by_subject(user, type, opts \\ []) do
    all_by_subject(user, type, opts)
    |> Enum.map(& e(&1, :edge, :object, nil))
  end

  def all_by_object(user, type, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :subject)
    |> query([object: user], type, ...)
    |> repo().many()
  end

  def all_subjects_by_object(user, type, opts \\ []) do
    all_by_object(user, type, opts)
    |> Enum.map(& e(&1, :edge, :subject, nil))
  end

  def all_requested_outboxes(user, type, opts \\ []) do
    all_objects_by_subject(user, type, opts)
    |> Enum.map(& e(&1, :character, :outbox_id, nil))
  end

  # defp query_base(filters, opts) do
  #   vis = filter_invisible(current_user(opts))
  #   from(f in Request, join: v in subquery(vis), on: f.id == v.object_id)
  #   |> proload(:edge)
  #   |> query_filter(filters)
  # end

  defp query_base(filters, type \\ nil, opts)

  defp query_base(filters, type, opts) when is_atom(type) and not is_nil(type) do
    (filters ++ [type: type.__pointers__(:table_id)])
    |> query_base(opts)
  end

  defp query_base(filters, _, opts) do
    Edges.query_parent(Request, filters, opts)
    |> query_filter(Keyword.drop(filters, [:object, :subject, :type]))
    # |> proload(:request)
  end

  def query([my: :object], type, opts), do: [subject: current_user(opts)] |> query(type, opts)

  def query([my: :requesters], type, opts), do: [object: current_user(opts)] |> query(type, opts)

  def query(filters, type \\ nil, opts) do
    query_base(filters, type, opts)
    # |> info("requests query")
  end

  def list_my_requested(type, opts, with_profile_only \\ true),
    do: list_requested(type, current_user(opts), opts, with_profile_only)

  def list_requested(%{id: user_id} = _user, type, opts \\ [], with_profile_only \\ true) when is_binary(user_id) do
    query([subject: user_id], type, opts)
    # |> maybe_with_requested_profile_only(with_profile_only)
    |> many(opts)
  end

  def list_my_requesters(opts, type, with_profile_only \\ true),
    do: list_requesters(current_user(opts), type, opts, with_profile_only)

  def list_requesters(%{id: user_id} = _user, type, opts \\ [], with_profile_only \\ true) when is_binary(user_id) do
    query([object: user_id], type, opts)
    # |> maybe_with_requester_profile_only(with_profile_only)
    |> many(opts)
  end

  def many(query, opts), do: repo().many(query, opts)

  defp maybe_with_requester_profile_only(q, true), do: q |> where([requester_profile: p], not is_nil(p.id))
  defp maybe_with_requester_profile_only(q, _), do: q

  # defp check_request(requester, object, opts) do
  #   skip? = skip_boundary_check?(opts, object)
  #   skip? = (:admins == skip? && Users.is_admin?(requester)) || (skip? == true)
  #   opts = Keyword.put_new(opts, :verbs, [:request])

  #   if skip? do
  #     info("skip boundary check")
  #     {:ok, object}
  #   else
  #     case ulid(object) do
  #       id when is_binary(id) ->
  #         Common.Pointers.one(id, opts ++ [log_query: true])
  #         |> info("allowed to request ?")
  #       _ ->
  #         error(object, "no object ID, try with username")
  #         maybe_apply(Characters, :by_username, [object, opts])
  #     end
  #   end
  # end

  defp do_request(requester, type, object, opts) do
    opts = [
      boundary: "mentions",
      to_circles: [ulid(object)],
      to_feeds: [notifications: object],
    ]
    case create(requester, type, object, opts) do
      {:ok, request} ->
        Integration.ap_push_activity(requester.id, request)
        {:ok, request}
      e ->
        case get(requester, type, object) do
          {:ok, request} ->
            debug("was already requested")
            {:ok, request}
          e2 ->
            error(e)
            error(e2)
            {:error, e}
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
    with {:ok, object} <- Bonfire.Common.Pointers.get(object, current_user: user) do
      unrequest(user, type, object)
    end
  end

  defp create(requester, type, object, opts) do
    Edges.changeset({Request, type}, requester, :request, object, opts)
    |> repo().upsert()
  end

  ###

  # publish follow requests
  def ap_publish_activity("create", %{edge: %{table_id: "70110WTHE1EADER1EADER1EADE"}} = request) do
    # info(request)
    with {:ok, follower} <- ActivityPub.Adapter.get_actor_by_id(request.edge.subject_id),
         {:ok, object} <- ActivityPub.Adapter.get_actor_by_id(request.edge.object_id) do
      ActivityPub.follow(follower, object, nil, true)
    end
  end

  def ap_publish_activity("create", request) do
    error(request, "unhandled request type")
  end


end
