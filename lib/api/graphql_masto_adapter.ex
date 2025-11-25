if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQLMasto.Adapter do
    @moduledoc "Social API endpoints for Mastodon-compatible client apps, powered by the GraphQL API (see `Bonfire.Social.API.GraphQL`)"

    use Arrows
    import Untangle
    use Bonfire.Common.Repo

    use AbsintheClient,
      schema: Bonfire.API.GraphQL.Schema,
      action: [mode: :internal]

    alias Bonfire.API.GraphQL.RestAdapter
    alias Bonfire.API.MastoCompat.{Schemas, Mappers, InteractionHandler}
    alias Bonfire.Common.Utils
    alias Bonfire.Common.Enums
    alias Bonfire.Me.API.GraphQLMasto.Adapter, as: MeAdapter

    @post_content "
    name
    summary
    content: html_body
    "

    @media "
    id
    url
    path
    media_type
    label
    description
    size
    "

    @user Utils.maybe_apply(MeAdapter, :user_profile_query, [], fallback_return: "id")

    @activity "
    id
    created_at: date
    uri: canonical_uri
    subject_id
    object_id
    verb {
      verb
    }
    account: subject {
      ... on User {
        #{@user}
    }}
    object {
      __typename
      ... on Post {
        id
        post_content {
          #{@post_content}
        }
        media {
          #{@media}
        }
        activity {
          id
          created_at: date
          uri: canonical_uri
          creator: subject {
            ... on User {
              #{@user}
            }
          }
        }
      }
      ... on Boost {
        id
        edge {
          id
          subject {
            ... on User {
              #{@user}
            }
          }
          object {
            __typename
            ... on Post {
              id
              post_content {
                #{@post_content}
              }
              media {
                #{@media}
              }
              activity {
                id
                created_at: date
                uri: canonical_uri
                creator: subject {
                  ... on User {
                    #{@user}
                  }
                }
              }
            }
          }
        }
      }
    }
    object_post_content {
      #{@post_content}
    }
    replied {
      reply_to_id: replyToId
      reply_to: replyTo {
        id
        subject_id: subjectId
      }
    }
    liked_by_me: likedByMe
    boosted_by_me: boostedByMe
    bookmarked_by_me: bookmarkedByMe
    like_count: likeCount
    boost_count: boostCount
    replies_count: repliesCount
    media {
      #{@media}
    }
    "

    # @graphql "query ($filter: PostFilters) {
    #   post(filter: $filter) {
    #     #{@post_content}
    # }}"
    # def post(params, conn) do
    #   post = graphql(conn, :post, debug(params))

    #   RestAdapter.return(:post, post, conn, &prepare_post/1)
    # end

    @graphql "query ($filter: FeedFilters, $first: Int, $last: Int, $after: String, $before: String) {
      feed_activities(filter: $filter, first: $first, last: $last, after: $after, before: $before) {
      edges { node {
              #{@activity}
      }}
      page_info: pageInfo {
        has_next_page: hasNextPage
        has_previous_page: hasPreviousPage
        start_cursor: startCursor
        end_cursor: endCursor
      }
    }}"
    def feed(params, conn) do
      # N+1 queries are prevented by Dataloader in GraphQL field resolvers
      # (see social_api_graphql.ex for peered/created Dataloader fields)
      # Pagination params are already translated by the controller

      current_user = conn.assigns[:current_user]

      graphql(conn, :feed, params)
      |> process_feed_edges_with_batch_loading(current_user, "feed")
      |> then(&respond_with_feed(conn, params, &1))
    end

    @graphql "query ($filter: FeedFilters, $first: Int, $last: Int, $after: String, $before: String) {
      feed_activities(filter: $filter, first: $first, last: $last, after: $after, before: $before) {
      edges { node {
              #{@activity}
      }}
      page_info: pageInfo {
        has_next_page: hasNextPage
        has_previous_page: hasPreviousPage
        start_cursor: startCursor
        end_cursor: endCursor
      }
    }}"
    def notifications(params, conn) do
      # N+1 queries are prevented by Dataloader in GraphQL field resolvers
      # Pagination params are already translated by the controller
      # Filter is already set to notifications feed by controller

      current_user = conn.assigns[:current_user]
      notification_filters = extract_notification_filters(conn.params)

      graphql(conn, :notifications, params)
      |> process_feed_edges_with_batch_loading(current_user, "notification")
      |> apply_notification_filters(notification_filters)
      |> then(&respond_with_feed(conn, params, &1))
    end

    # Apply Mastodon-specific notification filtering to result tuple
    defp apply_notification_filters({:ok, items, page_info}, filters) do
      filtered_items = filter_notifications(items, filters)
      {:ok, filtered_items, page_info}
    end

    defp apply_notification_filters({:error, _} = error, _filters), do: error

    # Extract notification filtering parameters from request
    defp extract_notification_filters(params) do
      %{
        types: extract_types_filter(params["types"]),
        exclude_types: extract_types_filter(params["exclude_types"]),
        account_id: params["account_id"]
      }
    end

    # Parse types/exclude_types arrays from params
    # Mastodon sends these as arrays in query params like: ?exclude_types[]=follow&exclude_types[]=mention
    defp extract_types_filter(nil), do: nil
    defp extract_types_filter(types) when is_list(types), do: types
    defp extract_types_filter(types) when is_binary(types), do: [types]
    defp extract_types_filter(_), do: nil

    # Filter notifications based on Mastodon filtering params
    defp filter_notifications(notifications, %{types: nil, exclude_types: nil, account_id: nil}) do
      # No filters, return all
      notifications
    end

    defp filter_notifications(notifications, filters) do
      notifications
      |> Enum.filter(fn notification ->
        type = Map.get(notification, "type")
        account = Map.get(notification, "account")
        account_id = if account, do: Map.get(account, "id"), else: nil

        # Apply type filtering (types and exclude_types are mutually exclusive)
        type_match =
          cond do
            filters.types != nil ->
              type in filters.types

            filters.exclude_types != nil ->
              type not in filters.exclude_types

            true ->
              true
          end

        # Apply account_id filtering
        account_match =
          if filters.account_id do
            account_id == filters.account_id
          else
            true
          end

        type_match && account_match
      end)
    end

    # Favourites timeline - posts liked by current user
    # Uses Bonfire.Social.Likes.list_my instead of GraphQL since there's no likes feed query
    @doc "Get posts favourited/liked by the current user"
    def favourites(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        # Extract pagination options from params
        pagination_opts = extract_favourites_pagination_opts(params)

        # Get liked posts using Likes module with proper preloads
        result =
          Bonfire.Social.Likes.list_my(
            Keyword.merge(pagination_opts,
              current_user: current_user,
              preload: :object_with_creator
            )
          )

        result
        |> process_likes_result(current_user)
        |> then(&respond_with_feed(conn, params, &1))
      end
    end

    # Extract pagination options for favourites query
    defp extract_favourites_pagination_opts(params) do
      limit = validate_limit(params[:first] || params[:last] || 20)

      opts = [limit: limit]
      opts = if params[:after], do: Keyword.put(opts, :after, params[:after]), else: opts
      opts = if params[:before], do: Keyword.put(opts, :before, params[:before]), else: opts
      opts
    end

    # Process Like edges into Status objects
    defp process_likes_result(%{edges: edges, page_info: page_info}, current_user) do
      # First, extract all objects and their IDs
      objects_with_ids =
        edges
        |> Enum.flat_map(fn like_edge ->
          object =
            case like_edge do
              %{edge: %{object: obj}} when not is_nil(obj) -> obj
              %{object: obj} when not is_nil(obj) -> obj
              _ -> nil
            end

          object_id = object && (Map.get(object, :id) || Map.get(object, "id"))
          if object && object_id, do: [{object, object_id}], else: []
        end)

      object_ids = Enum.map(objects_with_ids, fn {_, id} -> id end)

      # Batch load boost and bookmark states (likes are known: user favourited these)
      # This avoids N+1 queries in add_interaction_states
      boosted_ids =
        if current_user && length(object_ids) > 0 do
          batch_load_boosted(object_ids, current_user)
        else
          MapSet.new()
        end

      bookmarked_ids =
        if current_user && length(object_ids) > 0 do
          batch_load_bookmarked(object_ids, current_user)
        else
          MapSet.new()
        end

      # Build interaction states map
      interaction_states =
        Enum.reduce(object_ids, %{}, fn id, acc ->
          Map.put(acc, id, %{
            # User favourited these (that's why they're in the list)
            favourited: true,
            reblogged: MapSet.member?(boosted_ids, id),
            bookmarked: MapSet.member?(bookmarked_ids, id)
          })
        end)

      # Transform objects to statuses with pre-loaded interaction states
      statuses =
        objects_with_ids
        |> Enum.flat_map(fn {object, _object_id} ->
          try do
            status =
              Mappers.Status.from_post(object,
                current_user: current_user,
                interaction_states: interaction_states
              )

            if status, do: [status], else: []
          rescue
            e ->
              error(e, "Failed to transform liked post to status")
              []
          end
        end)

      # Add cursor_fields to page_info so Link headers use correct cursor format
      # Likes uses [id: :desc] (not {:activity, :id})
      page_info_with_cursor = Map.put(page_info, :cursor_fields, id: :desc)

      {:ok, statuses, page_info_with_cursor}
    end

    defp process_likes_result({:error, _} = error, _current_user), do: error

    defp process_likes_result(other, _current_user) do
      error(other, "Unexpected result from Likes.list_my")
      {:error, :unexpected_response}
    end

    # GraphQL query for fetching a single activity by ID
    # Must be immediately before show_status function for AbsintheClient
    @graphql "query ($filter: ActivityFilter) {
      activity(filter: $filter) {
        #{@activity}
      }
    }"
    # Get single status by ID
    # Uses GraphQL query defined above to leverage Dataloader and avoid N+1 queries
    # Returns map data (not Ecto structs) to prevent Jason.Encoder errors
    def show_status(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      # Call GraphQL with proper query name (matches function name)
      # The @activity fragment ensures complete selection set → returns maps not structs
      # Use object_id (not activity_id) - status ID is the post/object ID in Mastodon API
      case graphql(conn, :show_status, %{"filter" => %{"object_id" => id}}) do
        # CRITICAL: Use atom keys (:data, :activity), not string keys
        %{data: %{activity: activity}} when not is_nil(activity) ->
          # activity is now a MAP (from GraphQL), not an Ecto struct
          # Batch load interaction states for this single activity
          object_ids = [get_activity_id(activity)] |> Enum.reject(&is_nil/1)
          interaction_states = batch_load_interaction_states(current_user, object_ids)

          status =
            Mappers.Status.from_activity(activity,
              current_user: current_user,
              interaction_states: interaction_states
            )

          if Map.get(status, "id") do
            Phoenix.Controller.json(conn, status)
          else
            RestAdapter.error_fn({:error, :not_found}, conn)
          end

        %{data: %{activity: nil}} ->
          RestAdapter.error_fn({:error, :not_found}, conn)

        %{errors: errors} ->
          # Log errors for debugging
          error(errors, "GraphQL query failed in show_status")
          RestAdapter.error_fn({:error, errors}, conn)

        other ->
          error(other, "Unexpected GraphQL response in show_status")
          RestAdapter.error_fn({:error, :unexpected_response}, conn)
      end
    end

    # GraphQL query for fetching thread context (ancestors and descendants)
    # Must be immediately before status_context function for AbsintheClient
    @graphql "query ($id: ID!) {
      thread_context(id: $id) {
        ancestors {
          #{@activity}
        }
        descendants {
          #{@activity}
        }
      }
    }"
    # Get thread context (ancestors and descendants)
    # Uses GraphQL query defined above to leverage Dataloader and avoid N+1 queries
    # Returns map data (not Ecto structs) to prevent Jason.Encoder errors
    def status_context(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      # Call GraphQL with proper query name (matches function name)
      # The @activity fragment ensures complete selection set → returns maps not structs
      case graphql(conn, :status_context, %{"id" => id}) do
        %{data: %{thread_context: %{ancestors: ancestors, descendants: descendants}}} ->
          # Collect all activity IDs for batch loading interaction states
          all_activities = (ancestors || []) ++ (descendants || [])
          object_ids = all_activities |> Enum.map(&get_activity_id/1) |> Enum.reject(&is_nil/1)
          interaction_states = batch_load_interaction_states(current_user, object_ids)

          # Transform maps to Mastodon format with interaction states
          map_opts = [current_user: current_user, interaction_states: interaction_states]

          context = %{
            "ancestors" => Enum.map(ancestors || [], &Mappers.Status.from_activity(&1, map_opts)),
            "descendants" =>
              Enum.map(descendants || [], &Mappers.Status.from_activity(&1, map_opts))
          }

          Phoenix.Controller.json(conn, context)

        %{data: %{thread_context: nil}} ->
          # Empty context if thread not found
          Phoenix.Controller.json(conn, %{"ancestors" => [], "descendants" => []})

        %{errors: errors} ->
          error(errors, "GraphQL query failed in status_context")
          RestAdapter.error_fn({:error, errors}, conn)

        other ->
          error(other, "Unexpected GraphQL response in status_context")
          # Return empty context on unexpected response
          Phoenix.Controller.json(conn, %{"ancestors" => [], "descendants" => []})
      end
    end

    # Get accounts who favourited/liked a status
    def status_favourited_by(%{"id" => id} = params, conn) do
      current_user = conn.assigns[:current_user]
      opts = build_list_pagination_opts(params, current_user)

      case Bonfire.Social.Likes.list_of(id, opts) do
        %{edges: edges, page_info: page_info} ->
          accounts =
            edges
            |> Enum.map(& &1.subject)
            |> Enum.map(&Mappers.Account.from_user(&1, current_user: current_user))
            |> Enum.reject(&is_nil/1)

          conn
          |> add_link_headers(params, page_info, accounts)
          |> Phoenix.Controller.json(accounts)

        {:error, reason} ->
          RestAdapter.error_fn({:error, reason}, conn)

        _other ->
          # If list_of returns unexpected format, return empty list
          Phoenix.Controller.json(conn, [])
      end
    end

    # Get accounts who reblogged/boosted a status
    def status_reblogged_by(%{"id" => id} = params, conn) do
      current_user = conn.assigns[:current_user]
      opts = build_list_pagination_opts(params, current_user)

      case Bonfire.Social.Boosts.list_of(id, opts) do
        %{edges: edges, page_info: page_info} ->
          accounts =
            edges
            |> Enum.map(& &1.subject)
            |> Enum.map(&Mappers.Account.from_user(&1, current_user: current_user))
            |> Enum.reject(&is_nil/1)

          conn
          |> add_link_headers(params, page_info, accounts)
          |> Phoenix.Controller.json(accounts)

        {:error, reason} ->
          RestAdapter.error_fn({:error, reason}, conn)

        _other ->
          # If list_of returns unexpected format, return empty list
          Phoenix.Controller.json(conn, [])
      end
    end

    # Helper to extract activity/object ID for batch loading
    # Check object_id first - for Mastodon API, status ID is the object/post ID
    defp get_activity_id(%{object_id: id}), do: id
    defp get_activity_id(%{id: id}), do: id
    defp get_activity_id(_), do: nil

    # Batch load interaction states for multiple objects to avoid N+1 queries
    # Returns a map with %{object_id => %{favourited: bool, reblogged: bool, bookmarked: bool}}
    defp batch_load_interaction_states(nil, _object_ids), do: %{}
    defp batch_load_interaction_states(_user, []), do: %{}

    defp batch_load_interaction_states(current_user, object_ids) do
      # Query all likes, boosts, and bookmarks for this user in 3 queries total
      liked_ids = batch_load_liked(current_user, object_ids)
      boosted_ids = batch_load_boosted(current_user, object_ids)
      bookmarked_ids = batch_load_bookmarked(current_user, object_ids)

      # Build a map of object_id => interaction states
      object_ids
      |> Enum.map(fn object_id ->
        {object_id,
         %{
           favourited: MapSet.member?(liked_ids, object_id),
           reblogged: MapSet.member?(boosted_ids, object_id),
           bookmarked: MapSet.member?(bookmarked_ids, object_id)
         }}
      end)
      |> Map.new()
    end

    # Batch load all object IDs liked by user (filtered to specific object_ids)
    defp batch_load_liked(current_user, object_ids) do
      try do
        # Query edges table directly for better performance
        import Ecto.Query
        alias Bonfire.Data.Edges.Edge
        like_table_id = Bonfire.Data.Social.Like.__pointers__(:table_id)

        from(e in Edge,
          where: e.subject_id == ^current_user.id,
          where: e.object_id in ^object_ids,
          where: e.table_id == ^like_table_id,
          select: e.object_id
        )
        |> repo().all()
        |> MapSet.new()
      rescue
        _ -> MapSet.new()
      end
    end

    # Batch load all object IDs boosted by user (filtered to specific object_ids)
    defp batch_load_boosted(current_user, object_ids) do
      try do
        import Ecto.Query
        alias Bonfire.Data.Edges.Edge
        boost_table_id = Bonfire.Data.Social.Boost.__pointers__(:table_id)

        from(e in Edge,
          where: e.subject_id == ^current_user.id,
          where: e.object_id in ^object_ids,
          where: e.table_id == ^boost_table_id,
          select: e.object_id
        )
        |> repo().all()
        |> MapSet.new()
      rescue
        _ -> MapSet.new()
      end
    end

    # Batch load all object IDs bookmarked by user (filtered to specific object_ids)
    defp batch_load_bookmarked(current_user, object_ids) do
      try do
        import Ecto.Query
        alias Bonfire.Data.Edges.Edge
        bookmark_table_id = Bonfire.Data.Social.Bookmark.__pointers__(:table_id)

        from(e in Edge,
          where: e.subject_id == ^current_user.id,
          where: e.object_id in ^object_ids,
          where: e.table_id == ^bookmark_table_id,
          select: e.object_id
        )
        |> repo().all()
        |> MapSet.new()
      rescue
        _ -> MapSet.new()
      end
    end

    # Build pagination opts for list queries (favourited_by, reblogged_by)
    # These don't use the feed cursor format, just simple pagination
    defp build_list_pagination_opts(params, current_user) do
      limit = validate_limit(params["limit"])

      base_opts = [
        current_user: current_user,
        limit: limit
      ]

      # Add pagination cursors if present
      base_opts
      |> maybe_add_cursor(params, "max_id", :after)
      |> maybe_add_cursor(params, "since_id", :before)
      |> maybe_add_cursor(params, "min_id", :before)
    end

    defp maybe_add_cursor(opts, params, param_name, cursor_key) do
      if cursor = params[param_name] do
        Keyword.put(opts, cursor_key, cursor)
      else
        opts
      end
    end

    defp validate_limit(nil), do: 40

    defp validate_limit(limit) when is_binary(limit),
      do: String.to_integer(limit) |> validate_limit()

    defp validate_limit(limit) when is_integer(limit) and limit > 0 and limit <= 80, do: limit
    defp validate_limit(limit) when is_integer(limit) and limit > 80, do: 80
    defp validate_limit(_), do: 40

    # Process feed edges with batch loading of interaction states to avoid N+1 queries
    # This extracts object IDs, batch loads interaction states, then delegates to process_feed_edges
    defp process_feed_edges_with_batch_loading(feed_response, current_user, feed_type) do
      case feed_response do
        %{data: %{feed_activities: %{edges: edges}}} when is_list(edges) ->
          # Extract object IDs from all activities for batch loading
          object_ids =
            edges
            |> Enum.map(fn edge ->
              activity = Map.get(edge, :node) || edge
              get_activity_id(activity)
            end)
            |> Enum.reject(&is_nil/1)

          # Batch load interaction states in 3 queries total (not N×3)
          interaction_states = batch_load_interaction_states(current_user, object_ids)

          # Build prepare function with preloaded interaction states
          prepare_fn =
            case feed_type do
              "notification" ->
                &Mappers.Notification.from_activity(&1,
                  current_user: current_user,
                  interaction_states: interaction_states
                )

              _ ->
                &Mappers.Status.from_activity(&1,
                  current_user: current_user,
                  interaction_states: interaction_states
                )
            end

          # Delegate to existing process_feed_edges with prepared function
          process_feed_edges(feed_response, prepare_fn, feed_type)

        # Pass through errors and other responses
        other ->
          # For errors, use a simple prepare function without interaction states
          prepare_fn =
            case feed_type do
              "notification" ->
                &Mappers.Notification.from_activity(&1, current_user: current_user)

              _ ->
                &Mappers.Status.from_activity(&1, current_user: current_user)
            end

          process_feed_edges(other, prepare_fn, feed_type)
      end
    end

    # Shared helper to process feed responses from GraphQL
    # Pure function that returns {:ok, items, page_info} or {:error, reason}
    # Separates data processing from HTTP concerns for better composability
    defp process_feed_edges(feed_response, prepare_fn, feed_type) do
      case feed_response do
        %{data: %{feed_activities: %{edges: edges, page_info: page_info}}} when is_list(edges) ->
          # Process edges into items, filtering out invalid ones
          # Note: Mappers now return nil for invalid items after schema validation
          items =
            edges
            |> Enum.flat_map(fn edge ->
              try do
                case prepare_fn.(edge) do
                  nil ->
                    # Mapper returned nil (failed validation) - skip silently
                    # Validation warnings are logged by the mapper itself
                    []

                  item when is_map(item) ->
                    # Double-check required fields (defensive)
                    if Map.get(item, "account") && Map.get(item, "id") do
                      [item]
                    else
                      warn(
                        item,
                        "#{String.capitalize(feed_type)} item missing required fields (account or id)"
                      )

                      []
                    end

                  other ->
                    warn(other, "#{String.capitalize(feed_type)} mapper returned unexpected type")
                    []
                end
              rescue
                e ->
                  error(e, "Failed to prepare #{feed_type} item from edge: #{inspect(edge)}")
                  []
              end
            end)

          {:ok, items, page_info}

        %{errors: errors} ->
          {:error, errors}

        other ->
          error(other, "unexpected_#{feed_type}_response")
          {:error, other}
      end
    end

    # HTTP response helper - converts result tuple to JSON response
    defp respond_with_feed(conn, params, {:ok, items, page_info}) do
      conn
      |> add_link_headers(params, page_info, items)
      |> Phoenix.Controller.json(items)
    end

    defp respond_with_feed(conn, _params, {:error, errors}) do
      RestAdapter.error_fn(errors, conn)
    end

    # Add Mastodon-compatible Link headers for pagination using Paginator cursors
    defp add_link_headers(conn, _params, page_info, items) do
      # Build base URL, omitting standard ports (80 for HTTP, 443 for HTTPS)
      port_part =
        case {conn.scheme, conn.port} do
          {"https", 443} -> ""
          {"http", 80} -> ""
          {_, port} -> ":#{port}"
        end

      base_url = "#{conn.scheme}://#{conn.host}#{port_part}#{conn.request_path}"
      base_params = Map.take(conn.params, ["limit"])

      # Get cursors from page_info, with fallback to extracting from items
      # (Paginator may set start_cursor to nil on first page)
      cursor_for_record_fun = get_field(page_info, :cursor_for_record_fun) || (&Enums.id/1)

      # Extract cursor field format from page_info for proper encoding
      # Defaults to {:activity, :id} for timeline compatibility
      cursor_field = extract_cursor_field(page_info)

      start_cursor =
        (get_field(page_info, :start_cursor) ||
           items |> List.first() |> then(&if &1, do: cursor_for_record_fun.(&1)))
        |> encode_cursor_for_link_header(cursor_field)

      end_cursor =
        (get_field(page_info, :end_cursor) ||
           items |> List.last() |> then(&if &1, do: cursor_for_record_fun.(&1)))
        |> encode_cursor_for_link_header(cursor_field)

      links = []

      # Check if we're on the last page (Paginator sets final_cursor instead of end_cursor on last page)
      is_last_page = get_field(page_info, :final_cursor) != nil

      # Add "next" link for pagination (older posts) using end_cursor
      # Don't add if we're on the last page (no more results)
      links =
        if end_cursor && !is_last_page do
          query_params = base_params |> Map.put("max_id", end_cursor) |> URI.encode_query()
          next_link = "<#{base_url}?#{query_params}>; rel=\"next\""
          links ++ [next_link]
        else
          links
        end

      # Add "prev" link for pagination (newer posts) using start_cursor
      links =
        if start_cursor do
          query_params = base_params |> Map.put("min_id", start_cursor) |> URI.encode_query()
          prev_link = "<#{base_url}?#{query_params}>; rel=\"prev\""
          links ++ [prev_link]
        else
          links
        end

      if links != [] do
        conn
        |> Plug.Conn.put_resp_header("link", Enum.join(links, ", "))
        |> Plug.Conn.put_resp_header("access-control-expose-headers", "Link")
      else
        conn
      end
    end

    # Helper to safely get field from map with either atom or string key
    defp get_field(map, key) when is_atom(key) and is_map(map) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key))
    end

    defp get_field(_, _), do: nil

    # Extract cursor field format from page_info
    # Returns the field name (e.g., :id or {:activity, :id}) for cursor encoding
    # Defaults to {:activity, :id} for timeline compatibility
    defp extract_cursor_field(page_info) when is_map(page_info) do
      case get_field(page_info, :cursor_fields) do
        # Format: [id: :desc] or [{:activity, :id}: :desc]
        [{field, _direction} | _] -> field
        # Format: [:id] or [{:activity, :id}]
        [field | _] when is_atom(field) or is_tuple(field) -> field
        # Default to timeline format
        _ -> {:activity, :id}
      end
    end

    defp extract_cursor_field(_), do: {:activity, :id}

    # Status interaction mutations
    # Call Bonfire context functions directly with proper preloads

    def like_status(%{"id" => id} = params, conn) do
      debug(params, "like_status called with params")

      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :like,
        context_fn: &Bonfire.Social.Likes.like/2,
        flag: "favourited",
        flag_value: true
      )
    end

    def unlike_status(%{"id" => id} = params, conn) do
      debug(params, "unlike_status called with params")

      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :unlike,
        context_fn: &Bonfire.Social.Likes.unlike/2,
        flag: "favourited",
        flag_value: false
      )
    end

    def boost_status(%{"id" => id} = params, conn) do
      debug(params, "boost_status called with params")

      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :boost,
        context_fn: &Bonfire.Social.Boosts.boost/2,
        flag: "reblogged",
        flag_value: true
      )
    end

    def unboost_status(%{"id" => id} = params, conn) do
      debug(params, "unboost_status called with params")

      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :unboost,
        context_fn: &Bonfire.Social.Boosts.unboost/2,
        flag: "reblogged",
        flag_value: false
      )
    end

    def bookmark_status(%{"id" => id} = params, conn) do
      debug(params, "bookmark_status called with params")

      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :bookmark,
        context_fn: &Bonfire.Social.Bookmarks.bookmark/2,
        flag: "bookmarked",
        flag_value: true
      )
    end

    def unbookmark_status(%{"id" => id} = params, conn) do
      debug(params, "unbookmark_status called with params")

      InteractionHandler.handle_interaction(conn, id,
        interaction_type: :unbookmark,
        context_fn: &Bonfire.Social.Bookmarks.unbookmark/2,
        flag: "bookmarked",
        flag_value: false
      )
    end

    # Encode cursor for use in Link headers
    # All cursors must be consistently encoded to base64
    # Must use url_encode64 to match Paginator's url_decode64!

    # Handle nil cursor
    defp encode_cursor_for_link_header(nil, _cursor_field), do: nil

    # Handle map cursor (already in cursor format)
    defp encode_cursor_for_link_header(cursor, _cursor_field) when is_map(cursor) do
      cursor
      |> :erlang.term_to_binary()
      |> Base.url_encode64()
    end

    # Handle binary cursor with explicit cursor field format
    defp encode_cursor_for_link_header(cursor, cursor_field) when is_binary(cursor) do
      # Check if already base64 encoded (from Paginator)
      if String.match?(cursor, ~r/^g3[A-Za-z0-9_-]+=*$/) do
        # Already encoded, pass through unchanged
        cursor
      else
        # Plain ID from cursor_for_record_fun - convert to cursor map and encode
        # Use the specified cursor_field format to match query's cursor_fields
        %{cursor_field => cursor}
        |> :erlang.term_to_binary()
        |> Base.url_encode64()
      end
    end
  end
end
