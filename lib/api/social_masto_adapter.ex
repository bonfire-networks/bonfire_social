if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQLMasto.Adapter do
    @moduledoc """
    Social API endpoints for Mastodon-compatible client apps.

    Feeds, favourites and single-status reads run through the GraphQL Schema via `Absinthe.run`
    (the preloaded `feedActivitiesPreloaded`/`myLikes`/`status` resolvers) and map via
    `Bonfire.API.MastoCompat.Mappers.*`. A few by-id/low-volume reads (thread context, pin state,
    update) call Bonfire context functions (`Objects.read/2` etc.) directly — see
    GRAPHQL_FIRST_MASTO_PLAN.md for why those stay direct.
    """

    use Arrows
    import Ecto.Query, only: [from: 2]
    import Untangle
    use Bonfire.Common.Repo

    alias Bonfire.API.GraphQL.RestAdapter

    alias Bonfire.API.MastoCompat.{
      Mappers,
      InteractionHandler,
      Helpers,
      PaginationHelpers
    }

    import Helpers, only: [get_field: 2]

    # Actor (subject/creator/author) fields, shared with the notifications module — covers User
    # AND Category (groups), without which group-authored activities resolve to an untyped actor
    # and get dropped on validation. See `Bonfire.API.MastoCompat.Fragments.actor_fields/0`.
    @actor_fields Bonfire.API.MastoCompat.Fragments.actor_fields()
    @author_fields Bonfire.API.MastoCompat.Fragments.author_fields()
    @thread_fields Bonfire.API.MastoCompat.Fragments.thread_fields()
    @status_media Bonfire.API.MastoCompat.Fragments.status_media()
    @object_interactions Bonfire.API.MastoCompat.Fragments.object_interactions()
    @status_post_content Bonfire.API.MastoCompat.Fragments.status_post_content()
    @status_object Bonfire.API.MastoCompat.Fragments.status_object()

    # Activity-shaped selection for timelines, single statuses and streaming (handles boosts → reblog). The reblog account
    # comes from `object.creator` — the `:post.creator` field resolves synchronously from the
    # `:with_creator`-preloaded `created.creator`, avoiding the deep `object.activity.subject`
    # Dataloader rounds that made an earlier cut ~2× slower (now ~1.08× direct, within gate).
    # (Defined before feed_items: module attributes must be set before the interpolating fn.)
    @activity_node_selection """
    id
    object_id: objectId
    verb { verb }
    subject { #{@author_fields} }
    #{@status_object}
    #{@status_media}
    mentions { #{@actor_fields} }
    hashtags { id name }
    visibility
    context { ... on Category { id } }
    #{@object_interactions}
    replies_count: repliesCount
    like_count: likeCount
    boost_count: boostCount
    #{@thread_fields}
    """

    @feed_query """
    query Feed($first: Int, $last: Int, $after: String, $before: String, $filter: FeedFilters) {
      feed: feedActivitiesPreloaded(first: $first, last: $last, after: $after, before: $before, filter: $filter) {
        page_info: pageInfo {
          end_cursor: endCursor
          start_cursor: startCursor
          has_next_page: hasNextPage
          has_previous_page: hasPreviousPage
        }
        edges { node { #{@activity_node_selection} } }
      }
    }
    """

    def feed(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) and user_scoped_feed?(params) do
        # Home and bookmarks are viewer-scoped: per Mastodon spec they require auth
        # (401) rather than silently returning an empty public feed.
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        params
        |> feed_items(current_user)
        |> then(&respond_with_feed(conn, params, &1))
      end
    end

    @user_scoped_feeds ~w(my bookmarks)
    defp user_scoped_feed?(params) do
      feed_name =
        params
        |> Map.get(:filter, Map.get(params, "filter", %{}))
        |> then(&(Map.get(&1, :feed_name) || Map.get(&1, "feed_name")))

      to_string(feed_name) in @user_scoped_feeds
    end

    @doc "Profile timeline for a specific account (their posts + boosts/reblogs)."
    def user_activities_feed(user_id, params, conn) do
      current_user = conn.assigns[:current_user]

      # Load the account's OUTBOX feed (posts + boosts), matching the web UI profile
      # (feed_live.ex maps :user_activities → feed_id(:outbox, user)). The `user_activities`
      # `subjects` preset omits the account's boosts, so we pass the outbox feed id directly.
      params =
        case Bonfire.Social.Feeds.feed_id(:outbox, user_id) do
          outbox_id when is_binary(outbox_id) ->
            filter =
              params
              |> Map.get(:filter, Map.get(params, "filter", %{}))
              |> Map.put("feed_ids", [outbox_id])

            params |> Map.delete(:filter) |> Map.put("filter", filter)

          _ ->
            # fallback: keep the subjects-filtered preset if the outbox id can't be resolved
            params
        end

      params
      |> feed_items(current_user, extra_feed_opts: [by: user_id])
      |> then(&respond_with_feed(conn, params, &1))
    end

    # REST-on-GraphQL (Phase 7): load timelines through `feedActivitiesPreloaded` and map each
    # activity node via the GraphQL-output activity mapper.
    defp feed_items(params, current_user, load_opts \\ []) do
      filters = Map.get(params, :filter, Map.get(params, "filter", %{}))
      by = get_in(load_opts, [:extra_feed_opts, :by])

      gql_filter =
        %{}
        |> maybe_put_var("feedName", get_field(filters, :feed_name))
        |> maybe_put_var("feedIds", get_field(filters, :feed_ids))
        |> maybe_put_var("tags", get_field(filters, :tags))
        |> maybe_put_var("subjects", by && List.wrap(by))
        # the list timeline's members (`MastoTimelineController.list_timeline/2`): without it the list returned home
        |> maybe_put_var("subjectCircles", get_field(filters, :subject_circles))
        # set by the Mastodon timelines (posts, replies, boosts), not by bookmarks
        |> maybe_put_var("activityTypes", get_field(filters, :activity_types))
        # Mastodon wants full id-paginated history, not the feed's default 7-day window — the
        # masto params carry `time_limit: 0` (PaginationHelpers.build_feed_params); forward it
        # (default to 0) so old activities/boosts aren't hidden.
        |> maybe_put_var("timeLimit", get_field(filters, :time_limit) || 0)

      pagination_args = Map.take(params, [:first, :last, :after, :before])
      pagination = if pagination_args == %{}, do: %{first: 20}, else: pagination_args

      variables =
        %{"filter" => gql_filter}
        |> maybe_put_var("first", Map.get(pagination, :first))
        |> maybe_put_var("last", Map.get(pagination, :last))
        |> maybe_put_var("after", Map.get(pagination, :after))
        |> maybe_put_var("before", Map.get(pagination, :before))

      case Helpers.run_query(@feed_query, current_user, variables) do
        {:ok, %{data: %{feed: %{edges: edges} = connection}}} when is_list(edges) ->
          items =
            edges
            |> Enum.map(&get_field(&1, :node))
            |> Enum.reject(&is_nil/1)
            |> map_timeline_statuses(current_user)

          {:ok, items, feed_page_info(items, connection)}

        {:ok, %{errors: errors}} ->
          {:error, errors}

        _ ->
          {:ok, [], %{}}
      end
    end

    # Build the Link-header page_info from the feed's REAL Paginator cursors (carried back in the
    # connection's pageInfo), not synthesized from object ids — so `max_id`/`min_id` round-trip
    # correctly for every feed ordering (profile/custom sorts), not just [id: :desc] feeds.
    # `encode_cursor_for_link_header` passes the Paginator cursor ("g3…") through unchanged.
    defp feed_page_info(items, connection) do
      pi = get_field(connection, :page_info) || %{}
      end_cursor = get_field(pi, :end_cursor)
      start_cursor = get_field(pi, :start_cursor)

      %{
        start_cursor: start_cursor,
        end_cursor: end_cursor,
        # fall back to item ids only if the connection didn't carry cursors
        cursor_fields: [id: :desc],
        # suppress the "next" link on the last page
        final_cursor: if(get_field(pi, :has_next_page), do: nil, else: end_cursor || :last)
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> maybe_fallback_cursors(items)
    end

    # Favourites page by when each post was liked, so only the likes' own cursors fit the Link: a post's id in their place asks for the wrong likes (`prev` from page 1 brought the newest favourites back). No fallback to item ids, here or in `add_link_headers/5`: a missing cursor means no link
    defp favourites_page_info(statuses, connection) do
      pi = get_field(connection, :page_info) || %{}
      end_cursor = get_field(pi, :end_cursor)

      %{
        start_cursor: get_field(pi, :start_cursor),
        end_cursor: end_cursor,
        cursor_fields: [id: :desc],
        final_cursor: if(get_field(pi, :has_next_page) && end_cursor, do: nil, else: :last),
        cursor_for_record_fun: fn _status -> nil end
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> then(fn page_info -> if statuses == [], do: %{}, else: page_info end)
    end

    # If the feed connection carried no cursors (e.g. empty page_info), fall back to item ids so
    # add_link_headers still produces a (best-effort) Link header.
    defp maybe_fallback_cursors(%{end_cursor: _} = page_info, _items), do: page_info

    defp maybe_fallback_cursors(page_info, items) do
      ids = items |> Enum.map(&get_field(&1, :id)) |> Enum.reject(&is_nil/1)

      page_info
      |> Map.put(:start_cursor, List.first(ids))
      |> Map.put(:end_cursor, List.last(ids))
    end

    def notifications(params, conn) do
      current_user = conn.assigns[:current_user]
      notification_filters = extract_notification_filters(conn.params)

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        current_user
        |> Bonfire.Social.API.GraphQLMasto.Notifications.list_for_user(params,
          filters: notification_filters
        )
        |> notification_candidates_to_items(current_user)
        |> then(&respond_with_feed(conn, params, &1))
      end
    end

    @doc "Mastodon's NotificationPolicy: Bonfire filters no notifications, so every kind is accepted and nothing waits (masto-live-fixes decision 3). `:v1` is Mastodon 4.3's shape (booleans), `:v2` 4.4's (`for_*`)."
    def notification_policy(conn, version \\ :v2) do
      if is_nil(conn.assigns[:current_user]) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        Phoenix.Controller.json(conn, notification_policy_body(version))
      end
    end

    @nothing_waits %{"pending_requests_count" => 0, "pending_notifications_count" => 0}

    # false: not filtered
    defp notification_policy_body(:v1) do
      %{
        "filter_not_following" => false,
        "filter_not_followers" => false,
        "filter_new_accounts" => false,
        "filter_private_mentions" => false,
        "summary" => @nothing_waits
      }
    end

    defp notification_policy_body(:v2) do
      %{
        "for_not_following" => "accept",
        "for_not_followers" => "accept",
        "for_new_accounts" => "accept",
        "for_private_mentions" => "accept",
        "for_limited_accounts" => "accept",
        "summary" => @nothing_waits
      }
    end

    @unread_count_query "query ($limit: Int) { count: unseenNotificationsCount(limit: $limit) }"

    @doc "Mastodon's unread notifications count, read through GraphQL (masto-live-fixes decision 5), counted no further than `limit` as Mastodon does (default 100, at most 1000)."
    def notifications_unread_count(params, conn) do
      current_user = conn.assigns[:current_user]
      limit = PaginationHelpers.validate_limit(params["limit"], default: 100, max: 1000)

      with %{} <- current_user,
           {:ok, %{data: %{count: count}}} when is_integer(count) <-
             Bonfire.API.MastoCompat.Helpers.run_query(@unread_count_query, current_user, %{
               "limit" => limit
             }) do
        Phoenix.Controller.json(conn, %{"count" => count})
      else
        nil -> RestAdapter.error_fn({:error, :unauthorized}, conn)
        other -> RestAdapter.error_fn(other, conn)
      end
    end

    @doc "Maps the existing notification feed's page-local grouping to Mastodon v2."
    def grouped_notifications(params, conn) do
      user = conn.assigns[:current_user]

      cond do
        is_nil(user) ->
          RestAdapter.error_fn({:error, :unauthorized}, conn)

        params["group_key"] ->
          conn
          |> Plug.Conn.put_status(:not_implemented)
          |> Phoenix.Controller.json(%{
            "error" => "Notification group detail lookup is not supported"
          })

        true ->
          filters = extract_notification_filters(params)
          groupable = groupable_masto_types()
          grouped_types = List.wrap(params["grouped_types"] || groupable)

          # with no `types[]`, every type the notification categories declare (`Notifications.masto_types/0`), the same list the query selects by, as Mastodon names them
          types =
            List.wrap(
              params["types"] ||
                Enum.map(
                  Bonfire.Social.Notifications.masto_types(),
                  &Bonfire.API.MastoCompat.Schemas.Notification.type_name/1
                )
            ) -- List.wrap(params["exclude_types"])

          groupable_types = Enum.filter(types, &(&1 in groupable))
          group? = groupable_types != [] and Enum.all?(groupable_types, &(&1 in grouped_types))

          feed_params =
            PaginationHelpers.build_feed_params(params, %{"feed_name" => "notifications"},
              default_limit: 40,
              max_limit: 80
            )

          case Bonfire.Social.API.GraphQLMasto.Notifications.list_for_user(user, feed_params,
                 filters: filters,
                 grouped?: true,
                 group_likes_boosts?: group?
               ) do
            {:ok, candidates, page_info} ->
              by_id = Map.new(candidates, &{&1.id, &1})

              groups =
                candidates
                |> map_notification_candidates(user)
                |> Enum.map(fn item ->
                  candidate = Map.fetch!(by_id, item["id"])
                  actors = get_field(candidate.activity, :subjects_more) || []

                  accounts =
                    actors |> Enum.map(&Mappers.Account.from_user/1) |> Enum.reject(&is_nil/1)

                  count = 1 + length(actors)

                  group = %{
                    "key" =>
                      if(count > 1, do: "page-" <> item["id"], else: "ungrouped-" <> item["id"]),
                    "count" => count,
                    "latest_id" => item["id"]
                  }

                  {group, [item | Enum.map(accounts, &Map.put(item, "account", &1))]}
                end)

              conn
              |> PaginationHelpers.add_link_headers(feed_params, page_info, [])
              |> Phoenix.Controller.json(Mappers.NotificationGroups.from_groups(groups))

            {:error, _} = error ->
              RestAdapter.error_fn(error, conn)
          end
      end
    end

    def notification(id, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case Bonfire.Social.API.GraphQLMasto.Notifications.get_for_user(current_user, id) do
          {:ok, candidate} ->
            notification =
              candidate
              |> List.wrap()
              |> map_notification_candidates(current_user)
              |> List.first()

            if notification do
              Phoenix.Controller.json(conn, notification)
            else
              RestAdapter.error_fn({:error, :not_found}, conn)
            end

          {:error, _} ->
            RestAdapter.error_fn({:error, :not_found}, conn)

          nil ->
            RestAdapter.error_fn({:error, :not_found}, conn)
        end
      end
    end

    @doc "Clear all notifications for the current user"
    def clear_notifications(conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case Bonfire.Social.FeedActivities.mark_all_seen(:notifications,
               current_user: current_user
             ) do
          {:ok, _count} ->
            # Mastodon API returns empty object on success
            Phoenix.Controller.json(conn, %{})

          {:error, reason} ->
            error(reason, "Failed to clear notifications")
            RestAdapter.error_fn({:error, reason}, conn)

          _ ->
            # mark_all_seen may return different formats, treat as success
            Phoenix.Controller.json(conn, %{})
        end
      end
    end

    @doc "Dismiss a single notification"
    def dismiss_notification(id, conn) do
      current_user = conn.assigns[:current_user]

      cond do
        is_nil(current_user) ->
          RestAdapter.error_fn({:error, :unauthorized}, conn)

        # being in the reader's notification feeds is the authorization: a like or boost notification is the edge, which the boundary read hides from the post's author, so the id is marked as a map to skip it, as `Markers` does
        not Bonfire.Social.Notifications.published_to?(current_user, id) ->
          RestAdapter.error_fn({:error, :not_found}, conn)

        true ->
          case Bonfire.Social.Seen.mark_seen(conn.assigns, %{id: id}) do
            {:ok, _} ->
              # Mastodon API returns empty object on success
              Phoenix.Controller.json(conn, %{})

            {:error, reason} ->
              error(reason, "Failed to dismiss notification")
              RestAdapter.error_fn({:error, reason}, conn)

            _ ->
              # mark_seen may return different formats, treat as success
              Phoenix.Controller.json(conn, %{})
          end
      end
    end

    defp extract_notification_filters(params) do
      %{
        types: extract_types_filter(params["types"]) || extract_types_filter(params["types[]"]),
        exclude_types:
          extract_types_filter(params["exclude_types"]) ||
            extract_types_filter(params["exclude_types[]"]),
        account_id: params["account_id"]
      }
    end

    # what collapses into one group is what the notification categories declare `aggregate:`, as Mastodon names them, the same kinds the web collapses into one row
    defp groupable_masto_types do
      Bonfire.Social.Notifications.aggregated_categories()
      |> Enum.flat_map(fn {key, _category} ->
        Bonfire.Social.Notifications.masto_types_of(key)
      end)
      |> Enum.map(&Bonfire.API.MastoCompat.Schemas.Notification.type_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end

    defp extract_types_filter(nil), do: nil
    defp extract_types_filter(types) when is_list(types), do: types
    defp extract_types_filter(types) when is_binary(types), do: [types]
    defp extract_types_filter(_), do: nil

    defp notification_candidates_to_items({:ok, candidates, page_info}, current_user) do
      {:ok, map_notification_candidates(candidates, current_user), page_info}
    end

    defp notification_candidates_to_items({:error, _} = error, _current_user), do: error

    # Each status is built from what the notifications query already returned, so a page costs the same whatever number of statuses it holds
    defp map_notification_candidates(candidates, current_user) do
      Enum.flat_map(candidates, fn candidate ->
        case Mappers.Notification.from_candidate(candidate, current_user: current_user) do
          # a notification about a status is nothing to a client without it
          item when is_map(item) ->
            if is_nil(notification_status_id(candidate)) or is_map(item["status"]),
              do: [item],
              else: []

          _ ->
            []
        end
      end)
    end

    defp notification_status_id(%{type: :quote, status_post: post}), do: get_field(post, :id)

    # the kinds whose notification carries the post it is about: a `status` (a new post the reader asked to hear about) is nothing to a client without it
    defp notification_status_id(%{type: type, object_id: id})
         when type in [:mention, :status, :reblog, :favourite],
         do: id

    defp notification_status_id(_), do: nil

    @doc "Get posts favourited/liked by the current user"
    def favourites(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        params
        |> favourite_items(current_user)
        |> then(&respond_with_feed(conn, params, &1))
      end
    end

    @doc "Get posts bookmarked by the current user, most recently bookmarked first"
    def bookmarks(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        params
        |> bookmark_items(current_user)
        |> then(&respond_with_feed(conn, params, &1))
      end
    end

    # Post-shaped node selection (favourites). Snake_case aliases so the shared Status builders
    # read them. TODO(graphql-fix): only `... on Post` is selected — non-Post liked objects
    # (polls/Question, media) are stripped; extend to all object types.
    @status_node_selection """
    id
    #{@status_post_content}
    #{@status_media}
    activity {
      subject { #{@author_fields} }
      context { ... on Category { id } }
      mentions { #{@actor_fields} }
      hashtags { id name }
      visibility
      #{@object_interactions}
      replies_count: repliesCount
    like_count: likeCount
    boost_count: boostCount
    #{@thread_fields}
    }
    """

    @favourites_query """
    query Favourites($first: Int, $last: Int, $after: String, $before: String) {
      my_likes: myLikes(first: $first, last: $last, after: $after, before: $before) {
        page_info: pageInfo { start_cursor: startCursor end_cursor: endCursor has_next_page: hasNextPage }
        edges { node { #{@status_node_selection} } }
      }
    }
    """

    @bookmarks_query """
    query Bookmarks($first: Int, $last: Int, $after: String, $before: String) {
      my_bookmarks: myBookmarks(first: $first, last: $last, after: $after, before: $before) {
        page_info: pageInfo { start_cursor: startCursor end_cursor: endCursor has_next_page: hasNextPage }
        edges { node { #{@activity_node_selection} } }
      }
    }
    """

    @status_query """
    query Status($id: ID!) {
      status(id: $id) { #{@activity_node_selection} }
    }
    """

    @statuses_query """
    query Statuses($ids: [ID!]!) {
      statuses(ids: $ids) { #{@activity_node_selection} }
    }
    """

    # Parked, no callers: notifications and timeline reactions now build each status from the page's own query (`Mappers.Status.from_activity_object/2`) instead of re-reading it, which cost one `status(id:)` root resolution per status.
    # defp read_statuses_by_id([], _current_user), do: %{}
    #
    # defp read_statuses_by_id(ids, current_user) do
    #   indexed = Enum.with_index(ids)
    #   declarations = Enum.map_join(indexed, ", ", fn {_, index} -> "$id#{index}: ID!" end)
    #
    #   selections =
    #     Enum.map_join(indexed, "\n", fn {_, index} ->
    #       "s#{index}: status(id: $id#{index}) { #{@activity_node_selection} }"
    #     end)
    #
    #   variables = Map.new(indexed, fn {id, index} -> {"id#{index}", id} end)
    #
    #   case Absinthe.run("query NotificationStatuses(#{declarations}) { #{selections} }", Schema,
    #          variables: variables,
    #          context: Schema.context(%{current_user: current_user})
    #        ) do
    #     {:ok, %{data: data}} when is_map(data) ->
    #       data
    #       |> Map.values()
    #       |> Enum.filter(&is_map/1)
    #       |> map_graphql_statuses(current_user, &Mappers.Status.from_graphql_activity/2)
    #       |> Map.new(&{Map.fetch!(&1, "id"), &1})
    #
    #     _ ->
    #       %{}
    #   end
    # end

    # Every status comes from what the feed query returned, completed by the page's batch loads, so a page costs the same whatever its size. A boost renders as a reblog wrapping its post (`Mappers.Status`). Timelines no longer hold likes, votes or edits, which were rendered as the post they are about
    defp map_timeline_statuses(nodes, current_user),
      do: map_graphql_statuses(nodes, current_user, &Mappers.Status.from_graphql_activity/2)

    defp favourite_items(params, current_user) do
      pagination_args =
        case Map.take(params, [:first, :last, :after, :before]) do
          empty when map_size(empty) == 0 -> %{first: 20}
          args -> args
        end

      variables =
        %{}
        |> maybe_put_var("first", Map.get(pagination_args, :first))
        |> maybe_put_var("last", Map.get(pagination_args, :last))
        |> maybe_put_var("after", Map.get(pagination_args, :after))
        |> maybe_put_var("before", Map.get(pagination_args, :before))

      case Helpers.run_query(@favourites_query, current_user, variables) do
        {:ok, %{data: %{my_likes: %{edges: edges} = connection}}} when is_list(edges) ->
          statuses =
            edges
            |> Enum.map(&get_field(&1, :node))
            |> Enum.reject(&is_nil/1)
            |> map_graphql_statuses(current_user)

          {:ok, statuses, favourites_page_info(statuses, connection)}

        {:ok, %{errors: errors}} ->
          {:error, errors}

        _ ->
          {:ok, [], %{}}
      end
    end

    # as `favourite_items/2`, paged by bookmark; nodes are activities, mapped as timelines
    defp bookmark_items(params, current_user) do
      pagination_args =
        case Map.take(params, [:first, :last, :after, :before]) do
          empty when map_size(empty) == 0 -> %{first: 20}
          args -> args
        end

      variables =
        %{}
        |> maybe_put_var("first", Map.get(pagination_args, :first))
        |> maybe_put_var("last", Map.get(pagination_args, :last))
        |> maybe_put_var("after", Map.get(pagination_args, :after))
        |> maybe_put_var("before", Map.get(pagination_args, :before))

      case Helpers.run_query(@bookmarks_query, current_user, variables) do
        {:ok, %{data: %{my_bookmarks: %{edges: edges} = connection}}} when is_list(edges) ->
          statuses =
            edges
            |> Enum.map(&get_field(&1, :node))
            |> Enum.reject(&is_nil/1)
            |> map_timeline_statuses(current_user)

          {:ok, statuses, favourites_page_info(statuses, connection)}

        {:ok, %{errors: errors}} ->
          {:error, errors}

        _ ->
          {:ok, [], %{}}
      end
    end

    defp maybe_put_var(map, _key, nil), do: map
    defp maybe_put_var(map, key, value), do: Map.put(map, key, value)

    # GraphQL nodes to Mastodon statuses: each node carries all its status needs, so the mapper reads nothing else; a discover-only post comes redacted, without mentions
    defp map_graphql_statuses(nodes, current_user, mapper \\ &Mappers.Status.from_graphql/2)
         when is_list(nodes) do
      Enum.flat_map(nodes, fn node ->
        case mapper.(node, current_user: current_user) do
          status when is_map(status) -> [status]
          _ -> []
        end
      end)
    end

    @doc "Get single status by ID"
    def show_status(%{"id" => id}, conn) do
      case read_status(id, conn.assigns[:current_user]) do
        {:ok, status} -> Phoenix.Controller.json(conn, status)
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    @doc "Reads a Mastodon status through GraphQL, shared by GET and interaction responses."
    def read_status(id, current_user) do
      result = Helpers.run_query(@status_query, current_user, %{"id" => id})

      with {:ok, %{data: %{status: node}}} when is_map(node) <- result,
           [status] <-
             map_graphql_statuses([node], current_user, &Mappers.Status.from_graphql_activity/2),
           true <- is_map(status) and not is_nil(Map.get(status, "id")) do
        {:ok, status}
      else
        _ -> {:error, :not_found}
      end
    end

    @doc "Reads Mastodon statuses by object id through GraphQL (`statuses(ids:)`) in one run, in the order given; those the viewer may not read are left out."
    def read_statuses([], _current_user), do: []

    def read_statuses(ids, current_user) do
      case Helpers.run_query(@statuses_query, current_user, %{"ids" => ids}) do
        {:ok, %{data: %{statuses: nodes}}} when is_list(nodes) ->
          map_graphql_statuses(nodes, current_user, &Mappers.Status.from_graphql_activity/2)

        _ ->
          []
      end
    end

    @published_status_query """
    subscription PublishedStatus {
      feed_activity: feedActivity { #{@activity_node_selection} }
    }
    """

    @doc "A streamed activity as a Mastodon status, through the selection a timeline uses, run with the activity as root (`Helpers.run_published/4`); nil if it maps to nothing."
    def published_status(activity, current_user) do
      with {:ok, %{data: %{feed_activity: %{} = node}}} <-
             Helpers.run_published(@published_status_query, activity, current_user),
           [status] <- map_timeline_statuses([node], current_user) do
        status
      else
        _ -> nil
      end
    end

    @doc "Get the source (raw text) of a status for editing"
    def status_source(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case load_editable_post_content(id, current_user) do
          {:ok, post_content} ->
            source = %{
              "id" => id,
              "text" => Map.get(post_content, :html_body) || "",
              "spoiler_text" => Map.get(post_content, :summary) || ""
            }

            Phoenix.Controller.json(conn, source)

          _ ->
            RestAdapter.error_fn({:error, :not_found}, conn)
        end
      end
    end

    defp load_editable_post_content(id, current_user) do
      with %Bonfire.Data.Social.PostContent{} = post_content <-
             Bonfire.Boundaries.load_pointer(id,
               verbs: [:edit],
               from: Bonfire.Social.PostContents.query_base(),
               current_user: current_user
             ) do
        {:ok, post_content}
      end
    end

    @doc "Edit a status. Like Mastodon's update service, a blank body falls back to the submitted warning as text, and the warning is always replaced by the submitted value (or cleared when omitted)."
    def update_status(%{"id" => id} = params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        status = params["status"]
        spoiler_text = params["spoiler_text"]

        body =
          if is_nil(status) or (is_binary(status) and String.trim(status) == ""),
            do: spoiler_text,
            else: status

        attrs = %{html_body: body, summary: spoiler_text}

        case edit_post_content(current_user, id, attrs) do
          {:ok, _} ->
            # Reload through GraphQL, as show does.
            # Kept outside the rescue: a post-commit reload/map crash must not be
            # reported as :not_found (the edit already succeeded).
            case read_status(id, current_user) do
              {:ok, status} -> Phoenix.Controller.json(conn, status)
              _ -> RestAdapter.error_fn({:error, :not_found}, conn)
            end

          {:error, :not_found} ->
            RestAdapter.error_fn({:error, :not_found}, conn)

          {:error, %Ecto.Changeset{}} = error ->
            RestAdapter.error_fn(error, conn)

          {:error, _reason} ->
            RestAdapter.error_fn({:error, :forbidden}, conn)
        end
      end
    end

    # Scope the rescue to only the edit call so unexpected exceptions there map to
    # :not_found/:forbidden, while the reload+map path can surface its own failures.
    defp edit_post_content(current_user, id, attrs) do
      with %{} = post <-
             Bonfire.Boundaries.load_pointer(id, verbs: [:edit], current_user: current_user),
           post = repo().maybe_preload(post, [:post_content, :media]),
           %Bonfire.Data.Social.PostContent{} = content <- post.post_content,
           changeset = Bonfire.Data.Social.PostContent.changeset(content, attrs),
           changeset =
             if(post.media == [],
               do: Ecto.Changeset.validate_required(changeset, [:html_body]),
               else: changeset
             ),
           {:ok, _} <- Ecto.Changeset.apply_action(changeset, :update) do
        Bonfire.Social.PostContents.edit(current_user, content, attrs)
      else
        {:error, _} = error ->
          error

        _ ->
          {:error, :not_found}
      end
    rescue
      e ->
        error(e, "Failed to edit status")
        {:error, :not_found}
    end

    @doc "Delete a status owned by the caller, as required by the Mastodon endpoint."
    def delete_status(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        with %{id: creator_id} <- Bonfire.Social.Objects.object_creator(id),
             true <- creator_id == current_user.id,
             {:ok, _} <- Bonfire.Social.Objects.delete(id, current_user: current_user) do
          Phoenix.Controller.json(conn, %{"id" => id})
        else
          {:error, :not_found} ->
            RestAdapter.error_fn({:error, :not_found}, conn)

          {:error, :unauthorized} ->
            RestAdapter.error_fn({:error, :unauthorized}, conn)

          {:error, reason} ->
            error(reason, "Failed to delete status")
            RestAdapter.error_fn({:error, reason}, conn)

          _ ->
            RestAdapter.error_fn({:error, :not_found}, conn)
        end
      end
    end

    @doc "Get thread context (ancestors and descendants)"
    def status_context(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      # root, ancestors (root-first) and descendants read in one GraphQL run; `statuses(ids:)` leaves out what the viewer may not read
      ancestor_ids = ancestor_ids(id, [], 0)
      descendant_ids = descendant_reply_ids(id)

      by_id =
        (ancestor_ids ++ [id] ++ descendant_ids)
        |> read_statuses(current_user)
        |> Map.new(&{&1["id"], &1})

      # The root status must itself be readable; otherwise 404 (don't leak an empty
      # context for a private/non-existent status).
      if Map.has_key?(by_id, id) do
        Phoenix.Controller.json(conn, %{
          "ancestors" => pick_statuses(ancestor_ids, by_id),
          "descendants" => pick_statuses(descendant_ids, by_id)
        })
      else
        RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    defp pick_statuses(ids, by_id), do: Enum.flat_map(ids, &List.wrap(by_id[&1]))

    defp ancestor_ids(_id, acc, depth) when depth > 80, do: acc

    defp ancestor_ids(id, acc, depth) do
      parent_id =
        repo().one(
          from(r in Bonfire.Data.Social.Replied, where: r.id == ^id, select: r.reply_to_id)
        )

      if is_binary(parent_id) and parent_id != id do
        ancestor_ids(parent_id, [parent_id | acc], depth + 1)
      else
        acc
      end
    end

    defp descendant_reply_ids(id) do
      uuid = EctoMaterializedPath.UIDs.dump_one(id)
      path_ids = if is_binary(uuid), do: [uuid], else: []

      from(
        replied in Bonfire.Data.Social.Replied,
        where:
          replied.id != ^id and
            (replied.reply_to_id == ^id or replied.thread_id == ^id or
               fragment("? @> ?", replied.path, type(^path_ids, {:array, Ecto.UUID}))),
        order_by: [asc: replied.id],
        limit: 80,
        select: replied.id
      )
      |> repo().many()
    end

    def status_favourited_by(%{"id" => id}, conn) do
      list_status_interactors(conn, :like, id)
    end

    def status_reblogged_by(%{"id" => id}, conn) do
      list_status_interactors(conn, :boost, id)
    end

    @likers_query """
    query ($id: ID!) { likers_of: likersOf(id: $id) { #{Bonfire.API.MastoCompat.Fragments.account_fields()} } }
    """
    @boosters_query """
    query ($id: ID!) { boosters_of: boostersOf(id: $id) { #{Bonfire.API.MastoCompat.Fragments.account_fields()} } }
    """

    defp list_status_interactors(conn, interaction_type, id) do
      {query, field} =
        case interaction_type do
          :like -> {@likers_query, :likers_of}
          :boost -> {@boosters_query, :boosters_of}
        end

      case Helpers.run_query(query, conn.assigns[:current_user], %{"id" => id}) do
        {:ok, %{data: %{^field => users}}} when is_list(users) ->
          accounts = users |> Enum.map(&Mappers.Account.from_user/1) |> Enum.reject(&is_nil/1)
          Phoenix.Controller.json(conn, accounts)

        {:ok, %{errors: [_ | _] = errors}} ->
          RestAdapter.error_fn({:error, errors}, conn)

        {:error, _} = error ->
          RestAdapter.error_fn(error, conn)

        _ ->
          Phoenix.Controller.json(conn, [])
      end
    end

    defp respond_with_feed(conn, params, {:ok, items, page_info}) do
      conn
      |> PaginationHelpers.add_link_headers(params, page_info, items)
      |> Phoenix.Controller.json(items)
    end

    defp respond_with_feed(conn, _params, {:error, errors}) do
      RestAdapter.error_fn(errors, conn)
    end

    defp respond_with_feed(conn, _params, other) do
      warn(other, "respond_with_feed received unexpected format, returning empty array")
      Phoenix.Controller.json(conn, [])
    end

    def like_status(%{"id" => id}, conn) do
      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :like,
        context_fn: &Bonfire.Social.Likes.like/2,
        flag: "favourited",
        flag_value: true
      )
    end

    def unlike_status(%{"id" => id}, conn) do
      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :unlike,
        context_fn: &Bonfire.Social.Likes.unlike/2,
        flag: "favourited",
        flag_value: false
      )
    end

    def boost_status(%{"id" => id}, conn) do
      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :boost,
        context_fn: &Bonfire.Social.Boosts.boost/2,
        flag: "reblogged",
        flag_value: true
      )
    end

    def unboost_status(%{"id" => id}, conn) do
      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :unboost,
        context_fn: &Bonfire.Social.Boosts.unboost/2,
        flag: "reblogged",
        flag_value: false
      )
    end

    def bookmark_status(%{"id" => id}, conn) do
      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :bookmark,
        context_fn: &Bonfire.Social.Bookmarks.bookmark/2,
        flag: "bookmarked",
        flag_value: true
      )
    end

    def unbookmark_status(%{"id" => id}, conn) do
      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :unbookmark,
        context_fn: &Bonfire.Social.Bookmarks.unbookmark/2,
        flag: "bookmarked",
        flag_value: false
      )
    end

    def pin_status(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        result = pin_owned_status(current_user, id)

        case result do
          {:ok, _pin} ->
            fetch_and_respond_with_pin_state(conn, current_user, id, true)

          {:error, reason} ->
            error(reason, "pin_status error")
            pin_error(conn, reason)
        end
      end
    end

    defp pin_error(conn, :not_owned) do
      conn
      |> Plug.Conn.put_status(422)
      |> Phoenix.Controller.json(%{"error" => "Status is not owned by you"})
    end

    defp pin_error(conn, reason), do: RestAdapter.error_fn({:error, reason}, conn)

    defp pin_owned_status(current_user, id) do
      with {:ok, object} <- Bonfire.Social.Objects.read(id, current_user: current_user),
           true <- Bonfire.Boundaries.can?(current_user, :edit, object) do
        # Wrap in try/rescue to handle federation errors gracefully.
        # The pin creation may succeed but federation may fail.
        try do
          Bonfire.Social.Pins.pin(current_user, object)
        rescue
          e in RuntimeError ->
            if Bonfire.Social.Pins.pinned?(current_user, object) do
              {:ok, :already_pinned}
            else
              {:error, e.message}
            end
        end
      else
        false -> {:error, :not_owned}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :not_found}
      end
    end

    def unpin_status(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case Bonfire.Social.Pins.unpin(current_user, id) do
          {:ok, _} ->
            fetch_and_respond_with_pin_state(conn, current_user, id, false)

          _ ->
            # Unpin is idempotent - still return success
            fetch_and_respond_with_pin_state(conn, current_user, id, false)
        end
      end
    end

    defp fetch_and_respond_with_pin_state(conn, current_user, id, pinned_value) do
      case read_status(id, current_user) do
        {:ok, status} -> Phoenix.Controller.json(conn, Map.put(status, "pinned", pinned_value))
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    @doc "Search for statuses/posts, called by the Search adapter."
    def search_statuses_for_api(query, opts, _conn) do
      current_user = opts[:current_user]

      query
      |> search_status_ids(opts)
      |> read_statuses(current_user)
    end

    # Search the public index (where discoverable Posts are indexed — same index the web UI
    # search uses; the `:closed` index only holds boundary-restricted content) and return their
    # object ids. Returns [] for an empty query or any backend failure.
    defp search_status_ids(query, opts) do
      query = to_string(query)

      if query == "" do
        []
      else
        Bonfire.Search.search(
          query,
          %{
            index: :public,
            limit: opts[:limit] || 20,
            offset: opts[:offset] || 0,
            current_user: opts[:current_user]
          },
          [],
          %{"index_type" => ["Bonfire.Data.Social.Post"]}
        )
        |> case do
          %{hits: hits} when is_list(hits) ->
            hits |> Enum.map(&Bonfire.Common.Enums.id/1) |> Enum.reject(&is_nil/1)

          _ ->
            []
        end
      end
    rescue
      e ->
        error(e, "Search statuses failed")
        []
    end

    # ============================================
    # Reports API (Mastodon-compatible)
    # ============================================

    alias Bonfire.Social.Flags

    @doc """
    Create a new report (flag).

    Implements POST /api/v1/reports
    """
    def create_report(params, conn) do
      current_user = conn.assigns[:current_user]

      with {:ok, current_user} <- require_user(current_user),
           {:ok, account_id} <- require_param(params, "account_id"),
           flagged_id <- get_flagged_id(params, account_id),
           opts <- build_flag_opts(params),
           {:ok, flag} <- Flags.flag(current_user, flagged_id, opts) do
        flag = preload_flag_for_api(flag)
        report = Mappers.Report.from_flag(flag, report_opts([flag], current_user))

        if report do
          RestAdapter.json(conn, report)
        else
          RestAdapter.error_fn({:error, "Failed to create report"}, conn)
        end
      else
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    @doc """
    List reports created by the current user.

    Implements GET /api/v1/reports
    """
    def list_reports(_params, conn) do
      current_user = conn.assigns[:current_user]

      with {:ok, current_user} <- require_user(current_user) do
        result =
          Flags.list_by(current_user,
            current_user: current_user,
            paginate?: false,
            skip_boundary_check: true
          )

        flags = extract_flags(result)

        flags = Enum.map(flags, &preload_flag_for_api/1)
        opts = report_opts(flags, current_user)

        reports =
          flags
          |> Enum.map(&Mappers.Report.from_flag(&1, opts))
          |> Enum.reject(&is_nil/1)

        RestAdapter.json(conn, reports)
      else
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    @doc """
    Get a specific report by ID.

    Implements GET /api/v1/reports/:id
    """
    def show_report(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      with {:ok, current_user} <- require_user(current_user),
           {:ok, flag} <- get_flag_by_id(id, current_user) do
        flag = preload_flag_for_api(flag)
        report = Mappers.Report.from_flag(flag, report_opts([flag], current_user))

        if report do
          RestAdapter.json(conn, report)
        else
          RestAdapter.error_fn({:error, :not_found}, conn)
        end
      else
        {:error, reason} -> RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    # Report helper functions

    defp require_user(nil), do: {:error, :unauthorized}
    defp require_user(user), do: {:ok, user}

    defp require_param(params, key) do
      case params[key] do
        nil -> {:error, "#{key} is required"}
        "" -> {:error, "#{key} is required"}
        value -> {:ok, value}
      end
    end

    defp get_flagged_id(params, account_id) do
      status_ids = params["status_ids"] || []
      List.first(status_ids) || account_id
    end

    defp build_flag_opts(params) do
      opts = [forward: false]

      opts =
        case params["comment"] do
          comment when is_binary(comment) and comment != "" ->
            Keyword.put(opts, :comment, String.slice(comment, 0, 1000))

          _ ->
            opts
        end

      if params["forward"] in [true, "true"] do
        Keyword.put(opts, :forward, true)
      else
        opts
      end
    end

    defp extract_flags(result) do
      case result do
        %{edges: edges} when is_list(edges) -> edges
        flags when is_list(flags) -> flags
        _ -> []
      end
    end

    defp get_flag_by_id(id, current_user) do
      if Bonfire.Common.Types.is_uid?(id) do
        Flags.query([id: id, subjects: current_user], skip_boundary_check: true)
        |> repo().single()
        |> case do
          {:ok, flag} -> {:ok, flag}
          _ -> {:error, :not_found}
        end
      else
        {:error, :not_found}
      end
    end

    defp report_opts(flags, current_user) do
      [
        current_user: current_user,
        accounts_by_id:
          flags
          |> Enum.map(&Mappers.Report.target_user_id/1)
          |> Bonfire.API.MastoCompat.Accounts.by_ids(current_user)
      ]
    end

    defp preload_flag_for_api(flag) do
      repo().maybe_preload(
        flag,
        [:named, edge: [:object]],
        follow_pointers: true
      )
      |> then(fn flag ->
        case get_in(flag, [Access.key(:edge), Access.key(:object)]) do
          nil ->
            flag

          object ->
            object =
              repo().maybe_preload(
                object,
                [:profile, :character, created: [creator: [:profile, :character]]],
                follow_pointers: true
              )

            put_in(flag, [Access.key(:edge), Access.key(:object)], object)
        end
      end)
    end

    @doc "Get pinned statuses for a user"
    def pinned_statuses(user_id, params, conn) do
      current_user = conn.assigns[:current_user]
      # Mastodon status lists cap at 40
      limit = PaginationHelpers.validate_limit(params["limit"] || 20, max: 40)

      case Bonfire.Social.Pins.list_by(user_id, limit: limit) do
        %{edges: edges} when is_list(edges) ->
          # read as the viewer: a pin they may not read is left out
          statuses =
            edges
            |> Enum.map(&(get_field(&1, :edge) |> get_field(:object_id)))
            |> Enum.reject(&is_nil/1)
            # `pinned` comes from `pinnedByMe`: true only for the reader's own pins
            |> read_statuses(current_user)

          Phoenix.Controller.json(conn, statuses)

        _ ->
          Phoenix.Controller.json(conn, [])
      end
    end
  end
end
