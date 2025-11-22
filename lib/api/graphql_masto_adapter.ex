if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQLMasto.Adapter do
    @moduledoc "Social API endpoints for Mastodon-compatible client apps, powered by the GraphQL API (see `Bonfire.Social.API.GraphQL`)"

    use Arrows
    import Untangle

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
      prepare_fn = &Mappers.Status.from_activity(&1, current_user: current_user)

      graphql(conn, :feed, params)
      |> process_feed_edges(prepare_fn, "feed")
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
      prepare_fn = &Mappers.Notification.from_activity(&1, current_user: current_user)

      graphql(conn, :notifications, params)
      |> process_feed_edges(prepare_fn, "notification")
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

    # Shared helper to process feed responses from GraphQL
    # Pure function that returns {:ok, items, page_info} or {:error, reason}
    # Separates data processing from HTTP concerns for better composability
    defp process_feed_edges(feed_response, prepare_fn, feed_type) do
      case feed_response do
        %{data: %{feed_activities: %{edges: edges, page_info: page_info}}} when is_list(edges) ->
          # Process edges into items, filtering out invalid ones
          items =
            edges
            |> Enum.flat_map(fn edge ->
              try do
                item = prepare_fn.(edge)
                # Validate that item has required fields
                if Map.get(item, "account") && Map.get(item, "id") do
                  # Keep valid item
                  [item]
                else
                  warn(
                    item,
                    "#{String.capitalize(feed_type)} item missing required fields (account or id)"
                  )

                  # Skip invalid item
                  []
                end
              rescue
                e ->
                  error(e, "Failed to prepare #{feed_type} item from edge: #{inspect(edge)}")
                  # Skip failed item
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

      start_cursor =
        (get_field(page_info, :start_cursor) ||
           items |> List.first() |> then(&if &1, do: cursor_for_record_fun.(&1)))
        |> encode_cursor_for_link_header()

      end_cursor =
        (get_field(page_info, :end_cursor) ||
           items |> List.last() |> then(&if &1, do: cursor_for_record_fun.(&1)))
        |> encode_cursor_for_link_header()

      links = []

      # Add "next" link for pagination (older posts) using end_cursor
      links =
        if end_cursor do
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

    # Encode cursor for use in Link headers
    # All cursors must be consistently encoded to base64
    # Must use url_encode64 to match Paginator's url_decode64!
    defp encode_cursor_for_link_header(nil), do: nil

    defp encode_cursor_for_link_header(cursor) when is_map(cursor) do
      cursor
      |> :erlang.term_to_binary()
      |> Base.url_encode64()
    end

    defp encode_cursor_for_link_header(cursor) when is_binary(cursor) do
      # Check if already base64 encoded (from Paginator)
      if String.match?(cursor, ~r/^g3[A-Za-z0-9_-]+=*$/) do
        # Already encoded, pass through unchanged
        cursor
      else
        # Plain ID from cursor_for_record_fun - convert to cursor map and encode
        # Matches Bonfire's cursor_fields format: {{:activity, :id}, :desc}
        %{{:activity, :id} => cursor}
        |> :erlang.term_to_binary()
        |> Base.url_encode64()
      end
    end
  end
end
