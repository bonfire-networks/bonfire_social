if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQLMasto.Adapter do
    @moduledoc "Social API endpoints for Mastodon-compatible client apps, powered by the GraphQL API (see `Bonfire.Social.API.GraphQL`)"

    use Arrows
    import Untangle

    use AbsintheClient,
      schema: Bonfire.API.GraphQL.Schema,
      action: [mode: :internal]

    alias Bonfire.API.GraphQL.RestAdapter
    alias Bonfire.Common.Utils
    alias Bonfire.Common.Enums
    alias Bonfire.Me.API.GraphQLMasto.Adapter, as: MeAdapter

    @post_content "
    name
    summary
    content: html_body
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

    @graphql "query ($filter: FeedFilters, $first: Int) {
      feed_activities(filter: $filter, first: $first) {
      edges { node {
              #{@activity}
      }}
      page_info: pageInfo {
        has_next_page: hasNextPage
        has_previous_page: hasPreviousPage
      }
    }}"
    def feed(params, conn) do
      # N+1 queries are prevented by Dataloader in GraphQL field resolvers
      # (see social_api_graphql.ex for peered/created Dataloader fields)
      graphql(conn, :feed, params)
      |> process_feed_response(conn, params, &prepare_activity/1, "feed")
    end

    # Shared helper to process feed responses from GraphQL
    # Handles edges processing, pagination, and error responses
    defp process_feed_response(feed_response, conn, params, prepare_fn, feed_type) do
      debug(feed_response, "GraphQL #{feed_type} response")

      case feed_response do
        %{data: %{feed_activities: %{edges: edges, page_info: page_info}}} when is_list(edges) ->
          # Single-pass processing: accumulate items while tracking first/last IDs
          {items_reversed, first_id, last_id} =
            edges
            |> Enum.reduce({[], nil, nil}, fn edge, {acc_items, first_id, last_id} ->
              # Get current edge's ID for pagination tracking
              edge_id = get_in(edge, [:node, :id])
              # Set first_id only once (from first edge)
              new_first_id = first_id || edge_id

              # Process the edge item
              new_acc_items =
                try do
                  item = prepare_fn.(edge)
                  # Validate that item has required fields
                  if Map.get(item, "account") && Map.get(item, "id") do
                    # Prepend valid item
                    [item | acc_items]
                  else
                    warn(
                      item,
                      "#{String.capitalize(feed_type)} item missing required fields (account or id)"
                    )

                    # Keep accumulator unchanged
                    acc_items
                  end
                rescue
                  e ->
                    error(e, "Failed to prepare #{feed_type} item from edge: #{inspect(edge)}")
                    # Keep accumulator unchanged
                    acc_items
                end

              {new_acc_items, new_first_id, edge_id}
            end)

          # Reverse to maintain original order
          items = Enum.reverse(items_reversed)

          conn
          |> add_link_headers(params, first_id, last_id, page_info)
          |> Phoenix.Controller.json(items)

        %{errors: errors} ->
          RestAdapter.error_fn(errors, conn)

        other ->
          error(other, "unexpected_#{feed_type}_response")
          RestAdapter.error_fn(other, conn)
      end
    end

    # Add Mastodon-compatible Link headers for pagination
    # Skip headers only if we got 0 results
    defp add_link_headers(conn, _params, nil, nil, _page_info), do: conn

    defp add_link_headers(conn, params, first_id, last_id, page_info) do
      base_url = "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
      base_params = Map.take(conn.params, ["limit"])

      links = []

      # Add "next" link for pagination (older posts)
      links =
        if last_id do
          query_params = base_params |> Map.put("max_id", last_id) |> URI.encode_query()
          next_link = "<#{base_url}?#{query_params}>; rel=\"next\""
          links ++ [next_link]
        else
          links
        end

      # Add "prev" link for pagination (newer posts)
      links =
        if first_id do
          query_params = base_params |> Map.put("min_id", first_id) |> URI.encode_query()
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

    # Transform Bonfire media to Mastodon media_attachments format
    # defp prepare_media_attachments(nil), do: []
    # defp prepare_media_attachments([]), do: []

    # defp prepare_media_attachments(media) when is_list(media) do
    #   Enum.map(media, &prepare_media_attachment/1)
    # end

    # defp prepare_media_attachments(_other), do: []

    # defp prepare_media_attachment(media) do
    #   media_type = get_field(media, :media_type) || "unknown"

    #   # Determine Mastodon media type from MIME type
    #   type = cond do
    #     String.starts_with?(media_type, "image/") -> "image"
    #     String.starts_with?(media_type, "video/") -> "video"
    #     String.starts_with?(media_type, "audio/") -> "audio"
    #     true -> "unknown"
    #   end

    #   %{
    #     "id" => get_field(media, :id),
    #     "type" => type,
    #     "url" => get_field(media, :url),
    #     "preview_url" => get_field(media, :url),  # Use same URL for preview
    #     "remote_url" => nil,
    #     "meta" => get_field(media, :metadata) || %{},
    #     "description" => get_field(media, :description) || get_field(media, :label) || "",
    #     "blurhash" => nil
    #   }
    # end

    defp prepare_activity(%{node: activity}), do: prepare_activity(activity)

    defp prepare_activity(activity) do
      # Check if this is a boost/reblog by comparing verb ID
      verb_id = get_field(activity, :verb) |> get_field(:verb)
      boost_verb_id = Bonfire.Boundaries.Verbs.get_id!(:boost)
      is_boost = verb_id == boost_verb_id

      # Split nested associations from flat fields
      {nested, flat} = Map.split(activity, [:account, :object, :subject])
      flattened = Enums.maybe_flatten(flat)

      # Get account data (prefer :account, fallback to :subject)
      account_data =
        case get_field(nested, :account) || get_field(nested, :subject) do
          nil ->
            nil

          %{} = acc when map_size(acc) == 0 ->
            nil

          acc ->
            prepared = Utils.maybe_apply(MeAdapter, :prepare_user, acc, fallback_return: acc)
            # Ensure prepared account has an ID
            if is_map(prepared) && (Map.has_key?(prepared, :id) || Map.has_key?(prepared, "id")) do
              prepared
            else
              nil
            end
        end

      # Process reblog/boost if this is an Announce activity
      reblog_data =
        if is_boost do
          prepare_reblog(get_field(nested, :object))
        else
          nil
        end

      object = get_field(nested, :object)

      media_raw =
        get_field(object, :media) ||
          get_field(get_field(object, :activity), :media) ||
          get_field(activity, :media) ||
          []

      # media_attachments = prepare_media_attachments(media_raw)

      result =
        Map.merge(
          %{
            "visibility" => "private",
            "sensitive" => false,
            "spoiler_text" => "",
            "application" => nil,
            "bookmarked" => false,
            "card" => nil,
            "emojis" => [],
            "favourited" => false,
            "favourites_count" => 0,
            "in_reply_to_account_id" => nil,
            "in_reply_to_id" => nil,
            "language" => nil,
            "mentions" => [],
            "tags" => [],
            "muted" => false,
            "pinned" => false,
            "poll" => nil,
            "reblog" => nil,
            "reblogged" => false,
            "reblogs_count" => 0,
            "replies_count" => 0
          },
          flattened
          |> Map.merge(
            %{}
            |> then(fn map ->
              if account_data, do: Map.put(map, :account, account_data), else: map
            end)
            |> then(fn map ->
              if reblog_data, do: Map.put(map, :reblog, reblog_data), else: map
            end)
          )
          |> Enums.stringify_keys()
        )
    end

    # Prepare the original status for a boost/reblog
    defp prepare_reblog(nil), do: nil

    # Handle Boost objects - unwrap to get the original post
    defp prepare_reblog(%{__typename: "Boost"} = boost) do
      edge = get_field(boost, :edge)
      original_post = get_field(edge, :object)

      if original_post && get_field(original_post, :__typename) == "Post" do
        prepare_reblog(original_post)
      else
        nil
      end
    end

    defp prepare_reblog(%{__typename: "Post"} = post) do
      # Extract post content and activity
      post_content = get_field(post, :post_content) || %{}
      activity = get_field(post, :activity) || %{}

      # Get creator (prefer :creator, fallback to :subject)
      creator = get_field(activity, :creator) || get_field(activity, :subject)

      account =
        if creator do
          Utils.maybe_apply(MeAdapter, :prepare_user, creator, fallback_return: creator)
        else
          nil
        end

      media_raw =
        get_field(post, :media) ||
          get_field(activity, :media) ||
          []

      # media_attachments = prepare_media_attachments(media_raw)

      # Build a status object for the original post
      %{
        "id" => get_field(post, :id),
        "created_at" => get_field(activity, :created_at) || get_field(post, :created_at),
        "uri" => get_field(activity, :uri) || get_field(post, :canonical_uri),
        "url" => get_field(activity, :uri) || get_field(post, :canonical_uri),
        "account" => account,
        "content" =>
          get_field(post_content, :content) || get_field(post_content, :html_body) || "",
        "visibility" => "public",
        "sensitive" => false,
        "spoiler_text" => get_field(post_content, :summary) || "",
        # "media_attachments" => media_attachments,
        "mentions" => [],
        "tags" => [],
        "emojis" => [],
        "reblogs_count" => 0,
        "favourites_count" => 0,
        "replies_count" => 0,
        # Nested reblogs not supported
        "reblog" => nil,
        "application" => nil,
        "language" => nil,
        "muted" => false,
        "bookmarked" => false,
        "pinned" => false,
        "favourited" => false,
        "reblogged" => false,
        "card" => nil,
        "poll" => nil,
        "in_reply_to_id" => nil,
        "in_reply_to_account_id" => nil
      }
      |> Enums.stringify_keys()
    end

    defp prepare_reblog(_), do: nil

    # Status interaction mutations
    # Call Bonfire context functions directly with proper preloads

    def like_status(%{"id" => id} = params, conn) do
      debug(params, "like_status called with params")

      current_user = conn.assigns[:current_user]

      if current_user do
        case Bonfire.Social.Likes.like(current_user, id) do
          {:ok, like_activity} ->
            debug(like_activity, "like created successfully")

            # Get the activity with proper preloads to avoid GraphQL type resolution errors
            opts = [
              preload: [
                :with_subject,
                :with_creator,
                :with_media,
                :with_object_more,
                :with_object_peered,
                :with_reply_to
              ]
            ]

            case Bonfire.Social.Activities.get(id, current_user, opts) do
              {:ok, activity} ->
                prepared =
                  activity
                  |> prepare_activity()
                  |> Map.put("favourited", true)

                Phoenix.Controller.json(conn, prepared)

              {:error, reason} ->
                error(reason, "Failed to fetch activity after like")
                RestAdapter.error_fn({:error, reason}, conn)
            end

          {:error, reason} ->
            error(reason, "like_status error")
            RestAdapter.error_fn({:error, reason}, conn)
        end
      else
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      end
    end

    def unlike_status(%{"id" => id} = params, conn) do
      debug(params, "unlike_status called with params")

      current_user = conn.assigns[:current_user]

      if current_user do
        case Bonfire.Social.Likes.unlike(current_user, id) do
          {:ok, _} ->
            debug(id, "unlike completed successfully")

            # Get the activity with proper preloads
            opts = [
              preload: [
                :with_subject,
                :with_creator,
                :with_media,
                :with_object_more,
                :with_object_peered,
                :with_reply_to
              ]
            ]

            case Bonfire.Social.Activities.get(id, current_user, opts) do
              {:ok, activity} ->
                prepared =
                  activity
                  |> prepare_activity()
                  |> Map.put("favourited", false)

                Phoenix.Controller.json(conn, prepared)

              {:error, reason} ->
                error(reason, "Failed to fetch activity after unlike")
                RestAdapter.error_fn({:error, reason}, conn)
            end

          {:error, reason} ->
            error(reason, "unlike_status error")
            RestAdapter.error_fn({:error, reason}, conn)
        end
      else
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      end
    end

    def boost_status(%{"id" => id} = params, conn) do
      debug(params, "boost_status called with params")

      current_user = conn.assigns[:current_user]

      if current_user do
        case Bonfire.Social.Boosts.boost(current_user, id) do
          {:ok, boost_activity} ->
            debug(boost_activity, "boost created successfully")

            # Get the activity with proper preloads
            opts = [
              preload: [
                :with_subject,
                :with_creator,
                :with_media,
                :with_object_more,
                :with_object_peered,
                :with_reply_to
              ]
            ]

            case Bonfire.Social.Activities.get(id, current_user, opts) do
              {:ok, activity} ->
                prepared =
                  activity
                  |> prepare_activity()
                  |> Map.put("reblogged", true)

                Phoenix.Controller.json(conn, prepared)

              {:error, reason} ->
                error(reason, "Failed to fetch activity after boost")
                RestAdapter.error_fn({:error, reason}, conn)
            end

          {:error, reason} ->
            error(reason, "boost_status error")
            RestAdapter.error_fn({:error, reason}, conn)
        end
      else
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      end
    end

    def unboost_status(%{"id" => id} = params, conn) do
      debug(params, "unboost_status called with params")

      current_user = conn.assigns[:current_user]

      if current_user do
        case Bonfire.Social.Boosts.unboost(current_user, id) do
          {:ok, _} ->
            debug(id, "unboost completed successfully")

            # Get the activity with proper preloads
            opts = [
              preload: [
                :with_subject,
                :with_creator,
                :with_media,
                :with_object_more,
                :with_object_peered,
                :with_reply_to
              ]
            ]

            case Bonfire.Social.Activities.get(id, current_user, opts) do
              {:ok, activity} ->
                prepared =
                  activity
                  |> prepare_activity()
                  |> Map.put("reblogged", false)

                Phoenix.Controller.json(conn, prepared)

              {:error, reason} ->
                error(reason, "Failed to fetch activity after unboost")
                RestAdapter.error_fn({:error, reason}, conn)
            end

          {:error, reason} ->
            error(reason, "unboost_status error")
            RestAdapter.error_fn({:error, reason}, conn)
        end
      else
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      end
    end

    defp prepare_post(post) do
      # TODO: add required fields
      %{
        # "locked"=> false,
      }
      |> Map.merge(
        post
        |> Enums.maybe_flatten()
        |> Enums.stringify_keys()
        # |> Enums.map_put_default(:note, "") # because some clients don't accept nil
      )
    end
  end
end
