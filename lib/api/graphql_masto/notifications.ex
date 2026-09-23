if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQLMasto.Notifications do
    @moduledoc """
    Resolves Bonfire notification feed entries into Mastodon API notification candidates.

    Notification verbs are filtered in the feed query. Create/reply entries reach the notifications feed only because the user was mentioned, replied to or directly addressed, which Mastodon models as `mention`.
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

    # Which Mastodon type each kind of notification is, and which activity types to query for one, are both declared by the notification categories (`Bonfire.Social.RuntimeConfig`) and read through `Bonfire.Social.Notifications`, so this API and the notifications feed cannot disagree about what a favourite is.
    @masto_types [:favourite, :reblog, :follow, :follow_request, :quote, :mention, :admin_report]

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
    query Notifications($first: Int, $last: Int, $after: String, $before: String, $filter: FeedFilters, $grouped: Boolean!) {
      feed: feedActivitiesPreloaded(first: $first, last: $last, after: $after, before: $before, filter: $filter) {
        page_info: pageInfo {
          start_cursor: startCursor end_cursor: endCursor has_next_page: hasNextPage
        }
        edges {
          node {
            id
            object_id: objectId
            date
            verb { verb }
            subject { #{@actor_fields} }
            subjects_more: subjectsMore @include(if: $grouped) { #{@actor_fields} }
            object {
              ... on Post {
                id
                post_content: postContent { name summary html_body: rawBody }
                creator { #{@actor_fields} }
              }
              ... on Poll { id }
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

      case run_notifications_feed(feed_filter, params, current_user, opts) do
        {:ok, nodes, page_info} ->
          candidates =
            nodes
            |> activities_to_candidates(current_user)
            |> Enum.filter(&candidate_matches?(&1, type_filters))
            |> Enum.take(limit)

          {:ok, candidates,
           if(Keyword.get(opts, :grouped?, false),
             do: page_info,
             else: notifications_page_info(candidates)
           )}

        {:error, _} = error ->
          error
      end
    end

    defp run_notifications_feed(feed_filter, params, current_user, opts) do
      gql_filter =
        %{
          # the notifications-class feeds, notifications ∪ inbox: Mastodon models a direct message as a `mention`, and a DM is delivered to the inbox, so reading the notifications feed alone hid every message from a client
          "feedName" => get_map_field(feed_filter, :feed_name) || "notifications_class",
          "showObjectsOnlyOnce" => false,
          "dedupByLikeOrBoost" => Keyword.get(opts, :group_likes_boosts?, false),
          # Mastodon filters kinds per request (`types[]`/`exclude_types[]`) and stores no per-kind preference, so a client gets every category whatever the user hid in Bonfire's own UI
          "includeHiddenTypes" => true
        }
        |> put_var(
          "activityTypes",
          Enum.map(get_map_field(feed_filter, :activity_types, []), &to_string/1)
        )
        |> put_var("subjects", get_map_field(feed_filter, :subjects))
        # Mastodon wants full history, not the 7-day default window — forward time_limit: 0.
        |> Map.put("timeLimit", get_map_field(feed_filter, :time_limit) || 0)

      variables =
        %{"filter" => gql_filter, "grouped" => Keyword.get(opts, :grouped?, false)}
        |> put_var("first", Map.get(params, :first) || Map.get(params, "first"))
        |> put_var("last", Map.get(params, :last) || Map.get(params, "last"))
        |> put_var("after", Map.get(params, :after) || Map.get(params, "after"))
        |> put_var("before", Map.get(params, :before) || Map.get(params, "before"))

      case Absinthe.run(@notifications_query, Bonfire.API.GraphQL.Schema,
             variables: variables,
             context: Bonfire.API.GraphQL.Schema.context(%{current_user: current_user})
           ) do
        {:ok, %{data: %{"feed" => %{"edges" => edges, "page_info" => page_info}}}}
        when is_list(edges) ->
          page_info = %{
            start_cursor: page_info["start_cursor"],
            end_cursor: page_info["end_cursor"],
            final_cursor: if(page_info["has_next_page"], do: nil, else: :last)
          }

          {:ok, edges |> Enum.map(&get_map_field(&1, :node)) |> Enum.reject(&is_nil/1), page_info}

        {:ok, %{errors: errors}} ->
          {:error, errors}

        _ ->
          {:ok, [], %{final_cursor: :last}}
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
        |> Map.put_new("feed_name", "notifications_class")
        |> Map.put("activity_types", query_verbs(type_filters))
        |> maybe_put_subjects(type_filters.account_id)

      params
      |> Map.delete(:filter)
      |> Map.put("filter", filter)
    end

    defp query_verbs(%{types: types, exclude_types: exclude}) do
      base =
        case verbs_for_types(types) do
          [] -> verbs_for_types(@masto_types)
          verbs -> verbs
        end

      remaining_types = (types || @masto_types) -- (exclude || [])
      Enum.filter(base, &(&1 in verbs_for_types(remaining_types)))
    end

    def verbs_for_notification_types(types), do: verbs_for_types(normalize_types(types) || [])

    defp verbs_for_types(nil), do: []

    defp verbs_for_types(types) do
      types
      |> List.wrap()
      |> Enum.flat_map(&Bonfire.Social.Notifications.activity_types_for_masto_type/1)
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

      with type when not is_nil(type) <- candidate_type(activity, current_user) do
        subject = get_map_field(activity, :subject) || get_map_field(activity, :account)
        status_post = status_post(type, activity)

        %Candidate{
          id: get_map_field(activity, :id),
          type: type,
          activity: activity,
          actor: subject,
          actor_id: get_map_field(activity, :subject_id) || get_map_field(subject, :id),
          object_id: object_id,
          status_post: status_post,
          created_at: get_map_field(activity, :created_at) || get_map_field(activity, :date),
          status_context:
            status_context_for_ids([object_id, get_map_field(status_post, :id)], status_context),
          mentions: mentions
        }
      end
    end

    # Create/reply activities only land in the notifications feed when the user was mentioned,
    # replied to or directly addressed. Bonfire has no "notify on every post by this author"
    # subscription, so there is no producer for Mastodon's `status` type.
    defp candidate_type(activity, current_user \\ nil) do
      case Activities.experienced_as(atom_keyed(activity), current_user) do
        # something written that reached this feed did so because it was addressed to them, which is the only thing Mastodon's vocabulary can call it
        experience when experience in [:create, :write] ->
          :mention

        experience ->
          Bonfire.Social.Notifications.masto_type_for(experience)
      end
    end

    # This pipeline passes activities around as maps that can be keyed by string, which `Activities.experienced_as/2` cannot read: it is built on `e/3`, which only sees atom keys and would answer `nil` for every row. So the few fields it reads are lifted through the same accessor everything else here uses.
    defp atom_keyed(activity) do
      verb = get_map_field(activity, :verb)

      %{
        verb_id: get_map_field(activity, :verb_id),
        verb: if(is_map(verb), do: %{verb: get_map_field(verb, :verb)}, else: verb),
        edge: get_map_field(activity, :edge),
        object: get_map_field(activity, :object),
        tags: get_map_field(activity, :tags) || [],
        replied: get_map_field(activity, :replied),
        emoji: get_map_field(activity, :emoji)
      }
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

    # Mastodon models a direct message as a `mention` notification, so the inbox counts here as well as the notifications feed: reading only the latter made a fetch by id answer "not found" for a DM the list had already shown.
    # FIXME: one query, not two. 
    defp published_to_user_notifications?(current_user, activity_id) do
      case Feeds.notifications_class_ids(current_user) do
        [] ->
          false

        feed_ids ->
          from(fp in FeedPublish,
            where: fp.id == ^activity_id and fp.feed_id in ^feed_ids,
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

    defp get_map_field(value, field, default \\ nil)
    defp get_map_field(nil, _field, default), do: default

    defp get_map_field(%{} = map, field, default) do
      Map.get(map, field) || Map.get(map, to_string(field), default)
    end

    defp get_map_field(_other, _field, _default), do: nil

    defp quote_table_id, do: Quotes.quote_verb_id()
  end
end
