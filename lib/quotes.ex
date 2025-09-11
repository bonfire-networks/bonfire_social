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

  def quote_verb_id, do: Bonfire.Boundaries.Verbs.get_id(:annotate)

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
    do: Requests.requested?(quote_post, :annotate, quoted_object)

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
      Bonfire.Boundaries.can?(user, :annotate, quoted_object) ->
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
    |> flood("pending quote requests")
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
    # table_id: :annotate (annotation verb) 
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
    |> flood("Created quote request")
  end

  def accept_quote(quote_object, quoted_object, opts \\ []) do
    Requests.get(quote_object, quote_verb_id(), quoted_object, opts)
    |> flood("got quote request to accept")
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
           Requests.accept(request, opts) |> flood("accepted_quote"),
         quoted_creator =
           (quoted_creator ||
              e(request, :edge, :object, :created, :creator, nil) ||
              e(quoted_object, :created, :creator, nil) ||
              e(request, :edge, :object, :created, :creator_id, nil) ||
              e(quoted_object, :created, :creator_id, nil))
           |> flood("determined_quoted_creator"),
         quote_creator =
           (quote_creator ||
              e(request, :edge, :subject, :created, :creator, nil) ||
              e(quote_post, :created, :creator, nil) ||
              e(request, :edge, :subject, :created, :creator_id, nil) ||
              e(quote_post, :created, :creator_id, nil))
           |> flood("determined_quote_creator"),
         {:ok, quote_post} <-
           update_quote_add(quote_creator, quote_post, quoted_object, opts)
           |> repo().maybe_preload([:post_content, :activity])
           |> flood("updated_quote"),
         :ok <-
           if(opts[:incoming] != true,
             #  TODO: the Accept activity should include "result": "https://example.com/users/alice/stamps/1" with a QuoteAuthorization
             do:
               Requests.ap_publish_activity(
                 quoted_creator,
                 {:accept_to, quote_creator},
                 opts[:request_activity] || request
               )
               |> flood("published_accept"),
             else: :ok
           ),
         # Then send Update for the now-authorized quote post (only if this is a local quote_post)
         {:ok, quote_post} <-
           Social.maybe_federate_and_gift_wrap_activity(
             quoted_creator,
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

  def reject_quote(quote_object, quoted_object, opts \\ []) do
    with {:ok, request} <-
           Requests.get(quote_object, quote_verb_id(), quoted_object, skip_boundary_check: true)
           |> flood("got quote request to reject"),
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
    reject(request, e(request, :edge, :subject, nil), e(request, :edge, :object, nil), opts)
  end

  def reject(request, quote_object, quoted_object, opts) do
    quote_object =
      quote_object
      |> repo().maybe_preload(created: [creator: [:character]])

    quoted_object =
      quoted_object
      |> repo().maybe_preload(created: [creator: [:character]])

    with {:ok, request} <- Requests.ignore(request, opts) |> flood("ignored_quote_request"),
         {:ok, _} <-
           update_quote_remove(quote_object, quoted_object) |> flood("removed_quote_tag"),
         quoted_creator =
           e(quoted_object, :created, :creator, nil) ||
             e(quoted_object, :created, :creator_id, nil),
         quote_creator =
           e(quote_object, :created, :creator, nil) ||
             e(quote_object, :created, :creator_id, nil),
         {:ok, ap_quoted_object} <-
           ActivityPub.Object.get_cached(pointer: quoted_object)
           |> flood("ap_quoted_object"),
         {:ok, quoted_actor} <-
           if(quoted_creator,
             do: ActivityPub.Actor.get_cached(pointer: quoted_creator) |> flood("quoted_creator"),
             else: err(quoted_object, "quoted_creator not found")
           ),
         {:ok, quote_actor} <-
           if(quote_creator,
             do: ActivityPub.Actor.get_cached(pointer: quote_creator) |> flood("quote_creator"),
             else: err(quote_object, "quote_creator not found")
           ),
         %ActivityPub.Object{} = quote_request_activity <-
           ActivityPub.Object.fetch_latest_activity(quote_actor, ap_quoted_object, "QuoteRequest")
           |> flood("latest"),
         {:ok, _} <-
           if(opts[:verb] == :delete,
             do: ActivityPub.delete(quote_request_activity),
             else:
               ActivityPub.reject(%{
                 actor: quoted_actor,
                 to: [quote_actor],
                 object: quote_request_activity.data,
                 local: true
               })
           )
           |> flood("ap_rejected_quote_request") do
      {:ok, request}
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
    flood(quote_post, "thing to remove tags from")
    flood(quoted_object, "tags to remove from thing")

    Bonfire.Tag.Tagged.thing_tags_remove(quote_post, quoted_object)
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
           |> flood("quote_actor"),
         {:ok, ap_quoted_object} <-
           ActivityPub.Object.get_cached(pointer: quoted_object)
           |> flood("quoted_object for #{inspect(quoted_object)}"),
         {:ok, instrument} <-
           ActivityPub.Object.get_cached(pointer: id(quote_post))
           |> flood("quote post for #{inspect(quote_post)}"),
         {:ok, activity} <-
           ActivityPub.quote_request(%{
             actor: actor,
             object: ap_quoted_object,
             instrument: instrument,
             local: true
           }) do
      {:ok, activity}
    else
      {:error, :not_found} ->
        flood("Actor, Object, or Quote Post not found", error_msg)
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
    flood(data, "Received QuoteRequest activity")
    # debug(quoted_object, "quoted_object")

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
          with {:ok, quote_post} <-
                 Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(data["instrument"])
                 |> flood("prepared quote post"),
               %{} = quoted_post <- e(quoted_object, :pointer, nil),
               {:ok, request} <-
                 create_quote_request(requester, quoted_post, quote_post, incoming: true)
                 |> flood("prepared quote request to auto-accept"),
               # Auto-approve and tag the quote post
               {:ok, _updated} <-
                 accept_quote_request(request, quote_post, quoted_post,
                   incoming: false,
                   request_activity: quote_request_activity
                 )
                 |> flood("Auto-accepted quote request and updated quote post") do
            {:ok, request}
          else
            e ->
              err(e, "Error processing incoming quote post")
          end

        {:request_needed, quoted_object} ->
          with {:ok, quote_post} <-
                 Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(data["instrument"])
                 |> flood("prepared quote post") do
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
    flood(accept_activity, "Received Accept for QuoteRequest")
    flood(request_activity, "QuoteRequest object being accepted")

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
         #  quote_post_creator =
         #    e(local_quote_post, :pointer, :created, :creator, nil) ||
         #      e(local_quote_post, :pointer, :created, :creator_id, nil),
         {:ok, local_quote_post} <-
           accept_quote(local_quote_post.pointer, quoted_object.pointer,
             request_activity: request_activity
           )
           |> flood("Updated local quote post with authorization") do
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
    flood(quote_request_object, "Received Reject for QuoteRequest")

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
         #  quote_post_creator =
         #    e(local_quote_post, :pointer, :created, :creator, nil) ||
         #      e(local_quote_post, :pointer, :created, :creator_id, nil),
         {:ok, updated_quote_post} <-
           reject_quote(local_quote_post.pointer, quoted_object.pointer)
           |> flood("Updated local quote post with rejection") do
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
    flood(object, "Received Delete for QuoteRequest")

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
