defmodule Bonfire.Social.Quotes do
  @moduledoc """
  Handles quote post requests and approvals following FEP-044f.

  Provides functionality for requesting permission to quote posts,
  accepting/rejecting requests, and verifying quote authorizations.
  """

  alias Bonfire.Data.Social.Request
  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.Requests
  alias Bonfire.Social.PostContents
  alias Bonfire.Social
  alias Bonfire.Tag
  alias Bonfire.Data.Edges.Edge

  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "QuoteRequest",
      {"Accept", "QuoteRequest"},
      {"Reject", "QuoteRequest"},
      {"Delete", "QuoteAuthorization"}
    ]


    @doc """
  Checks if a quote request has been made.

  ## Parameters

  - `subject`: The subject (requester)
  - `quote_post`: The quote post (instrument)
  - `quoted_object`: The quoted object 

  ## Returns

  Boolean indicating if a quote request exists.

  ## Examples

      iex> Bonfire.Social.Quotes.requested?(user, quote_post, quoted_object)
      true
  """
  def requested?(subject, quote_post, quoted_object),
    do: Requests.requested?(subject, id(quote_post), quoted_object)
    
  @doc """
  Requests permission to quote a post, checking boundaries and creating requests as needed.

  Returns a tuple with {approved_quotes, pending_quotes} where:
  - approved_quotes can be tagged immediately  
  - pending_quotes need quote requests after post creation
  """
  def process_quotes(user, quoted_objects, opts \\ [])

  def process_quotes(user, quoted_objects, opts) when is_list(quoted_objects) do
    results = Enum.map(quoted_objects, &process_quote(user, &1, opts))

    approved = Enum.filter_map(results, &match?({:auto_approve, _}, &1), &elem(&1, 1))
    pending = Enum.filter_map(results, &match?({:request_needed, _}, &1), &elem(&1, 1))

    {approved, pending}
  end

  def process_quote(user, quoted_object, opts) do
    check_quote_permission(user, quoted_object, opts)
  end

  @doc """
  Creates quote requests for pending quotes after the post has been created.
  """
  def create_pending_quote_requests(user, pending_quotes, quote_post, opts \\ []) do
    pending_quotes
    |> flood("pending quote requests")
    |> Enum.map(fn quoted_object ->
      create_quote_request(user, quoted_object, quote_post, opts)
    end)
    |> flood("Created quote requests for pending quotes")
    |> Enum.reject(&match?({:error, _}, &1))
  end

  defp check_quote_permission(user, quoted_object, _opts \\ []) do
    user_id = id(user)
    quoted_object = repo().maybe_preload(quoted_object, [:created])

    cond do
      e(quoted_object, :created, :creator_id, nil) == user_id ||
          id(quoted_object) == user_id ->
        flood(user_id, "User is quoting their own post")
        {:auto_approve, quoted_object}

      # Check if user can annotate the post (auto-approve)
      Bonfire.Boundaries.can?(user, :annotate, quoted_object) ->
        flood(user_id, "User has permission to annotate")
        {:auto_approve, quoted_object}

      # Check if user can make a request about the post (manual approval)  
      Bonfire.Boundaries.can?(user, :request, quoted_object) ->
        flood(user_id, "User needs to request")
        {:request_needed, quoted_object}

      true ->
        {:not_permitted, quoted_object}
    end
  end

  defp create_quote_request(user, quoted_object, quote_post, opts) do
    # Store as a Request in our database and federate as QuoteRequest
    # subject: requester (user)
    # table_id: ID of the quote_post (the new post wanting to quote, also called instrument in AP FEP-044f )
    # object: quoted_object (the post being quoted)
    Requests.request(
      user,
      id(quote_post),
      quoted_object,
      opts
      |> Keyword.put(:federation_module, __MODULE__)
      # |> Keyword.put(:current_user, user)
    )
    |> flood("Created quote request")
  end

  def accept_quote_from(requester, quoted_object, opts \\ []) do
    # Requests.get(requester, id(quote_post), original_post)
    # TODO: we should accept the request of the specific quote post, not just any request from this user for this quoted object

    Requests.get(requester, nil, quoted_object, opts)
    |> flood("got quote request to accept")
    ~> accept(requester, opts)
  end

  def accept(request, requester, opts) do
    debug(opts, "opts")

    with {:ok,
          %{edge: %{object: quoted_object, subject: subject, table_id: quote_post_id}} = request} <-
           Requests.accept(request, opts) |> flood("accepted_quote"),
         {:ok, quote_post} <-
           update_quote(subject, quote_post_id, quoted_object, opts)
           |> repo().maybe_preload([:post_content, :activity])
           |> flood("updated_quote"),
         :ok <-
           if(opts[:incoming] != true,
             do:
               Requests.ap_publish_activity(subject, {:accept_from, requester}, request)
               |> flood("published_accept"),
             else: :ok
           ),
         # Then send Update for the now-authorized quote post (only if this is a local quote_post)
         {:ok, quote_post} <-
           Social.maybe_federate_and_gift_wrap_activity(
             subject,
             quote_post,
             opts ++ [verb: :update]
           )
           |> flood("published_update_for_quote_post") do
      {:ok, quote_post}
    else
      e ->
        error(e, l("An error occurred while accepting the quote request"))
    end
  end

  def update_quote(subject, quote_post_id, quoted_object, opts) do
    debug(subject, "update_quote subject (quote post)")
    debug(quote_post_id, "update_quote quote_post_id (post with attached quote)")
    debug(quoted_object, "update_quote object (quoted post)")

    Bonfire.Tag.tag_something(
      subject,
      quote_post_id,
      [quoted_object],
      :skip_boundary_check
    )
  end

  # ActivityPub integration

  def ap_publish_activity(
        subject,
        verb,
        request
      ) do
    flood(request, "Publishing QuoteRequest activity")

    request =
      repo().maybe_preload(request,
        # :pointer, 
        edge: [:subject, :object]
      )

    error_msg = l("Could not federate the quote request")

    with {:ok, actor} <-
           ActivityPub.Actor.get_cached(
             pointer:
               subject || e(request, :edge, :subject, nil) || e(request, :edge, :subject_id, nil)
           )
           |> flood("actor"),
         {:ok, object} <-
           ActivityPub.Object.get_cached(
             pointer: e(request, :edge, :object, nil) || e(request, :edge, :object_id, nil)
           )
           |> flood("quote request object"),
         {:ok, instrument} <-
           ActivityPub.Object.get_cached(pointer: e(request, :edge, :table_id, nil))
           |> flood("quote post"),
         {:ok, activity} <-
           ActivityPub.quote_request(%{
             actor: actor,
             object: object,
             instrument: instrument,
             local: true
           }) do
      {:ok, activity}
    else
      {:error, :not_found} ->
        err("Actor, Object, or Quote Post not found", error_msg)
        {:ok, :ignore}

      {:reject, reason} ->
        {:reject, reason}

      e ->
        err(e, error_msg)
        raise error_msg
    end
  end

  def ap_receive_activity(
        subject,
        %{data: %{"type" => "QuoteRequest", "actor" => actor} = data} = _activity,
        quoted_object
      ) do
    flood(data, "Received QuoteRequest activity")
    # flood(quoted_object, "quoted_object")

    # Extract request details and create local request
    with {:ok, requester} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(actor),
         %{} = quoted_object <-
           quoted_object
           |> repo().maybe_preload(pointer: [:created])
           |> flood("loaded quoted object"),
         quoted_creator =
           e(quoted_object, :pointer, :created, :creator, nil) ||
             e(quoted_object, :pointer, :created, :creator_id, nil),
         {:ok, quoted_actor} <-
           if(quoted_creator,
             do: ActivityPub.Actor.get_cached(pointer: quoted_creator) |> flood("quoted_creator"),
             else: err(quoted_object, "quoted_creator not found")
           ) do
      case check_quote_permission(requester, quoted_object)
           |> flood("checked_quote_permission") do
        {:auto_approve, quoted_object} ->
          # Auto-send Accept activity without needing to store Request
          # Don't call ActivityPub.quote_request - just send Accept directly
          ActivityPub.accept(%{
            actor: quoted_actor,
            to: [actor],
            object: data,
            local: true
          })
          |> flood("Auto-accepted quote request")

        {:request_needed, quoted_object} ->
          with {:ok, quote_post} <-
                 Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(data["instrument"])
                 |> flood("prepared quote post") do
            # Save request in our system for manual approval
            flood("WIP: send notification of request to user")

            create_quote_request(requester, e(quoted_object, :pointer, nil), quote_post,
              incoming: true
            )
          else
            e ->
              err(e, "Error processing incoming quote post")
          end

        {:not_permitted, _quoted_object} ->
          # Send Reject 
          ActivityPub.reject(%{
            actor: quoted_actor,
            to: [data["actor"]],
            object: data,
            local: true
          })
          |> flood("Rejected quote request")
      end
    else
      {:error, e} ->
        flood(e, "QuoteRequest error")
        err(e, "Error processing incoming QuoteRequest")

      e ->
        flood(e, "unexpected")
        err(e, "Unexpected error processing incoming QuoteRequest")
    end
  end

  def ap_receive_activity(
        _subject,
        %{data: %{"type" => "Accept"}} = activity,
        %{
          data: %{
            "type" => "QuoteRequest",
            "instrument" => quote_post,
            "object" => quoted_object_id
          }
        } = quote_request_object
      ) do
    debug(activity, "Received Accept for QuoteRequest")
    debug(quote_request_object, "QuoteRequest object being accepted")

    with {:ok, local_quote_post} <-
           ActivityPub.Object.get_cached(ap_id: quote_post)
           |> repo().maybe_preload(pointer: [:created])
           |> flood("Found local quote post"),
         {:ok, quoted_object} <-
           ActivityPub.Object.get_cached(ap_id: quoted_object_id)
           |> repo().maybe_preload([:pointer])
           #  |> repo().maybe_preload(pointer: [:created])
           |> flood("loaded quoted object"),
         # quoted_creator = e(quoted_object, :pointer, :created, :creator, nil) || e(quoted_object, :pointer, :created, :creator_id, nil),
         quote_post_creator =
           e(local_quote_post, :pointer, :created, :creator, nil) ||
             e(local_quote_post, :pointer, :created, :creator_id, nil),
         {:ok, updated_quote_post} <-
           accept_quote_from(quote_post_creator, quoted_object)
           #  update_quote(
           #    quoted_creator, 
           #    e(local_quote_post, :pointer, nil),
           #    e(quoted_object, :pointer, nil),
           #    incoming: true
           #  )
           |> flood("Updated local quote post with authorization") do
      debug("Successfully processed Accept for QuoteRequest")
      {:ok, updated_quote_post}
    else
      {:error, :not_found} ->
        warn("Could not find local quote post or quoted object for Accept")
        {:error, "Quote post or quoted object not found locally"}

      e ->
        error(e, "Error processing Accept for QuoteRequest")
    end
  end

  def ap_receive_activity(
        _subject,
        %{data: %{"type" => "Reject"}} = activity,
        %{data: %{"type" => "QuoteRequest"}} = object
      ) do
    debug(activity, "Received Reject for QuoteRequest")
    # Handle rejected quote request
    err("TODO: Remove local quote post if needed")
  end

  def ap_receive_activity(
        _subject,
        %{data: %{"type" => "Delete"}} = activity,
        %{data: %{"type" => "QuoteRequest"}} = object
      ) do
    debug(activity, "Received Delete for QuoteRequest")
    # Handle rejected quote request
    err("TODO: Remove local quote post")
  end

  def ap_receive_activity(_subject, activity, _object) do
    debug(activity, "Unhandled quote activity")
    {:ignore, "Not a quote-related activity"}
  end


end
