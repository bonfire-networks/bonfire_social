if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQLMasto.Notifications do
    @moduledoc """
    Resolves Bonfire notification feed entries into Mastodon API notification candidates.

    Notification verbs are filtered in the feed query. Create/reply entries reach the notifications feed only because the user was mentioned, replied to or directly addressed, which Mastodon models as `mention`.
    """

    use Bonfire.Common.Utils

    alias Bonfire.Social.Activities
    alias Bonfire.Social.API.GraphQLMasto.NotificationCandidate, as: Candidate

    # Which Mastodon type each kind of notification is, and which activity types to query for one, are both declared by the notification categories (`Bonfire.Social.RuntimeConfig`) and read through `Bonfire.Social.Notifications` (`masto_types/0`), so this API and the notifications feed cannot disagree about what a favourite is. Mastodon's names for them come from `Bonfire.API.MastoCompat.Schemas.Notification`

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
    @object_interactions Bonfire.API.MastoCompat.Fragments.object_interactions()

    # What a notification's status needs beyond its object; media, counts and thread join on `object_id`, so on a like or boost they describe the post
    @status_fields """
    #{Bonfire.API.MastoCompat.Fragments.status_media()}
    mentions { #{@actor_fields} }
    hashtags { id name }
    visibility
    # the group or topic it was published in (`context_id`), as the feed selects it
    context { ... on Category { id } }
    # the fallback status, for an object that is neither a Post nor a Poll (`Mappers.Notification`)
    object_post_content: objectPostContent { name summary html_body: rawBody }
    replies_count: repliesCount
    like_count: likeCount
    boost_count: boostCount
    #{Bonfire.API.MastoCompat.Fragments.thread_fields()}
    """

    # One notification's activity, as the list and the single notification both select it
    @notification_node """
    id
    object_id: objectId
    date
    verb { verb }
    subject { #{@actor_fields} }
    subjects_more: subjectsMore @include(if: $grouped) { #{@actor_fields} }
    #{Bonfire.API.MastoCompat.Fragments.status_object()}
    #{@status_fields}
    edge {
      table_id: tableId
      subject_id: subjectId
      # the quoting post, on a quote request, read as the viewer
      subject_object {
        __typename
        ... on Post {
          id
          #{Bonfire.API.MastoCompat.Fragments.status_post_content()}
          #{Bonfire.API.MastoCompat.Fragments.status_media()}
          creator { #{@actor_fields} }
          #{@object_interactions}
          activity { mentions { #{@actor_fields} } hashtags { id name } visibility }
        }
      }
    }
    """

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
            #{@notification_node}
          }
        }
      }
    }
    """

    @notification_query """
    query Notification($id: ID!, $grouped: Boolean!) {
      notification(id: $id) {
        #{@notification_node}
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
          "notificationCategories",
          Enum.map(get_map_field(feed_filter, :notification_categories, []), &to_string/1)
        )
        |> put_var(
          "excludeNotificationCategories",
          Enum.map(get_map_field(feed_filter, :exclude_notification_categories, []), &to_string/1)
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

      case Bonfire.API.MastoCompat.Helpers.run_query(
             @notifications_query,
             current_user,
             variables
           ) do
        {:ok, %{data: %{feed: %{edges: edges, page_info: page_info}}}}
        when is_list(edges) ->
          page_info = %{
            start_cursor: get_map_field(page_info, :start_cursor),
            end_cursor: get_map_field(page_info, :end_cursor),
            final_cursor: if(get_map_field(page_info, :has_next_page), do: nil, else: :last)
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

    def get_for_user(current_user, id, _opts) when is_binary(id) do
      case Bonfire.API.MastoCompat.Helpers.run_query(@notification_query, current_user, %{
             "id" => id,
             "grouped" => false
           }) do
        {:ok, %{data: %{notification: %{} = node}}} ->
          case build_candidate(node, current_user) do
            %Candidate{} = candidate -> {:ok, candidate}
            nil -> {:error, :not_found}
          end

        _ ->
          {:error, :not_found}
      end
    end

    def get_for_user(_current_user, _id, _opts), do: {:error, :not_found}

    @published_notification_query """
    subscription PublishedNotification($grouped: Boolean!) {
      feed_activity: feedActivity {
        #{@notification_node}
      }
    }
    """

    @doc "A streamed activity as a notification candidate, through the list's node, run with the activity as root (`Helpers.run_published/4`); nil if it is no notification a client knows."
    def published_candidate(activity, current_user) do
      case Bonfire.API.MastoCompat.Helpers.run_published(
             @published_notification_query,
             activity,
             current_user,
             %{"grouped" => false}
           ) do
        {:ok, %{data: %{feed_activity: %{} = node}}} -> build_candidate(node, current_user)
        _ -> nil
      end
    end

    # Inject the notification-type verb filter (and optional account filter) into the
    # feed query, so a single page contains only mappable notification activities.
    defp put_notification_query_filters(params, type_filters) do
      filter =
        params
        |> get_map_field(:filter, %{})
        |> Map.put_new("feed_name", "notifications_class")
        |> Map.put("notification_categories", query_categories(type_filters))
        |> Map.put("exclude_notification_categories", categories_without_masto_type())
        |> maybe_put_subjects(type_filters.account_id)

      params
      |> Map.delete(:filter)
      |> Map.put("filter", filter)
    end

    # Mastodon's type names are read here and nowhere else: each is the categories whose `masto:` names it (Mastodon's one `mention` is both Mentions and Replies (without mentioning you)), and the feed filter then selects exactly what those categories select. With no `types[]`, every type this adapter maps, so a page holds only activities a client can be shown
    defp query_categories(%{types: types, exclude_types: exclude}) do
      masto_types = (types || Bonfire.Social.Notifications.masto_types()) -- (exclude || [])

      Bonfire.Social.Notifications.categories()
      |> Enum.map(fn {key, _category} -> key end)
      |> Enum.filter(fn key ->
        Enum.any?(Bonfire.Social.Notifications.masto_types_of(key), &(&1 in masto_types))
      end)
    end

    # What a client has no type for is left out of the query, since the mapper would drop it and leave the page short: a catch-all (Other) selects whatever no chip does, which includes kinds that have a category but no chip (votes, pins).
    # TODO: translate these into a type a client knows (eg. a note-like `status`) as needed, rather than leaving them out
    defp categories_without_masto_type do
      Bonfire.Social.Notifications.categories()
      |> Enum.map(fn {key, _category} -> key end)
      # only kinds with a condition of their own: Latest has none, and excluding it would exclude every row
      |> Enum.filter(
        # the Hidden chip is a view of who is behind rows, not a kind, and a Mastodon client gets everything regardless
        &(Bonfire.Social.Notifications.masto_types_of(&1) == [] and
            Bonfire.Social.Notifications.own_condition?(&1) and
            not Bonfire.Social.Notifications.audience_view?(&1))
      )
    end

    defp maybe_put_subjects(filter, nil), do: filter
    defp maybe_put_subjects(filter, account_id), do: Map.put(filter, "subjects", [account_id])

    # each node carries what its status needs (`@status_fields`), so no batch context
    defp activities_to_candidates(activities, current_user) do
      activities
      |> Enum.flat_map(fn activity ->
        case build_candidate(activity, current_user) do
          %Candidate{} = candidate -> [candidate]
          nil -> []
        end
      end)
    end

    defp build_candidate(activity, current_user) do
      object_id = get_map_field(activity, :object_id)
      mentions = get_map_field(activity, :mentions) || []

      with type when not is_nil(type) <- candidate_type(activity, current_user, mentions) do
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
          # each node carries what its status needs (`@status_fields`)
          status_context: [],
          mentions: mentions
        }
      end
    end

    # A post reaches the notifications feed by naming the reader (a `:mention`), answering them (a `:reply`), or without doing either: through a bell on its author or group, or addressed to a circle they're in. That last kind is Mastodon's `status`, "a new post you asked to hear about"
    defp candidate_type(activity, current_user, mentions) do
      # `:write` and `:create`, which no category claims, are named by the `masto_unclaimed` config beside the categories, which push and streaming read too
      atom_keyed(activity, mentions)
      |> Activities.experienced_as(current_user)
      |> Bonfire.Social.Notifications.masto_type_for()
    end

    # This pipeline passes activities around as maps that can be keyed by string, which `Activities.experienced_as/2` cannot read: it is built on `e/3`, which only sees atom keys and would answer `nil` for every row. So the few fields it reads are lifted through the same accessor everything else here uses.
    # `mentions` are the node's GraphQL ones (the characters named): without them a post naming the reader would read as a plain post (`:write`, a `status`) instead of a mention
    defp atom_keyed(activity, mentions) do
      verb = get_map_field(activity, :verb)

      %{
        verb_id: get_map_field(activity, :verb_id),
        verb: if(is_map(verb), do: %{verb: get_map_field(verb, :verb)}, else: verb),
        edge: atom_keyed_edge(get_map_field(activity, :edge)),
        object: atom_keyed_object(get_map_field(activity, :object)),
        tags:
          get_map_field(activity, :tags) ||
            Enum.map(
              List.wrap(mentions),
              &%{id: get_map_field(&1, :id)}
            ),
        replied: get_map_field(activity, :replied),
        emoji: get_map_field(activity, :emoji)
      }
    end

    # what `experienced_as/2` reads of the object: its id, and whether it carries written content, which is what makes a create a `:write` (a post) rather than a `:create`. The query's object is keyed by string, so its post content is lifted the same way
    # what was asked for, on a request: its edge's table (a quote, a follow, a join)
    defp atom_keyed_edge(nil), do: nil

    defp atom_keyed_edge(edge) do
      %{
        table_id: get_map_field(edge, :table_id),
        subject_id: get_map_field(edge, :subject_id)
      }
    end

    defp atom_keyed_object(nil), do: nil

    defp atom_keyed_object(object) do
      %{
        id: get_map_field(object, :id),
        post_content:
          case get_map_field(object, :post_content) do
            nil -> nil
            post_content -> %{id: get_map_field(post_content, :id)}
          end
      }
    end

    # the quoting post: the node's GraphQL `subject_object`, read as the viewer. One the reader may not read gives no status, and so no notification
    defp status_post(:quote, activity) do
      case activity |> get_map_field(:edge) |> get_map_field(:subject_object) do
        %{id: _} = post -> post
        _ -> nil
      end
    end

    defp status_post(_type, _activity), do: nil

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
        type when is_binary(type) -> Bonfire.API.MastoCompat.Schemas.Notification.type_atom(type)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
    end

    defp get_map_field(value, field, default \\ nil)
    defp get_map_field(nil, _field, default), do: default

    defp get_map_field(%{} = map, field, default) do
      Map.get(map, field) || Map.get(map, to_string(field), default)
    end

    defp get_map_field(_other, _field, _default), do: nil
  end
end
