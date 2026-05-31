defmodule Bonfire.Social.API.GraphQLMasto.Notifications do
  @moduledoc """
  Resolves Bonfire notification feed entries into Mastodon API notification candidates.

  Notification-type selection is pushed into the feed query (via `activity_types`), so a single
  page contains only notification-relevant activities. We trust feed membership for mention/reply
  semantics: an activity only reaches a user's notifications feed if they were mentioned or
  replied to (see `Bonfire.Social.Feeds.reply_and_or_mentions_notifications_feeds/5`).
  """

  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  import Ecto.Query

  alias Bonfire.Data.Social.FeedPublish
  alias Bonfire.Data.Social.Follow
  alias Bonfire.Social.Activities
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.API.GraphQLMasto.NotificationCandidate, as: Candidate
  alias Bonfire.Social.Quotes
  alias Bonfire.API.MastoCompat.FeedPipeline
  alias Bonfire.API.MastoCompat.BatchLoaders

  @type_by_api_name %{
    "favourite" => :favourite,
    "reblog" => :reblog,
    "follow" => :follow,
    "follow_request" => :follow_request,
    "poll" => :poll,
    "mention" => :mention,
    "admin.report" => :admin_report,
    "quote" => :quote,
    "quoted_update" => :quoted_update,
    "status" => :status,
    "update" => :update
  }

  # Mastodon notification type -> the Bonfire verbs that produce it.
  @type_to_verbs %{
    favourite: [:like],
    reblog: [:boost],
    follow: [:follow],
    follow_request: [:request],
    quote: [:request],
    poll: [:vote],
    mention: [:create, :reply],
    admin_report: [:flag]
  }

  # All verbs that can appear as a notification (used when no type filter is given).
  @default_notification_verbs [:like, :boost, :follow, :request, :vote, :create, :reply, :flag]

  @doc """
  Lists notification candidates for a user in a single feed query.

  Returns `{:ok, candidates, page_info}`, filtered by the requested
  `types`/`exclude_types`/`account_id`.
  """
  def list_for_user(current_user, params, opts \\ [])
  def list_for_user(nil, _params, _opts), do: {:error, :unauthorized}

  # Actor fields, shared with the timeline adapter — covers User + Category (groups), without
  # which group-authored notifications resolve to an untyped actor and get dropped on validation.
  @actor_fields Bonfire.API.MastoCompat.Fragments.actor_fields()

  # REST-on-GraphQL (Phase 7): verb-filtered notifications feed via `feedActivitiesPreloaded`,
  # candidates built from the activity nodes.
  @notifications_query """
  query Notifications($first: Int, $last: Int, $after: String, $before: String, $filter: FeedFilters) {
    feed: feedActivitiesPreloaded(first: $first, last: $last, after: $after, before: $before, filter: $filter) {
      edges {
        node {
          id
          object_id: objectId
          date
          verb { verb }
          subject { #{@actor_fields} }
          object {
            ... on Post {
              id
              post_content: postContent { name summary html_body: rawBody }
              creator { #{@actor_fields} }
            }
          }
          edge { table_id: tableId subject_id: subjectId }
        }
      }
    }
  }
  """

  def list_for_user(current_user, params, opts) do
    type_filters = normalize_filters(Keyword.get(opts, :filters, %{}))
    limit = page_limit(params)

    feed_filter =
      get_map_field(put_notification_query_filters(params, type_filters), :filter, %{})

    case run_notifications_feed(feed_filter, params, current_user) do
      {:ok, nodes} ->
        candidates =
          nodes
          |> activities_to_candidates(current_user)
          |> Enum.filter(&candidate_matches?(&1, type_filters))
          |> Enum.take(limit)

        {:ok, candidates, notifications_page_info(candidates)}

      {:error, _} = error ->
        error
    end
  end

  defp run_notifications_feed(feed_filter, params, current_user) do
    gql_filter =
      %{"feedName" => get_map_field(feed_filter, :feed_name) || "notifications"}
      |> put_var(
        "activityTypes",
        Enum.map(get_map_field(feed_filter, :activity_types, []), &to_string/1)
      )
      |> put_var("subjects", get_map_field(feed_filter, :subjects))
      # Mastodon wants full history, not the 7-day default window — forward time_limit: 0.
      |> Map.put("timeLimit", get_map_field(feed_filter, :time_limit) || 0)

    variables =
      %{"filter" => gql_filter}
      |> put_var("first", Map.get(params, :first) || Map.get(params, "first"))
      |> put_var("last", Map.get(params, :last) || Map.get(params, "last"))
      |> put_var("after", Map.get(params, :after) || Map.get(params, "after"))
      |> put_var("before", Map.get(params, :before) || Map.get(params, "before"))

    case Absinthe.run(@notifications_query, Bonfire.API.GraphQL.Schema,
           variables: variables,
           context: Bonfire.API.GraphQL.Schema.context(%{current_user: current_user})
         ) do
      {:ok, %{data: %{"feed" => %{"edges" => edges}}}} when is_list(edges) ->
        {:ok, edges |> Enum.map(&get_map_field(&1, :node)) |> Enum.reject(&is_nil/1)}

      {:ok, %{errors: errors}} ->
        {:error, errors}

      _ ->
        {:ok, []}
    end
  end

  defp put_var(map, _key, nil), do: map
  defp put_var(map, _key, []), do: map
  defp put_var(map, key, value), do: Map.put(map, key, value)

  defp notifications_page_info([]), do: %{}

  defp notifications_page_info(candidates) do
    ids = candidates |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)
    %{start_cursor: List.first(ids), end_cursor: List.last(ids), cursor_fields: [id: :desc]}
  end

  defp page_limit(params) do
    Map.get(params, :first) || Map.get(params, :last) ||
      Map.get(params, "first") || Map.get(params, "last") || 20
  end

  @doc "Resolves one notification candidate by ID for the given user."
  def get_for_user(current_user, id, opts \\ [])
  def get_for_user(nil, _id, _opts), do: {:error, :unauthorized}

  def get_for_user(current_user, id, opts) when is_binary(id) do
    with true <- published_to_user_notifications?(current_user, id),
         {:ok, activity} <- Activities.get(id, current_user: current_user),
         {:ok, candidate} <- activity_to_candidate(activity, current_user, opts) do
      {:ok, candidate}
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  def get_for_user(_current_user, _id, _opts), do: {:error, :not_found}

  # Inject the notification-type verb filter (and optional account filter) into the
  # feed query, so a single page contains only mappable notification activities.
  defp put_notification_query_filters(params, type_filters) do
    filter =
      params
      |> get_map_field(:filter, %{})
      |> Map.put_new("feed_name", "notifications")
      |> Map.put("activity_types", query_verbs(type_filters))
      |> maybe_put_subjects(type_filters.account_id)

    params
    |> Map.delete(:filter)
    |> Map.put("filter", filter)
  end

  defp query_verbs(%{types: types, exclude_types: exclude}) do
    base =
      case verbs_for_types(types) do
        [] -> @default_notification_verbs
        verbs -> verbs
      end

    base -- verbs_for_types(exclude)
  end

  defp verbs_for_types(nil), do: []

  defp verbs_for_types(types) do
    types
    |> List.wrap()
    |> Enum.flat_map(&Map.get(@type_to_verbs, &1, []))
    |> Enum.uniq()
  end

  defp maybe_put_subjects(filter, nil), do: filter
  defp maybe_put_subjects(filter, account_id), do: Map.put(filter, "subjects", [account_id])

  defp activity_to_candidate(activity, current_user, opts) do
    activity =
      activity
      |> Activities.activity_preloads(
        FeedPipeline.feed_preloads() ++ FeedPipeline.postload_preloads(),
        current_user: current_user,
        skip_boundary_check: true
      )
      |> preload_request_edges()

    status_context =
      BatchLoaders.load(current_user, raw_object_ids([activity]), post_content?: true)

    case build_candidate(activity, current_user, status_context, opts) do
      %Candidate{} = candidate -> {:ok, candidate}
      nil -> {:error, :not_found}
    end
  end

  defp activities_to_candidates(activities, current_user) do
    status_context =
      BatchLoaders.load(current_user, raw_object_ids(activities), post_content?: true)

    activities
    |> Enum.flat_map(fn activity ->
      case build_candidate(activity, current_user, status_context, []) do
        %Candidate{} = candidate -> [candidate]
        nil -> []
      end
    end)
  end

  defp preload_request_edges(activities) do
    repo().maybe_preload(activities,
      edge: [
        :request,
        subject: [
          :post_content,
          created: [creator: [:profile, :character]]
        ]
      ]
    )
  end

  defp build_candidate(activity, current_user, status_context, _opts) do
    object_id = get_map_field(activity, :object_id)
    mentions_by_object = Keyword.get(status_context, :mentions_by_object, %{})
    mentions = Map.get(mentions_by_object, object_id, [])

    with type when not is_nil(type) <- candidate_type(activity) do
      subject = get_map_field(activity, :subject) || get_map_field(activity, :account)
      status_post = status_post(type, activity)

      %Candidate{
        id: get_map_field(activity, :id),
        type: type,
        activity: activity,
        actor: subject,
        actor_id: get_map_field(activity, :subject_id),
        object_id: object_id,
        status_post: status_post,
        created_at: get_map_field(activity, :created_at) || get_map_field(activity, :date),
        status_context:
          status_context_for_ids([object_id, get_map_field(status_post, :id)], status_context),
        mentions: mentions
      }
    end
  end

  # Map a notification-feed activity to its Mastodon notification type. We trust
  # feed membership: a create/reply in the user's notifications feed is there
  # because they were mentioned or replied to, which Mastodon models as :mention.
  defp candidate_type(activity) do
    verb_id = get_map_field(activity, :verb_id)
    verb_name = get_verb_name(activity)

    cond do
      verb_matches?(verb_id, verb_name, :like) -> :favourite
      verb_matches?(verb_id, verb_name, :boost) -> :reblog
      verb_matches?(verb_id, verb_name, :follow) -> :follow
      verb_matches?(verb_id, verb_name, :request) -> request_type(activity)
      verb_matches?(verb_id, verb_name, :vote) -> :poll
      verb_matches?(verb_id, verb_name, :create) -> :mention
      verb_matches?(verb_id, verb_name, :reply) -> :mention
      verb_matches?(verb_id, verb_name, :flag) -> :admin_report
      true -> nil
    end
  end

  defp request_type(activity) do
    edge = get_map_field(activity, :edge)
    table_id = get_map_field(edge, :table_id)

    cond do
      table_id == quote_table_id() -> :quote
      table_id == follow_table_id() -> :follow_request
      true -> nil
    end
  end

  defp status_post(:quote, activity) do
    edge = get_map_field(activity, :edge)

    case get_map_field(edge, :subject) do
      %{id: _} = post -> post
      _ -> load_quote_post(get_map_field(edge, :subject_id))
    end
  end

  defp status_post(_type, _activity), do: nil

  defp load_quote_post(id) when is_binary(id) do
    case Bonfire.Social.Objects.read(id,
           skip_boundary_check: true,
           preload: [:with_post_content, :with_creator]
         ) do
      {:ok, post} -> post
      _ -> nil
    end
  end

  defp load_quote_post(_), do: nil

  defp candidate_matches?(%Candidate{} = candidate, filters) do
    type_match? =
      (is_nil(filters.types) or candidate.type in filters.types) and
        (is_nil(filters.exclude_types) or candidate.type not in filters.exclude_types)

    account_match? = is_nil(filters.account_id) or candidate.actor_id == filters.account_id

    type_match? and account_match?
  end

  defp normalize_filters(filters) do
    %{
      types: normalize_types(Map.get(filters, :types) || Map.get(filters, "types")),
      exclude_types:
        normalize_types(Map.get(filters, :exclude_types) || Map.get(filters, "exclude_types")),
      account_id: Map.get(filters, :account_id) || Map.get(filters, "account_id")
    }
  end

  defp normalize_types(nil), do: nil

  defp normalize_types(types) do
    types
    |> List.wrap()
    |> Enum.map(fn
      type when is_atom(type) -> type
      type when is_binary(type) -> Map.get(@type_by_api_name, type)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp published_to_user_notifications?(current_user, activity_id) do
    case Feeds.my_feed_id(:notifications, current_user) do
      nil ->
        false

      feed_id ->
        from(fp in FeedPublish,
          where: fp.id == ^activity_id and fp.feed_id == ^feed_id,
          select: true
        )
        |> repo().exists?()
    end
  end

  defp raw_object_ids(activities) do
    activities
    |> Enum.flat_map(fn activity ->
      [get_map_field(activity, :object_id), quote_request_post_id(activity)]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp quote_request_post_id(activity) do
    edge = get_map_field(activity, :edge)

    if get_map_field(edge, :table_id) == quote_table_id() do
      get_map_field(edge, :subject_id) ||
        edge |> get_map_field(:subject) |> get_map_field(:id)
    end
  end

  defp status_context_for_ids(ids, status_context) do
    ids =
      ids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    [
      interaction_states:
        take_map_keys(Keyword.get(status_context, :interaction_states, %{}), ids),
      mentions_by_object:
        take_map_keys(Keyword.get(status_context, :mentions_by_object, %{}), ids),
      post_content_by_id:
        take_map_keys(Keyword.get(status_context, :post_content_by_id, %{}), ids),
      visibility_by_object:
        take_map_keys(Keyword.get(status_context, :visibility_by_object, %{}), ids),
      followers_grant_objects:
        take_map_set_keys(
          Keyword.get(status_context, :followers_grant_objects, MapSet.new()),
          ids
        )
    ]
  end

  defp take_map_keys(map, ids) when is_map(map) do
    ids
    |> Enum.flat_map(fn id ->
      case Map.fetch(map, id) do
        {:ok, value} -> [{id, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp take_map_keys(_map, _ids), do: %{}

  defp take_map_set_keys(%MapSet{} = set, ids) do
    ids
    |> Enum.filter(&MapSet.member?(set, &1))
    |> MapSet.new()
  end

  defp take_map_set_keys(_set, _ids), do: MapSet.new()

  defp verb_matches?(verb_id, verb_name, verb) do
    verb_id == Bonfire.Boundaries.Verbs.get_id!(verb) ||
      verb_name == Bonfire.Boundaries.Verbs.get(verb)[:verb]
  end

  defp get_verb_name(activity) do
    case get_map_field(activity, :verb) do
      %{verb: verb} when is_binary(verb) -> verb
      %{"verb" => verb} when is_binary(verb) -> verb
      verb when is_binary(verb) -> verb
      _ -> nil
    end
  end

  defp get_map_field(value, field, default \\ nil)
  defp get_map_field(nil, _field, default), do: default

  defp get_map_field(%{} = map, field, default) do
    Map.get(map, field) || Map.get(map, to_string(field), default)
  end

  defp get_map_field(_other, _field, _default), do: nil

  defp quote_table_id, do: Quotes.quote_verb_id()
  defp follow_table_id, do: Bonfire.Common.Types.table_id(Follow)
end
