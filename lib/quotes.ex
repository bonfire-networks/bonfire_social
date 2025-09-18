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

  def quote_verb, do: :quote
  def quote_verb_id, do: Bonfire.Boundaries.Verbs.get_id(quote_verb())

  @doc """
  Checks if a quote request has been made.

  ## Parameters

  - `subject`: The subject (requester)
  - `quote_post`: The quote post (instrument)
  - `quoted_object`: The quoted object 

  ## Returns

  Boolean indicating if a quote request exists.

  ## Examples

      iex> Bonfire.Social.Quotes.requested?(quote_post, quoted_object)
      true
  """
  def requested?(quote_post, quoted_object),
    do: Requests.requested?(quote_post, quote_verb(), quoted_object)

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

  def check_quote_permission(user, quoted_object, _opts \\ []) do
    user_id = id(user)
    quoted_object = repo().maybe_preload(quoted_object, [:created])

    cond do
      e(quoted_object, :created, :creator_id, nil) == user_id ||
          id(quoted_object) == user_id ->
        debug(user_id, "User is quoting their own post")
        {:auto_approve, quoted_object}

      # Check if user can annotate the post (auto-approve)
      Bonfire.Boundaries.can?(user, quote_verb(), quoted_object) ->
        debug(user_id, "User has permission to annotate")
        {:auto_approve, quoted_object}

      # Check if user can make a request about the post (manual approval)  
      Bonfire.Boundaries.can?(user, :request, quoted_object) ->
        debug(user_id, "User needs to request")
        {:request_needed, quoted_object}

      true ->
        {:not_permitted, quoted_object}
    end
  end

  @doc """
  Creates quote requests for pending quotes after the post has been created.
  """
  def create_quote_requests(user, pending_quotes, quote_post, opts \\ []) do
    pending_quotes
    |> debug("pending quote requests")
    |> Enum.map(fn quoted_object ->
      create_quote_request(user, quoted_object, quote_post, opts)
    end)
    |> debug("Created quote requests for pending quotes")
    |> Enum.reject(&match?({:error, _}, &1))
  end

  defp create_quote_request(user, quoted_object, quote_post, opts) do
    quoted_object =
      quoted_object
      |> repo().maybe_preload(created: [creator: [:character]])

    # Get the creator of the quoted object for notifications
    quoted_creator =
      e(quoted_object, :created, :creator, nil) ||
        e(quoted_object, :created, :creator_id, nil)

    # Store as a Request in our database and federate as QuoteRequest
    # subject: quote_post (can lookup creator from here)
    # table_id: :quote verb
    # object: quoted_object (the post being quoted)
    Requests.request(
      quote_post,
      quote_verb_id(),
      quoted_object,
      opts
      |> Keyword.put(:current_user, user)
      |> Keyword.put(:federation_module, __MODULE__)
      |> Keyword.put(:to_circles, [id(quoted_creator)])
      |> Keyword.put(:to_feeds, notifications: quoted_creator)
    )
    |> debug("Created quote request on #{repo()}")
  end

  def requested(quote_object, quoted_object, opts \\ []) do
    Requests.get(
      quote_object,
      quote_verb_id(),
      quoted_object,
      opts |> Keyword.put(:skip_boundary_check, true)
    )
  end

  def accept_quote(quote_object, quoted_object, opts \\ []) do
    requested(quote_object, quoted_object, opts)
    |> debug("got quote request to accept on #{repo()}")
    ~> accept_quote_request(quote_object, quoted_object, opts)
  end

  def accept_quote_request(request, quote_object, quoted_object, opts \\ []) do
    quote_object =
      quote_object
      |> repo().maybe_preload(created: [creator: [:character]])

    quoted_object =
      quoted_object
      |> repo().maybe_preload(created: [creator: [:character]])

    quote_creator =
      e(quote_object, :created, :creator, nil) ||
        e(quote_object, :created, :creator_id, nil)

    quoted_creator =
      e(quoted_object, :created, :creator, nil) ||
        e(quoted_object, :created, :creator_id, nil)

    accept(request, quote_creator, quoted_creator, opts)
  end

  def accept(request, quote_creator \\ nil, quoted_creator \\ nil, opts) do
    # debug(opts, "opts")

    with {:ok, %{edge: %{object: quoted_object, subject: quote_post}} = request} <-
           Requests.accept(request, opts) |> debug("accepted_quote on #{repo()}"),
         quoted_creator =
           (quoted_creator ||
              e(request, :edge, :object, :created, :creator, nil) ||
              e(quoted_object, :created, :creator, nil) ||
              e(request, :edge, :object, :created, :creator_id, nil) ||
              e(quoted_object, :created, :creator_id, nil))
           |> debug("determined_quoted_creator"),
         quote_creator =
           (quote_creator ||
              e(request, :edge, :subject, :created, :creator, nil) ||
              e(quote_post, :created, :creator, nil) ||
              e(request, :edge, :subject, :created, :creator_id, nil) ||
              e(quote_post, :created, :creator_id, nil))
           |> debug("determined_quote_creator"),
         {:ok, quote_post} <-
           update_quote_add(quote_creator, quote_post, quoted_object, opts)
           |> repo().maybe_preload([:post_content, :activity])
           |> debug("updated_quote"),
         :ok <-
           if(opts[:incoming] != true,
             #  TODO: the Accept activity should include "result": "https://example.com/users/alice/stamps/1" with a QuoteAuthorization
             do:
               Requests.ap_publish_activity(
                 quoted_creator,
                 {:accept_to, quote_creator},
                 opts[:request_activity] || request
               )
               |> debug("published_accept"),
             else: :ok
           ),
         # Then send Update for the now-authorized quote post (only if this is a local quote_post)
         {:ok, quote_post} <-
           Social.maybe_federate_and_gift_wrap_activity(
             quoted_creator,
             quote_post,
             opts ++ [verb: :update]
           )
           |> debug("published_update_for_quote_post") do
      {:ok, quote_post}
    end
  end

  def reject_quote(quote_object, quoted_object, opts \\ []) do
    with {:ok, request} <-
           requested(quote_object, quoted_object, opts)
           |> debug("got quote request to reject"),
         {:ok, request} <- reject(request, quote_object, quoted_object, opts) do
      {:ok, request}
    end
  end

  @doc """
  Rejects a quote request.

  ## Parameters

  - `request`: The request to ignore
  - `opts`: Additional options

  ## Returns

  Result of the ignore operation.

  ## Examples

      iex> reject(request, current_user: user)
      {:ok, ignored_request}
  """
  def reject(request, opts) do
    Requests.requested(request)
    |> debug("request to reject")
    ~> reject(..., e(..., :edge, :subject, nil), e(..., :edge, :object, nil), opts)
  end

  def reject(request, quote_object, quoted_object, opts)
      when is_struct(quote_object) and is_struct(quoted_object) do
    quote_object =
      quote_object
      |> repo().maybe_preload(created: [creator: [:character]])

    quoted_object =
      quoted_object
      |> repo().maybe_preload(created: [creator: [:character]])

    quoted_creator =
      (e(request, :edge, :object, :created, :creator, nil) ||
         e(quoted_object, :created, :creator, nil) ||
         e(request, :edge, :object, :created, :creator_id, nil) ||
         e(quoted_object, :created, :creator_id, nil))
      |> debug("determined_quoted_creator")

    with {:ok, request} <- Requests.ignore(request, opts) |> debug("ignored_quote_request"),
         {:ok, quote_object} <-
           update_quote_remove(quote_object, quoted_object) |> debug("removed_quote_tag"),
         {:ok, _} <-
           federate_reject(opts[:verb], request, quote_object, quoted_object)
           |> debug("ap_rejected_quote_request"),
         # Then send Update for the now-unauthorized quote post (only if this is a local quote_post)
         {:ok, quote_post} <-
           Social.maybe_federate_and_gift_wrap_activity(
             quoted_creator,
             quote_object,
             opts ++ [verb: :update]
           )
           |> debug("published_update_for_quote_post") do
      {:ok, quote_post}
    end
  end

  defp federate_reject(:delete, request, quote_object, quoted_object) do
    with {:ok, ap_quote_object} <-
           ActivityPub.Object.get_cached(pointer: quote_object)
           |> debug("ap_quote_object"),
         {:ok, quote_auth} <-
           ActivityPub.Object.get_cached(ap_id: ap_quote_object.data["quoteAuthorization"])
           |> debug("ap_quoteAuthorization"),
         {:ok, result} <-
           ActivityPub.delete(quote_auth,
             bcc: e(ap_quote_object, :data, "to", []) ++ e(ap_quote_object, :data, "cc", [])
           ) do
      {:ok, result}
    else
      {:error, :not_found} ->
        debug("No quoteAuthorization found, nothing to delete")
        {:ok, :ignore}

      e ->
        error(e, "Error while attempting to federate the rejection")
    end
  end

  defp federate_reject(_reject, request, quote_object, quoted_object) do
    quoted_creator =
      e(quoted_object, :created, :creator, nil) ||
        e(quoted_object, :created, :creator_id, nil)

    quote_creator =
      e(quote_object, :created, :creator, nil) ||
        e(quote_object, :created, :creator_id, nil)

    with {:ok, ap_quoted_object} <-
           ActivityPub.Object.get_cached(pointer: quoted_object)
           |> debug("ap_quoted_object"),
         {:ok, quoted_actor} <-
           if(quoted_creator,
             do: ActivityPub.Actor.get_cached(pointer: quoted_creator) |> debug("quoted_creator"),
             else: err(quoted_object, "quoted_creator not found")
           ),
         {:ok, quote_actor} <-
           if(quote_creator,
             do: ActivityPub.Actor.get_cached(pointer: quote_creator) |> debug("quote_creator"),
             else: err(quote_object, "quote_creator not found")
           ),
         %ActivityPub.Object{} = quote_request_activity <-
           ActivityPub.Object.fetch_latest_activity(quote_actor, ap_quoted_object, "QuoteRequest")
           |> debug("latest"),
         {:ok, result} <-
           ActivityPub.reject(%{
             actor: quoted_actor,
             to: [quote_actor],
             object: quote_request_activity.data,
             local: true
           }) do
      {:ok, result}
    else
      {:error, :not_found} ->
        warn("No AP object found for the quote post, quoted post, or actor, so skip federation")
        {:ok, :ignore}

      e ->
        error(e, "Error while attempting to federate the rejection")
    end
  end

  def update_quote_add(subject, quote_post, quoted_object, _opts) do
    # debug(subject, "update_quote_add subject (requester)")
    # debug(quote_post, "update_quote_add quote_post (post with attached quote)")
    # debug(quoted_object, "update_quote_add object (quoted post)")

    Bonfire.Tag.tag_something(
      subject,
      quote_post,
      [quoted_object],
      :skip_boundary_check
    )
  end

  def update_quote_remove(quote_post, quoted_object) do
    debug(quote_post, "thing to remove tags from")
    debug(quoted_object, "tags to remove from thing")

    Bonfire.Tag.Tagged.thing_tags_remove(quote_post, quoted_object)

    {:ok,
     quote_post
     |> repo().maybe_preload([:tags], force: true)}
  end

  @doc """
  Fetches the QuoteAuthorization for a quote post using fresh data.

  ## Parameters

  - `quote_post`: The quote post to get authorization for
  - `quoted_object`: The quoted object (optional - if not provided, gets first quoted object)

  ## Returns

  `{:ok, authorization}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> fetch_fresh_quote_authorization(quote_post)
      {:ok, %ActivityPub.Object{}}

      iex> fetch_fresh_quote_authorization(quote_post, quoted_object)
      {:ok, %ActivityPub.Object{}}
  """
  def fetch_fresh_quote_authorization(quote_post, quoted_object \\ nil) do
    quoted_object = quoted_object || get_first_quoted_object(quote_post)

    with {:ok, %{data: ap_json}} <-
           ActivityPub.Object.get_cached(pointer: quote_post) |> debug("quote_ap_json"),
         quote_auth_url when is_binary(quote_auth_url) <- ap_json["quoteAuthorization"],
         {:ok, authorization} <-
           ActivityPub.Federator.Fetcher.fetch_fresh_object_from_id(quote_auth_url,
             return_tombstones: true
           )
           |> debug("fetched_fresh") do
      {:ok, authorization}
    else
      nil ->
        debug("No quoteAuthorization field in quote post")
        {:error, :not_found}

      other ->
        other
    end
  end

  @doc """
  Verifies that a quote authorization is valid.

  ## Parameters

  - `quote_post`: The quote post to verify authorization for
  - `quoted_object`: The quoted object (optional - will call get_quote_authorization to get it)

  ## Returns

  - `{:ok, :valid}` if authorization exists and is valid
  - `{:error, :invalid}` if authorization exists but is invalid (wrong signatures, etc)  
  - `{:error, :revoked}` if authorization was deleted/revoked or network errors

  ## Examples

      iex> Bonfire.Social.Quotes.verify_quote_authorization(quote_post)
      {:ok, :valid}

      iex> Bonfire.Social.Quotes.verify_quote_authorization(quote_post, quoted_object)
      {:error, :invalid}
  """
  def verify_quote_authorization(quote_post, quoted_object \\ nil, authorization \\ nil) do
    quoted_object =
      (quoted_object || get_first_quoted_object(quote_post))
      |> debug("quoted_object for verification")

    case authorization || fetch_fresh_quote_authorization(quote_post, quoted_object) do
      {:ok, authorization} ->
        case ActivityPub.Object.is_deleted?(authorization) do
          true ->
            {:not_authorized, "Quote authorization was revoked"}

          false ->
            case verify_authorization_data(authorization, quote_post, quoted_object) do
              {:ok, :valid} -> {:ok, :authorization_verified}
              {:error, reason} -> {:not_authorized, reason}
            end
        end

      {:error, :network_error} ->
        {:error, "Network error fetching quote authorization"}

      {:error, :not_found} ->
        {:not_authorized, "Quote authorization not found"}

      {:error, other} ->
        err(other, "Unexpected error fetching quote authorization")
    end
    |> case do
      {:not_authorized, reason} ->
        info(reason, "Quote authorization invalid or revoked, removing quote tag if present")
        reject_quote(quote_post, quoted_object)

        {:not_authorized, reason}

      other ->
        other
    end
  end

  defp get_first_quoted_object(quote_post) do
    quote_tags = Bonfire.Social.Tags.list_tags_quote(quote_post)

    case quote_tags do
      [first_tag | _] -> first_tag
      [] -> nil
    end
  end

  defp verify_authorization_data(%{data: auth_data} = authorization, quote_post, quoted_object) do
    quote_post = repo().maybe_preload(quote_post, [:created])
    quoted_object = repo().maybe_preload(quoted_object, [:created])

    quote_creator_id =
      e(quote_post, :created, :creator_id, nil) || id(quote_post)

    quoted_creator_id =
      e(quoted_object, :created, :creator_id, nil) || id(quoted_object)

    with {:ok, quote_ap_object} <- ActivityPub.Object.get_cached(pointer: quote_post),
         {:ok, quoted_ap_object} <- ActivityPub.Object.get_cached(pointer: quoted_object),
         {:ok, quoted_actor} <- ActivityPub.Actor.get_cached(pointer: quoted_creator_id) do
      cond do
        # Check that authorization references correct objects
        auth_data["interactingObject"] != quote_ap_object.data["id"] ->
          error(
            auth_data["interactingObject"],
            "authorization object does not match quote post ID"
          )

          error(quote_ap_object.data["id"], "Quote post ID does not match authorization object")

        auth_data["interactionTarget"] != quoted_ap_object.data["id"] ->
          error(
            auth_data["interactionTarget"],
            "authorization target does not match quote post ID"
          )

          error(
            quoted_ap_object.data["id"],
            "Quoted object ID does not match authorization target"
          )

        # Check that authorization is signed by quoted object's creator
        auth_data["attributedTo"] != quoted_actor.ap_id ->
          error(
            auth_data["attributedTo"],
            "Authorization actor does not match quoted object's creator"
          )

        true ->
          {:ok, :valid}
      end
    else
      e ->
        error(e, "Error loading objects for authorization verification")
    end
  end

  #### ActivityPub integration

  def ap_publish_activity(
        subject,
        verb,
        request
      ) do
    debug(request, "Publishing QuoteRequest activity")

    request =
      repo().maybe_preload(request,
        # :pointer, 
        edge: [:object, subject: [created: [:creator]]]
      )

    error_msg = l("Could not federate the quote request")

    # Get the creator of the quote post (which is the subject in our new structure)
    quote_post =
      e(request, :edge, :subject, nil)

    quoted_object = e(request, :edge, :object, nil) || e(request, :edge, :object_id, nil)

    with {:ok, actor} <-
           ActivityPub.Actor.get_cached(
             pointer:
               subject || e(quote_post, :created, :creator, nil) ||
                 e(quote_post, :created, :creator_id, nil)
           )
           |> debug("quote_actor"),
         {:ok, ap_quoted_object} <-
           ActivityPub.Object.get_cached(pointer: quoted_object)
           |> debug("quoted_object for #{inspect(quoted_object)}"),
         {:ok, instrument} <-
           ActivityPub.Object.get_cached(pointer: id(quote_post))
           |> debug("quote post for #{inspect(quote_post)}"),
         {:ok, activity} <-
           ActivityPub.quote_request(%{
             actor: actor,
             object: ap_quoted_object,
             instrument: instrument,
             local: true
           })
           |> debug("created AP quote request") do
      {:ok, activity}
    else
      {:error, :not_found} ->
        debug("Actor, Object, or Quote Post not found", error_msg)
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
        %{data: %{"type" => "QuoteRequest", "actor" => actor} = data} = quote_request_activity,
        quoted_object
      ) do
    debug(data, "Received QuoteRequest activity")
    # debug(quoted_object, "quoted_object")

    # Extract request details and create local request
    with {:ok, requester} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(actor),
         %{} = quoted_object <-
           quoted_object
           |> repo().maybe_preload(pointer: [:created])
           |> debug("loaded quoted object"),
         quoted_creator =
           e(quoted_object, :pointer, :created, :creator, nil) ||
             e(quoted_object, :pointer, :created, :creator_id, nil),
         {:ok, quoted_actor} <-
           if(quoted_creator,
             do: ActivityPub.Actor.get_cached(pointer: quoted_creator) |> debug("quoted_creator"),
             else: err(quoted_object, "quoted_creator not found")
           ) do
      case check_quote_permission(requester, quoted_object)
           |> debug("checked_quote_permission") do
        {:auto_approve, quoted_object} ->
          with {:ok, quote_post} <-
                 Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(data["instrument"])
                 |> debug("prepared quote post"),
               %{} = quoted_post <- e(quoted_object, :pointer, nil),
               {:ok, request} <-
                 create_quote_request(requester, quoted_post, quote_post, incoming: true)
                 |> debug("prepared quote request to auto-accept"),
               # Auto-approve and tag the quote post
               {:ok, _updated} <-
                 accept_quote_request(request, quote_post, quoted_post,
                   incoming: false,
                   request_activity: quote_request_activity
                 )
                 |> debug("Auto-accepted quote request and updated quote post") do
            {:ok, request}
          else
            e ->
              err(e, "Error processing incoming quote post")
          end

        {:request_needed, quoted_object} ->
          with {:ok, quote_post} <-
                 Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(data["instrument"])
                 |> debug("prepared quote post") do
            # Save request in our system for manual approval
            debug("WIP: send notification of request to user")

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
          |> debug("Rejected quote request")
      end
    else
      {:error, e} ->
        debug(e, "QuoteRequest error")
        err(e, "Error processing incoming QuoteRequest")

      e ->
        debug(e, "unexpected")
        err(e, "Unexpected error processing incoming QuoteRequest")
    end
  end

  def ap_receive_activity(
        _subject,
        %{data: %{"type" => "Accept"}} = accept_activity,
        %{
          data: %{
            "type" => "QuoteRequest",
            "instrument" => quote_post,
            "object" => quoted_object_id
          }
        } = request_activity
      ) do
    debug(accept_activity, "Received Accept for QuoteRequest")
    debug(request_activity, "QuoteRequest object being accepted")

    with {:ok, local_quote_post} <-
           ActivityPub.Object.get_cached(ap_id: quote_post)
           |> repo().maybe_preload(pointer: [:created])
           |> debug("Found local quote post"),
         {:ok, quoted_object} <-
           ActivityPub.Object.get_cached(ap_id: quoted_object_id)
           |> repo().maybe_preload([:pointer])
           #  |> repo().maybe_preload(pointer: [:created])
           |> debug("loaded quoted object"),
         # quoted_creator = e(quoted_object, :pointer, :created, :creator, nil) || e(quoted_object, :pointer, :created, :creator_id, nil),
         #  quote_post_creator =
         #    e(local_quote_post, :pointer, :created, :creator, nil) ||
         #      e(local_quote_post, :pointer, :created, :creator_id, nil),
         {:ok, local_quote_post} <-
           accept_quote(local_quote_post.pointer, quoted_object.pointer,
             request_activity: request_activity
           )
           |> debug("Updated local quote post with authorization") do
      {:ok, local_quote_post}
    else
      {:error, :not_found} ->
        err("Could not find local quote post or quoted object for Accept")
        {:error, "Quote post or quoted object not found locally"}

      e ->
        err(e, "Error processing Accept for QuoteRequest")
    end
  end

  def ap_receive_activity(
        _subject,
        %{data: %{"type" => "Reject"}} = _activity,
        %{
          data: %{
            "type" => "QuoteRequest",
            "instrument" => quote_post,
            "object" => quoted_object_id
          }
        } = quote_request_object
      ) do
    debug(quote_request_object, "Received Reject for QuoteRequest")

    with {:ok, local_quote_post} <-
           ActivityPub.Object.get_cached(ap_id: quote_post)
           |> repo().maybe_preload(pointer: [:created])
           |> debug("Found local quote post"),
         {:ok, quoted_object} <-
           ActivityPub.Object.get_cached(ap_id: quoted_object_id)
           |> repo().maybe_preload([:pointer])
           #  |> repo().maybe_preload(pointer: [:created])
           |> debug("loaded quoted object"),
         # quoted_creator = e(quoted_object, :pointer, :created, :creator, nil) || e(quoted_object, :pointer, :created, :creator_id, nil),
         #  quote_post_creator =
         #    e(local_quote_post, :pointer, :created, :creator, nil) ||
         #      e(local_quote_post, :pointer, :created, :creator_id, nil),
         {:ok, updated_quote_post} <-
           reject_quote(local_quote_post.pointer, quoted_object.pointer)
           |> debug("Updated local quote post with rejection") do
      {:ok, updated_quote_post}
    else
      {:error, :not_found} ->
        err("Could not find local quote post or quoted object for Reject")
        {:error, "Quote post or quoted object not found locally"}

      e ->
        err(e, "Error processing Reject for QuoteRequest")
    end
  end

  def ap_receive_activity(
        _subject,
        %{data: %{"type" => "Delete"}} = _activity,
        %{data: %{"type" => "QuoteRequest"}} = object
      ) do
    debug(object, "Received Delete for QuoteRequest")

    ap_receive_activity(
      _subject,
      %{data: %{"type" => "Reject"}} = _activity,
      object
    )
  end

  def ap_receive_activity(_subject, activity, _object) do
    debug(activity, "Unhandled quote activity")
    {:ignore, "Not a quote-related activity"}
  end
end
