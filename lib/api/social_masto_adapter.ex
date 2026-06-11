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
    alias Bonfire.API.GraphQL.Schema

    alias Bonfire.API.MastoCompat.{
      Mappers,
      InteractionHandler,
      Helpers,
      PaginationHelpers,
      FeedPipeline,
      BatchLoaders
    }

    import Helpers, only: [get_field: 2]

    # Actor (subject/creator/author) fields, shared with the notifications module — covers User
    # AND Category (groups), without which group-authored activities resolve to an untyped actor
    # and get dropped on validation. See `Bonfire.API.MastoCompat.Fragments.actor_fields/0`.
    @actor_fields Bonfire.API.MastoCompat.Fragments.actor_fields()

    # Activity-shaped selection for timelines (handles boosts → reblog). The reblog account
    # comes from `object.creator` — the `:post.creator` field resolves synchronously from the
    # `:with_creator`-preloaded `created.creator`, avoiding the deep `object.activity.subject`
    # Dataloader rounds that made an earlier cut ~2× slower (now ~1.08× direct, within gate).
    # (Defined before feed_items: module attributes must be set before the interpolating fn.)
    @activity_node_selection """
    id
    object_id: objectId
    verb { verb }
    subject { #{@actor_fields} }
    object {
      __typename
      ... on Post {
        id
        post_content: postContent { name summary html_body: rawBody }
        media { id media_type: mediaType url description metadata }
        creator { #{@actor_fields} }
      }
      ... on Poll { id post_content: postContent { name summary html_body: rawBody } }
    }
    media { id media_type: mediaType url description metadata }
    liked_by_me: likedByMe
    boosted_by_me: boostedByMe
    bookmarked_by_me: bookmarkedByMe
    replies_count: repliesCount
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

      case Absinthe.run(@feed_query, Schema,
             variables: variables,
             context: Schema.context(%{current_user: current_user})
           ) do
        {:ok, %{data: %{"feed" => %{"edges" => edges} = connection}}} when is_list(edges) ->
          items =
            edges
            |> Enum.map(&get_field(&1, :node))
            |> Enum.reject(&is_nil/1)
            |> map_graphql_statuses(current_user, &Mappers.Status.from_graphql_activity/2)

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

    @doc "Get a single notification by ID"
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

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case Bonfire.Social.Seen.mark_seen(current_user, id) do
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

    defp extract_types_filter(nil), do: nil
    defp extract_types_filter(types) when is_list(types), do: types
    defp extract_types_filter(types) when is_binary(types), do: [types]
    defp extract_types_filter(_), do: nil

    defp notification_candidates_to_items({:ok, candidates, page_info}, current_user) do
      {:ok, map_notification_candidates(candidates, current_user), page_info}
    end

    defp notification_candidates_to_items({:error, _} = error, _current_user), do: error

    defp map_notification_candidates(candidates, current_user) do
      candidates
      |> Enum.flat_map(fn candidate ->
        case Mappers.Notification.from_candidate(candidate, current_user: current_user) do
          item when is_map(item) -> [item]
          _ -> []
        end
      end)
    end

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

    # Post-shaped node selection (favourites). Snake_case aliases so the shared Status builders
    # read them. TODO(graphql-fix): only `... on Post` is selected — non-Post liked objects
    # (polls/Question, media) are stripped; extend to all object types.
    @status_node_selection """
    id
    post_content: postContent { name summary html_body: rawBody }
    media { id media_type: mediaType url description metadata }
    activity {
      subject { #{@actor_fields} }
      liked_by_me: likedByMe
      boosted_by_me: boostedByMe
      bookmarked_by_me: bookmarkedByMe
      replies_count: repliesCount
    }
    """

    @favourites_query """
    query Favourites($first: Int, $last: Int, $after: String, $before: String) {
      my_likes: myLikes(first: $first, last: $last, after: $after, before: $before) {
        page_info: pageInfo { has_next_page: hasNextPage }
        edges { node { #{@status_node_selection} } }
      }
    }
    """

    # Lean activity selection for a SINGLE status (a regular post or a poll — never a reblog
    # wrapper, so no boost `object.activity` nesting). The `... on Poll` fragment carries the
    # __typename + content for detection; `Mappers.Status.maybe_add_poll` loads the full Question.
    @status_activity_selection """
    id
    object_id: objectId
    verb { verb }
    subject { #{@actor_fields} }
    object { __typename ... on Post { id post_content: postContent { name summary html_body: rawBody } } ... on Poll { id post_content: postContent { name summary html_body: rawBody } } }
    media { id media_type: mediaType url description metadata }
    liked_by_me: likedByMe
    boosted_by_me: boostedByMe
    bookmarked_by_me: bookmarkedByMe
    replies_count: repliesCount
    """

    @status_query """
    query Status($id: ID!) {
      status(id: $id) { #{@status_activity_selection} }
    }
    """

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

      case Absinthe.run(@favourites_query, Schema,
             variables: variables,
             context: Schema.context(%{current_user: current_user})
           ) do
        {:ok, %{data: %{"my_likes" => %{"edges" => edges} = connection}}} when is_list(edges) ->
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

    defp favourites_page_info([], _connection), do: %{}

    defp favourites_page_info(statuses, connection) do
      ids = statuses |> Enum.map(&get_field(&1, :id)) |> Enum.reject(&is_nil/1)
      has_next_page = get_field(connection, :page_info) |> get_field(:has_next_page)

      %{
        start_cursor: List.first(ids),
        end_cursor: List.last(ids),
        cursor_fields: [id: :desc],
        final_cursor: if(has_next_page, do: nil, else: List.last(ids))
      }
    end

    defp maybe_put_var(map, _key, nil), do: map
    defp maybe_put_var(map, key, value), do: Map.put(map, key, value)

    # GraphQL `:post`/`:activity` node maps → Mastodon statuses: GraphQL provides the core node;
    # BatchLoaders supplies hashtags/mentions/visibility (keyed by object id).
    defp map_graphql_statuses(nodes, current_user, mapper \\ &Mappers.Status.from_graphql/2)
         when is_list(nodes) do
      object_ids =
        nodes
        |> Enum.map(&(get_field(&1, :object_id) || get_field(&1, :id)))
        |> Enum.reject(&is_nil/1)

      batch_opts = batch_load_supplementary(current_user, object_ids)

      Enum.flat_map(nodes, fn node ->
        case mapper.(node, batch_opts) do
          status when is_map(status) -> [status]
          _ -> []
        end
      end)
    end

    @doc "Get single status by ID"
    def show_status(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      result =
        Absinthe.run(@status_query, Schema,
          variables: %{"id" => id},
          context: Schema.context(%{current_user: current_user})
        )

      with {:ok, %{data: %{"status" => node}}} when is_map(node) <- result,
           [status] <-
             map_graphql_statuses([node], current_user, &Mappers.Status.from_graphql_activity/2),
           true <- is_map(status) and not is_nil(Map.get(status, "id")) do
        Phoenix.Controller.json(conn, status)
      else
        _ -> RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    # Load a single status by id via a direct `Objects.read` (used by the by-id/interaction
    # paths that stay direct; feeds and `show_status` go through GraphQL). Reads the OBJECT
    # (post) and its create-activity (subject = author) — unlike the old `activity(object_id:)`
    # query, which could match a like-activity and mis-attribute the status to the liker.
    defp read_single_status(id, current_user) do
      case Bonfire.Social.Objects.read(id,
             current_user: current_user,
             preload: FeedPipeline.single_status_preloads()
           ) do
        {:ok, %{activity: activity} = object} when is_map(activity) ->
          {:ok, Map.put(activity, :object, object)}

        {:ok, object} ->
          {:ok, %{id: id, object_id: id, object: object}}

        _ ->
          {:error, :not_found}
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

    @doc "Edit a status"
    def update_status(%{"id" => id} = params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        attrs = %{
          html_body: params["status"],
          summary: params["spoiler_text"]
        }

        case edit_post_content(current_user, id, attrs) do
          {:ok, _} ->
            # Reload via the direct loader to get all associations the mapper needs.
            # Kept outside the rescue: a post-commit reload/map crash must not be
            # reported as :not_found (the edit already succeeded).
            with {:ok, activity} <- read_single_status(id, current_user),
                 status when not is_nil(status) <-
                   Mappers.Status.from_activity(activity, current_user: current_user) do
              Phoenix.Controller.json(conn, status)
            else
              _ -> RestAdapter.error_fn({:error, :not_found}, conn)
            end

          {:error, :not_found} ->
            RestAdapter.error_fn({:error, :not_found}, conn)

          {:error, _reason} ->
            RestAdapter.error_fn({:error, :forbidden}, conn)
        end
      end
    end

    # Scope the rescue to only the edit call so unexpected exceptions there map to
    # :not_found/:forbidden, while the reload+map path can surface its own failures.
    defp edit_post_content(current_user, id, attrs) do
      case Bonfire.Social.PostContents.edit(current_user, id, attrs) do
        {:ok, _} = ok ->
          ok

        {:error, _} = err ->
          err

        other ->
          # edit/3 returns nil for a non-existent/unreadable status
          debug(other, "edit returned non-tuple; treating as not_found")
          {:error, :not_found}
      end
    rescue
      e ->
        error(e, "Failed to edit status")
        {:error, :not_found}
    end

    @doc "Delete a status"
    def delete_status(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case Bonfire.Social.Objects.delete(id, current_user: current_user) do
          {:ok, _} ->
            # Mastodon API returns the deleted status for delete-and-redraft functionality
            Phoenix.Controller.json(conn, %{"id" => id})

          {:error, :not_found} ->
            RestAdapter.error_fn({:error, :not_found}, conn)

          {:error, :unauthorized} ->
            RestAdapter.error_fn({:error, :unauthorized}, conn)

          {:error, reason} ->
            error(reason, "Failed to delete status")
            RestAdapter.error_fn({:error, reason}, conn)
        end
      end
    end

    @doc "Get thread context (ancestors and descendants)"
    def status_context(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      # The root status must itself be readable; otherwise 404 (don't leak an empty
      # context for a private/non-existent status).
      case read_single_status(id, current_user) do
        {:ok, _root} ->
          ancestors = ancestor_activities(id, current_user)

          descendants =
            id
            |> descendant_reply_ids()
            |> Enum.flat_map(&load_status_activity(&1, current_user))

          object_ids =
            (ancestors ++ descendants) |> Enum.map(&get_activity_id/1) |> Enum.reject(&is_nil/1)

          map_opts = batch_load_supplementary(current_user, object_ids)

          context = %{
            "ancestors" => Enum.map(ancestors, &Mappers.Status.from_activity(&1, map_opts)),
            "descendants" => Enum.map(descendants, &Mappers.Status.from_activity(&1, map_opts))
          }

          Phoenix.Controller.json(conn, context)

        {:error, _} ->
          RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    # Walk the reply_to chain up to the thread root, returning activities ordered
    # root-first. Boundaries are applied at load time (load_status_activity drops
    # any ancestor the current user cannot read).
    defp ancestor_activities(id, current_user) do
      id
      |> ancestor_ids([], 0)
      |> Enum.flat_map(&load_status_activity(&1, current_user))
    end

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

    defp load_status_activity(id, current_user) do
      case read_single_status(id, current_user) do
        {:ok, activity} -> [activity]
        _ -> []
      end
    end

    def status_favourited_by(%{"id" => id}, conn) do
      list_status_interactors(conn, :like, id)
    end

    def status_reblogged_by(%{"id" => id}, conn) do
      list_status_interactors(conn, :boost, id)
    end

    defp list_status_interactors(conn, interaction_type, id) do
      current_user = conn.assigns[:current_user]

      result =
        case interaction_type do
          :like ->
            Bonfire.Social.Likes.by_liked(id, current_user: current_user, preload: :subject)

          :boost ->
            Bonfire.Social.Boosts.list_of(id, current_user: current_user)
        end

      edges =
        case result do
          list when is_list(list) -> list
          %{edges: list} when is_list(list) -> list
          _ -> []
        end

      accounts =
        edges
        |> Enum.flat_map(fn edge ->
          subject = Map.get(edge, :edge, edge) |> Map.get(:subject, nil)
          if subject, do: [subject], else: []
        end)
        |> Enum.map(
          &Mappers.Account.from_user(&1, current_user: current_user, skip_expensive_stats: true)
        )
        |> Enum.reject(&is_nil/1)

      Phoenix.Controller.json(conn, accounts)
    end

    defp get_activity_id(%{object_id: id}), do: id
    defp get_activity_id(%{id: id}), do: id
    defp get_activity_id(_), do: nil

    # Batch-load supplementary per-object context, ready to merge into mapper opts.
    defp batch_load_supplementary(current_user, object_ids) do
      current_user
      |> BatchLoaders.load(object_ids)
      |> Keyword.put(:current_user, current_user)
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
      opts = [
        current_user: current_user,
        preload: FeedPipeline.single_status_preloads()
      ]

      case Bonfire.Social.Objects.read(id, opts) do
        {:ok, object} ->
          case Mappers.Status.from_post(object, current_user: current_user) do
            nil ->
              RestAdapter.error_fn({:error, :not_found}, conn)

            status ->
              prepared =
                status
                |> Map.put("pinned", pinned_value)
                |> Helpers.deep_struct_to_map()

              Phoenix.Controller.json(conn, prepared)
          end

        {:error, reason} ->
          RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    @doc "Search for statuses/posts, called by the Search adapter."
    def search_statuses_for_api(query, opts, _conn) do
      current_user = opts[:current_user]

      query
      |> search_status_ids(opts)
      |> Enum.flat_map(&load_status_activity(&1, current_user))
      |> map_statuses_with_batch(current_user)
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

    defp map_statuses_with_batch(activities, current_user) do
      object_ids = activities |> Enum.map(&get_activity_id/1) |> Enum.reject(&is_nil/1)
      batch_opts = batch_load_supplementary(current_user, object_ids)

      Enum.flat_map(activities, fn activity ->
        case Mappers.Status.from_activity(activity, batch_opts) do
          status when is_map(status) ->
            if Map.get(status, "id"), do: [status], else: []

          _ ->
            []
        end
      end)
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
        report = Mappers.Report.from_flag(flag, current_user: current_user)

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

        reports =
          flags
          |> Enum.map(&preload_flag_for_api/1)
          |> Enum.map(&Mappers.Report.from_flag(&1, current_user: current_user))
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
        report = Mappers.Report.from_flag(flag, current_user: current_user)

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

      case Bonfire.Social.Pins.list_by(user_id, limit: limit, preload: :object_with_creator) do
        %{edges: edges} when is_list(edges) ->
          statuses =
            Enum.flat_map(edges, fn edge ->
              post = get_field(edge, :edge) |> get_field(:object)

              if post do
                case Mappers.Status.from_post(post, current_user: current_user) do
                  nil -> []
                  status -> [Map.put(status, "pinned", true)]
                end
              else
                []
              end
            end)

          Phoenix.Controller.json(conn, statuses)

        _ ->
          Phoenix.Controller.json(conn, [])
      end
    end
  end
end
