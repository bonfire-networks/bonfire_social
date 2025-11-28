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
    alias Bonfire.API.MastoCompat.{Schemas, Mappers, InteractionHandler, Helpers}
    import Helpers, only: [get_field: 2]
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

    @circle "
    id
    name
    summary
    "

    @circle_member "
    id
    subject_id: subjectId
    subject {
      ... on User {
        #{@user}
      }
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
        types: extract_types_filter(params["types"]) || extract_types_filter(params["types[]"]),
        exclude_types:
          extract_types_filter(params["exclude_types"]) ||
            extract_types_filter(params["exclude_types[]"]),
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
      Enum.filter(notifications, fn notification ->
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
    # Uses GraphQL my_likes query which returns posts (node_type: :post)
    # The post's activity field is resolved via Dataloader for efficiency
    @graphql "query ($first: Int, $last: Int, $after: String, $before: String) {
      my_likes(first: $first, last: $last, after: $after, before: $before) {
        edges { node {
          id
          post_content {
            #{@post_content}
          }
          activity {
            #{@activity}
          }
        }}
        page_info: pageInfo {
          has_next_page: hasNextPage
          has_previous_page: hasPreviousPage
          start_cursor: startCursor
          end_cursor: endCursor
        }
      }
    }"
    @doc "Get posts favourited/liked by the current user"
    def favourites(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        graphql(conn, :favourites, params)
        |> process_favourites_result(current_user)
        |> then(&respond_with_feed(conn, params, &1))
      end
    end

    # Process my_likes GraphQL result into Status objects
    defp process_favourites_result(response, current_user) do
      case response do
        %{data: %{my_likes: %{edges: edges, page_info: page_info}}} when is_list(edges) ->
          # Extract object IDs for batch loading interaction states
          object_ids =
            edges
            |> Enum.flat_map(fn edge ->
              post = Map.get(edge, :node) || edge
              # Get post ID and also check activity's object_id
              post_id = Map.get(post, :id)
              activity_object_id = get_in(post, [:activity, :object_id])
              [post_id, activity_object_id]
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          # Batch load interaction states (likes are known: user favourited these)
          # But we still need boost/bookmark states
          interaction_states = batch_load_interaction_states(current_user, object_ids)

          # Override favourited to true for all items (since they're in favourites list)
          interaction_states =
            Enum.reduce(object_ids, interaction_states, fn id, acc ->
              Map.update(acc, id, %{favourited: true}, &Map.put(&1, :favourited, true))
            end)

          # Batch load mentions
          mentions_by_object = batch_load_mentions(object_ids)

          # Transform to statuses - use the nested activity for from_activity mapper
          statuses =
            edges
            |> Enum.flat_map(fn edge ->
              try do
                post = Map.get(edge, :node) || edge
                # Use the activity nested within the post for the mapper
                activity = Map.get(post, :activity)

                # Build activity-like structure if activity exists
                activity_data =
                  if activity do
                    # Merge post data into activity's object for the mapper
                    Map.put(activity, :object, post)
                  else
                    # Fallback: construct minimal activity-like map from post
                    %{
                      id: Map.get(post, :id),
                      object_id: Map.get(post, :id),
                      object: post
                    }
                  end

                status =
                  Mappers.Status.from_activity(%{node: activity_data},
                    current_user: current_user,
                    interaction_states: interaction_states,
                    mentions_by_object: mentions_by_object
                  )

                # Validate using Schema per mastodon-api skill guidelines
                case Schemas.Status.validate(status) do
                  {:ok, valid_status} -> [valid_status]
                  {:error, {:missing_fields, fields}} ->
                    warn(fields, "Favourites status missing required fields")
                    []
                  {:error, _} -> []
                end
              rescue
                e ->
                  error(e, "Failed to transform liked post to status")
                  []
              end
            end)

          # Add cursor_fields to page_info so Link headers use correct cursor format
          page_info_with_cursor = Map.put(page_info, :cursor_fields, id: :desc)

          {:ok, statuses, page_info_with_cursor}

        %{errors: errors} ->
          {:error, errors}

        other ->
          error(other, "Unexpected result from my_likes GraphQL query")
          {:error, :unexpected_response}
      end
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
    # Uses GraphQL likers_of query for consistency
    @graphql "query ($id: ID!) {
      likers_of(id: $id) {
        #{@user}
      }
    }"
    def status_favourited_by(%{"id" => id}, conn) do
      list_status_interactors(conn, :status_favourited_by, :likers_of, id)
    end

    # Get accounts who reblogged/boosted a status
    # Uses GraphQL boosters_of query for consistency
    @graphql "query ($id: ID!) {
      boosters_of(id: $id) {
        #{@user}
      }
    }"
    def status_reblogged_by(%{"id" => id}, conn) do
      list_status_interactors(conn, :status_reblogged_by, :boosters_of, id)
    end

    # Shared helper for listing users who interacted with a status (liked/boosted)
    defp list_status_interactors(conn, query_name, data_key, id) do
      current_user = conn.assigns[:current_user]

      case graphql(conn, query_name, %{"id" => id}) do
        %{data: data} when is_map(data) ->
          users = Map.get(data, data_key, [])

          accounts =
            users
            |> Enum.map(&Mappers.Account.from_user(&1, current_user: current_user))
            |> Enum.reject(&is_nil/1)

          Phoenix.Controller.json(conn, accounts)

        %{errors: errors} ->
          RestAdapter.error_fn({:error, errors}, conn)

        _other ->
          Phoenix.Controller.json(conn, [])
      end
    end

    # Helper to extract activity/object ID for batch loading
    # Check object_id first - for Mastodon API, status ID is the object/post ID
    defp get_activity_id(%{object_id: id}), do: id
    defp get_activity_id(%{id: id}), do: id
    defp get_activity_id(_), do: nil

    # Extract all object IDs from an activity, including nested reblog IDs
    # This is used for batch loading mentions to ensure reblogs also get their mentions loaded
    defp get_all_object_ids(activity) do
      main_id = get_activity_id(activity)

      # Extract nested reblog IDs (for Boost activities)
      # Structure: activity.object.edge.object.id (for Boost -> nested Post)
      nested_ids = extract_nested_object_ids(activity)

      [main_id | nested_ids]
    end

    # Extract object IDs from nested structures (boosts, reblogs)
    # Also extracts activity.object.id for Posts since it may differ from activity.object_id
    # (e.g., for notification activities where object_id points to an edge/mention)
    defp extract_nested_object_ids(activity) do
      object = Map.get(activity, :object) || %{}
      # Try both atom and string keys for typename (GraphQL may return either)
      typename = Map.get(object, :__typename) || Map.get(object, "__typename")

      case typename do
        "Boost" ->
          # Boost structure: object.edge.object.id
          edge = Map.get(object, :edge) || %{}
          nested_object = Map.get(edge, :object) || %{}
          nested_id = Map.get(nested_object, :id)
          if nested_id, do: [nested_id], else: []

        "Post" ->
          # Collect the Post's ID since it may differ from activity.object_id
          # This ensures mentions are batch-loaded correctly when from_post uses post.id
          post_id = Map.get(object, :id)
          if post_id, do: [post_id], else: []

        _ ->
          []
      end
    end

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

    # Batch load object IDs for a specific interaction type (like/boost/bookmark)
    # Query edges table directly for better performance
    defp batch_load_interaction(current_user, object_ids, interaction_module) do
      try do
        import Ecto.Query
        alias Bonfire.Data.Edges.Edge
        table_id = interaction_module.__pointers__(:table_id)

        from(e in Edge,
          where: e.subject_id == ^current_user.id,
          where: e.object_id in ^object_ids,
          where: e.table_id == ^table_id,
          select: e.object_id
        )
        |> repo().all()
        |> MapSet.new()
      rescue
        _ -> MapSet.new()
      end
    end

    defp batch_load_liked(current_user, object_ids),
      do: batch_load_interaction(current_user, object_ids, Bonfire.Data.Social.Like)

    defp batch_load_boosted(current_user, object_ids),
      do: batch_load_interaction(current_user, object_ids, Bonfire.Data.Social.Boost)

    defp batch_load_bookmarked(current_user, object_ids),
      do: batch_load_interaction(current_user, object_ids, Bonfire.Data.Social.Bookmark)

    # Batch load mentions (user tags) for multiple objects
    # Returns a map with %{object_id => [%{tag_id, username, canonical_uri, ...}]}
    # Mentions are stored as Tagged records where the tag points to a User/Character
    # IMPORTANT: Returns empty lists for objects without mentions (not missing keys)
    # so extract_mentions can distinguish "no mentions" from "not batch loaded"
    defp batch_load_mentions([]), do: %{}

    defp batch_load_mentions(object_ids) do
      try do
        import Ecto.Query
        alias Bonfire.Tag.Tagged

        # Initialize all object_ids with empty lists
        # This ensures we return a key for every ID, even those without mentions
        base_map = Map.new(object_ids, fn id -> {id, []} end)

        # Query all Tagged records for these objects, preload tag -> character for username
        tagged_records =
          from(t in Tagged,
            where: t.id in ^object_ids,
            preload: [tag: [:character, :profile]]
          )
          |> repo().all()

        # Group by object ID and filter to only user mentions (tags with character data)
        mentions_map =
          tagged_records
          |> Enum.group_by(& &1.id)
          |> Enum.map(fn {object_id, tags} ->
            # Filter to only tags that have character data (user mentions)
            mentions =
              tags
              |> Enum.filter(fn tagged ->
                tag = tagged.tag
                character = tag && Map.get(tag, :character)
                # Has character data (not NotLoaded and not nil)
                is_map(character) && !match?(%Ecto.Association.NotLoaded{}, character) &&
                  map_size(character) > 0
              end)
              |> Enum.map(fn tagged ->
                tag = tagged.tag
                character = Map.get(tag, :character) || %{}

                %{
                  tag_id: tagged.tag_id,
                  character: character,
                  profile: Map.get(tag, :profile)
                }
              end)

            {object_id, mentions}
          end)
          |> Map.new()

        # Merge mentions into base map (overwrites empty lists with actual mentions)
        Map.merge(base_map, mentions_map)
      rescue
        e ->
          error(e, "Failed to batch load mentions")
          %{}
      end
    end

    # Batch load subjects (users/accounts) for notification activities
    # This is needed because the notifications feed doesn't always have subjects preloaded
    # Returns a map with %{subject_id => user_with_profile_and_character}
    defp batch_load_subjects([]), do: %{}

    defp batch_load_subjects(subject_ids) do
      try do
        import Ecto.Query
        alias Bonfire.Data.Identity.User

        # First, try to load as Users (local users have User records)
        users =
          from(u in User,
            where: u.id in ^subject_ids,
            preload: [:profile, :character]
          )
          |> repo().all()

        users_map =
          users
          |> Enum.map(fn user -> {user.id, user} end)
          |> Map.new()

        # Find IDs not found in User table (likely remote/federated users)
        found_user_ids = Map.keys(users_map)
        missing_ids = Enum.reject(subject_ids, &(&1 in found_user_ids))

        # For missing IDs, try to load via Needle.Pointer with mixins
        # Remote users are stored as Pointers with Character/Profile/Peered mixins
        characters_map =
          if missing_ids != [] do
            # Use Needle to load pointers with their mixins
            pointers =
              from(p in Needle.Pointer,
                where: p.id in ^missing_ids
              )
              |> repo().all()
              # Preload mixins that we need for account mapping
              |> repo().maybe_preload([:character, :profile, :peered])

            pointers
            |> Enum.filter(fn p ->
              # Only include if has character data (is a user/actor)
              char = Map.get(p, :character)
              is_map(char) && !match?(%Ecto.Association.NotLoaded{}, char)
            end)
            |> Enum.map(fn p ->
              # Build a user-like map with the loaded mixin data
              # This structure matches what Mappers.Account.from_user expects
              {p.id,
               %{
                 id: p.id,
                 character: Map.get(p, :character),
                 profile: Map.get(p, :profile),
                 peered: Map.get(p, :peered)
               }}
            end)
            |> Map.new()
          else
            %{}
          end

        # Merge both maps (users take precedence)
        Map.merge(characters_map, users_map)
      rescue
        e ->
          error(e, "Failed to batch load subjects")
          %{}
      end
    end

    # Extract subject IDs from activities that don't have subjects loaded
    # Used for batch loading subjects in notifications
    defp extract_subject_ids_for_batch_load(edges) do
      edges
      |> Enum.flat_map(fn edge ->
        activity = Map.get(edge, :node) || edge
        account = Map.get(activity, :account)
        subject_id = Map.get(activity, :subject_id)

        # Only include if we have a subject_id but the account is missing or invalid
        if subject_id && (is_nil(account) || account == %{} || !is_map(account)) do
          [subject_id]
        else
          []
        end
      end)
      |> Enum.uniq()
    end

    # Batch load post content for notification activities
    # This is needed because notifications may not have object/object_post_content loaded
    # Returns a map with %{post_id => %PostContent{}}
    defp batch_load_post_content([]), do: %{}

    defp batch_load_post_content(post_ids) do
      try do
        import Ecto.Query
        alias Bonfire.Data.Social.PostContent

        # Query post content by post IDs
        post_contents =
          from(pc in PostContent,
            where: pc.id in ^post_ids
          )
          |> repo().all()

        # Build map of post_id => post_content
        post_contents
        |> Enum.map(fn pc -> {pc.id, pc} end)
        |> Map.new()
      rescue
        e ->
          error(e, "Failed to batch load post content")
          %{}
      end
    end

    # Extract object IDs from activities that need content loaded
    # Used for batch loading post content in notifications
    defp extract_object_ids_for_content_batch_load(edges) do
      edges
      |> Enum.flat_map(fn edge ->
        activity = Map.get(edge, :node) || edge
        object = Map.get(activity, :object) || %{}
        object_post_content = Map.get(activity, :object_post_content)
        object_id = Map.get(activity, :object_id)

        # Check if object is loaded with post_content
        object_has_content =
          is_map(object) && map_size(object) > 0 &&
            (Map.get(object, :post_content) || Map.get(object, "post_content"))

        # Only include if we have object_id but content isn't loaded
        if object_id && !object_has_content && is_nil(object_post_content) do
          [object_id]
        else
          []
        end
      end)
      |> Enum.uniq()
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

    defp validate_limit(limit) when is_binary(limit) do
      case Integer.parse(limit) do
        {n, _} -> validate_limit(n)
        :error -> 40
      end
    end

    defp validate_limit(limit) when is_integer(limit) and limit > 0 and limit <= 80, do: limit
    defp validate_limit(limit) when is_integer(limit) and limit > 80, do: 80
    defp validate_limit(_), do: 40

    # Process feed edges with batch loading of interaction states and mentions to avoid N+1 queries
    # This extracts object IDs, batch loads interaction states + mentions, then delegates to process_feed_edges
    # For notifications, also batch loads subjects (accounts) since they may not be preloaded
    defp process_feed_edges_with_batch_loading(feed_response, current_user, feed_type) do
      case feed_response do
        %{data: %{feed_activities: %{edges: edges}}} when is_list(edges) ->
          # Extract object IDs from all activities for batch loading
          # This includes both main object IDs and nested reblog IDs
          object_ids =
            edges
            |> Enum.flat_map(fn edge ->
              activity = Map.get(edge, :node) || edge
              get_all_object_ids(activity)
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          # Batch load interaction states in 3 queries total (not N×3)
          interaction_states = batch_load_interaction_states(current_user, object_ids)

          # Batch load mentions (user tags) for all objects in 1 query
          mentions_by_object = batch_load_mentions(object_ids)

          # For notifications, batch load subjects (accounts) and post content
          # since GraphQL Dataloader may not load them properly for the notifications feed
          {subjects_by_id, post_content_by_id} =
            if feed_type == "notification" do
              subject_ids = extract_subject_ids_for_batch_load(edges)
              subjects = batch_load_subjects(subject_ids)

              content_ids = extract_object_ids_for_content_batch_load(edges)
              post_content = batch_load_post_content(content_ids)

              {subjects, post_content}
            else
              {%{}, %{}}
            end

          # Build prepare function with preloaded interaction states and mentions
          prepare_fn =
            case feed_type do
              "notification" ->
                &Mappers.Notification.from_activity(&1,
                  current_user: current_user,
                  interaction_states: interaction_states,
                  mentions_by_object: mentions_by_object,
                  subjects_by_id: subjects_by_id,
                  post_content_by_id: post_content_by_id
                )

              _ ->
                &Mappers.Status.from_activity(&1,
                  current_user: current_user,
                  interaction_states: interaction_states,
                  mentions_by_object: mentions_by_object
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
          # Return empty list instead of error for unexpected responses
          # This prevents clients from showing error messages for edge cases like empty pagination
          warn(other, "unexpected_#{feed_type}_response, returning empty list")
          {:ok, [], %{}}
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

    # Catch-all for unexpected response formats - return empty array instead of crashing
    defp respond_with_feed(conn, _params, other) do
      warn(other, "respond_with_feed received unexpected format, returning empty array")
      Phoenix.Controller.json(conn, [])
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

    # Conversations API (DM threads)
    # Uses Bonfire.Messages to list threads with latest_in_threads option

    @doc """
    List conversations (DM threads) for the current user.

    Returns a list of Mastodon-compatible Conversation objects with:
    - id: thread ID
    - accounts: participants
    - unread: whether there are unseen messages
    - last_status: the most recent message
    """
    def conversations(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        pagination_opts = build_conversation_pagination_opts(params)

        opts =
          Keyword.merge(pagination_opts,
            current_user: current_user,
            latest_in_threads: true,
            # Preloads needed for Conversation/Status mappers:
            # - :with_object_more loads post_content and replied
            # - :with_subject loads activity.subject (sender) for account
            # - :with_seen for unread tracking
            # - :tags for participants
            preload: [:with_object_more, :with_subject, :with_seen, :tags]
          )

        case Bonfire.Messages.list(current_user, nil, opts) do
          %{edges: edges, page_info: page_info} ->
            conversations =
              edges
              |> Enum.map(&Mappers.Conversation.from_thread(&1, current_user: current_user))
              |> Enum.reject(&is_nil/1)

            conn
            |> add_link_headers(params, page_info, conversations)
            |> Phoenix.Controller.json(conversations)

          {:error, reason} ->
            RestAdapter.error_fn({:error, reason}, conn)

          other ->
            error(other, "Unexpected result from Messages.list")
            Phoenix.Controller.json(conn, [])
        end
      end
    end

    @doc """
    Mark a conversation as read.

    Marks all messages in the thread as seen by the current user.
    Returns the updated conversation object.
    """
    def mark_conversation_read(%{"id" => thread_id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        # Mark the thread as seen
        case Bonfire.Social.Seen.mark_seen(current_user, thread_id) do
          {:ok, _} ->
            # Return the updated conversation
            get_single_conversation(thread_id, current_user, conn)

          {:error, reason} ->
            RestAdapter.error_fn({:error, reason}, conn)

          _ ->
            # mark_seen may return different formats, try to get conversation anyway
            get_single_conversation(thread_id, current_user, conn)
        end
      end
    end

    # Get a single conversation by thread ID
    defp get_single_conversation(thread_id, current_user, conn) do
      # Try to load the thread's latest message
      opts = [
        current_user: current_user,
        preload: [:with_object_more, :with_subject, :with_seen, :tags]
      ]

      case Bonfire.Messages.read(thread_id, opts) do
        {:ok, message} ->
          conversation =
            Mappers.Conversation.from_thread(message, current_user: current_user)

          if conversation do
            Phoenix.Controller.json(conn, conversation)
          else
            RestAdapter.error_fn({:error, :not_found}, conn)
          end

        {:error, reason} ->
          RestAdapter.error_fn({:error, reason}, conn)

        _ ->
          RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    # ==========================================
    # Lists API (Mastodon Lists → Bonfire Circles)
    # ==========================================

    @doc """
    Get all lists owned by the authenticated user.

    Returns an array of Mastodon List objects. System circles (built-in and
    stereotypes like followers/blocked) are filtered out, only user-created
    circles are returned.

    Endpoint: GET /api/v1/lists
    """
    @graphql "query ($filter: CircleFilters) {
      my_circles(filter: $filter) {
        #{@circle}
      }
    }"
    def lists(_params, conn) do
      filter = %{
        "exclude_stereotypes" => true,
        "exclude_built_ins" => true
      }

      case graphql(conn, :lists, %{"filter" => filter}) do
        %{data: %{my_circles: circles}} when is_list(circles) ->
          lists =
            circles
            |> Enum.map(&Mappers.List.from_circle/1)
            |> Enum.reject(&is_nil/1)

          Phoenix.Controller.json(conn, lists)

        %{errors: errors} ->
          RestAdapter.error_fn({:error, errors}, conn)

        _ ->
          RestAdapter.error_fn({:error, :unexpected_response}, conn)
      end
    end

    @doc """
    Create a new list.

    Endpoint: POST /api/v1/lists
    """
    @graphql "mutation ($circle: CircleInput!) {
      create_circle(circle: $circle) {
        #{@circle}
      }
    }"
    def create_list(params, conn) do
      with_valid_title(params, conn, fn title ->
        case graphql(conn, :create_list, %{"circle" => %{"name" => title}}) do
          %{data: %{create_circle: circle}} when not is_nil(circle) ->
            list = Mappers.List.from_circle(circle)
            Phoenix.Controller.json(conn, list)

          %{errors: errors} ->
            RestAdapter.error_fn({:error, errors}, conn)

          _ ->
            RestAdapter.error_fn({:error, :unexpected_response}, conn)
        end
      end)
    end

    @doc """
    Get a specific list by ID.

    Endpoint: GET /api/v1/lists/:id
    """
    @graphql "query ($id: ID!) {
      circle(id: $id) {
        #{@circle}
      }
    }"
    def show_list(id, _params, conn) do
      case graphql(conn, :show_list, %{"id" => id}) do
        %{data: %{circle: circle}} when not is_nil(circle) ->
          list = Mappers.List.from_circle(circle)
          Phoenix.Controller.json(conn, list)

        %{data: %{circle: nil}} ->
          RestAdapter.error_fn({:error, :not_found}, conn)

        %{errors: errors} ->
          RestAdapter.error_fn({:error, errors}, conn)

        _ ->
          RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    @doc """
    Update a list (change title).

    Endpoint: PUT /api/v1/lists/:id
    """
    @graphql "mutation ($id: ID!, $circle: CircleInput!) {
      update_circle(id: $id, circle: $circle) {
        #{@circle}
      }
    }"
    def update_list(id, params, conn) do
      with_valid_title(params, conn, fn title ->
        case graphql(conn, :update_list, %{"id" => id, "circle" => %{"name" => title}}) do
          %{data: %{update_circle: circle}} when not is_nil(circle) ->
            list = Mappers.List.from_circle(circle)
            Phoenix.Controller.json(conn, list)

          %{errors: errors} ->
            RestAdapter.error_fn({:error, errors}, conn)

          _ ->
            RestAdapter.error_fn({:error, :unexpected_response}, conn)
        end
      end)
    end

    @doc """
    Delete a list.

    Endpoint: DELETE /api/v1/lists/:id
    """
    @graphql "mutation ($id: ID!) {
      delete_circle(id: $id)
    }"
    def delete_list(id, _params, conn) do
      case graphql(conn, :delete_list, %{"id" => id}) do
        %{data: %{delete_circle: true}} ->
          Phoenix.Controller.json(conn, %{})

        %{errors: errors} ->
          RestAdapter.error_fn({:error, errors}, conn)

        _ ->
          RestAdapter.error_fn({:error, :unexpected_response}, conn)
      end
    end

    @doc """
    Get accounts in a list.

    Returns an array of Mastodon Account objects for all members of the list.

    Endpoint: GET /api/v1/lists/:id/accounts
    """
    @graphql "query ($circle_id: ID!, $limit: Int, $after: String, $before: String) {
      circle_members(circle_id: $circle_id, limit: $limit, after: $after, before: $before) {
        entries {
          #{@circle_member}
        }
        page_info: pageInfo {
          has_next_page: hasNextPage
          has_previous_page: hasPreviousPage
          start_cursor: startCursor
          end_cursor: endCursor
        }
      }
    }"
    def list_accounts(id, params, conn) do
      limit = validate_limit(params["limit"] || 40)

      # Build pagination params from Mastodon params
      pagination_params =
        %{"circle_id" => id, "limit" => limit}
        |> maybe_add_graphql_cursor(params, "max_id", "after")
        |> maybe_add_graphql_cursor(params, "since_id", "before")
        |> maybe_add_graphql_cursor(params, "min_id", "before")

      case graphql(conn, :list_accounts, pagination_params) do
        %{data: %{circle_members: %{entries: entries, page_info: page_info}}}
        when is_list(entries) ->
          accounts =
            entries
            |> Enum.map(fn member ->
              subject = Map.get(member, :subject)
              Mappers.Account.from_user(subject)
            end)
            |> Enum.reject(&is_nil/1)

          # Add Link headers for pagination if we have page_info
          conn =
            if page_info do
              page_info_map = %{
                start_cursor: Map.get(page_info, :start_cursor),
                end_cursor: Map.get(page_info, :end_cursor),
                cursor_fields: [id: :desc]
              }

              add_link_headers(conn, params, page_info_map, entries)
            else
              conn
            end

          Phoenix.Controller.json(conn, accounts)

        %{errors: errors} ->
          RestAdapter.error_fn({:error, errors}, conn)

        _ ->
          RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    # Validate title for list create/update operations
    defp with_valid_title(params, conn, fun) do
      title = params["title"]

      if is_nil(title) or String.trim(title) == "" do
        RestAdapter.error_fn({:error, :unprocessable_entity}, conn)
      else
        fun.(title)
      end
    end

    # Add cursor to GraphQL params (string params)
    defp maybe_add_graphql_cursor(params, mastodon_params, mastodon_key, graphql_key) do
      case mastodon_params[mastodon_key] do
        id when is_binary(id) and id != "" ->
          case encode_encircle_cursor(id) do
            {:ok, cursor} -> Map.put(params, graphql_key, cursor)
            _ -> params
          end

        _ ->
          params
      end
    end

    # Generic cursor encoding for pagination
    defp encode_cursor(id, cursor_map) when is_binary(id) and is_map(cursor_map) do
      if String.match?(id, ~r/^g3[A-Za-z0-9_-]+=*$/) do
        {:ok, id}
      else
        try do
          cursor =
            cursor_map
            |> :erlang.term_to_binary()
            |> Base.url_encode64()

          {:ok, cursor}
        rescue
          _ -> {:error, :encoding_failed}
        end
      end
    end

    defp encode_cursor(_, _), do: {:error, :invalid_id}

    # Encode cursor for Encircle pagination (uses simple :id format)
    defp encode_encircle_cursor(id) when is_binary(id),
      do: encode_cursor(id, %{id: id})

    defp encode_encircle_cursor(_), do: {:error, :invalid_id}

    @doc """
    Add accounts to a list.

    Expects `account_ids` param with an array of account IDs to add.

    Endpoint: POST /api/v1/lists/:id/accounts
    """
    @graphql "mutation ($circle_id: ID!, $subject_ids: [ID!]!) {
      add_to_circle(circle_id: $circle_id, subject_ids: $subject_ids)
    }"
    def add_to_list(id, params, conn) do
      modify_circle_members(conn, id, params, :add_to_list, :add_to_circle)
    end

    @doc """
    Remove accounts from a list.

    Expects `account_ids` param with an array of account IDs to remove.

    Endpoint: DELETE /api/v1/lists/:id/accounts
    """
    @graphql "mutation ($circle_id: ID!, $subject_ids: [ID!]!) {
      remove_from_circle(circle_id: $circle_id, subject_ids: $subject_ids)
    }"
    def remove_from_list(id, params, conn) do
      modify_circle_members(conn, id, params, :remove_from_list, :remove_from_circle)
    end

    # Shared helper for add/remove circle members operations
    defp modify_circle_members(conn, id, params, query_name, data_key) do
      account_ids = params["account_ids"] || []

      case graphql(conn, query_name, %{"circle_id" => id, "subject_ids" => account_ids}) do
        %{data: data} when is_map(data) ->
          if Map.get(data, data_key) == true do
            Phoenix.Controller.json(conn, %{})
          else
            RestAdapter.error_fn({:error, :unexpected_response}, conn)
          end

        %{errors: errors} ->
          RestAdapter.error_fn({:error, errors}, conn)

        _ ->
          RestAdapter.error_fn({:error, :unexpected_response}, conn)
      end
    end

    @doc """
    Get the timeline for a list (posts from list members).

    Returns statuses from accounts in the specified list.

    Endpoint: GET /api/v1/timelines/list/:list_id
    """
    def list_timeline(list_id, params, conn) do
      # Use Bonfire's native subject_circles filter which joins with Encircle table
      # This is more efficient than fetching member IDs and filtering by subjects
      # See: FeedLoader.feed(:custom, %{subject_circles: [circle]}, current_user: me)
      limit = validate_limit(params["limit"] || 20)

      # Extract pagination cursors from Mastodon params
      cursors = extract_mastodon_pagination_cursors(params)

      # Build limit param based on cursor direction (first for forward, last for backward)
      limit_param =
        cond do
          Map.has_key?(cursors, :after) -> %{first: limit}
          Map.has_key?(cursors, :before) -> %{last: limit}
          true -> %{first: limit}
        end

      # Use subject_circles filter to show posts from users in this list (circle)
      # - subject_circles joins with Encircle table to find posts by circle members
      # - time_limit: 0 disables Bonfire's default 1-month time limit
      # - feed_name: nil prevents defaulting to :my (home feed)
      feed_params =
        %{
          "filter" => %{
            "subject_circles" => [list_id],
            "time_limit" => 0,
            "feed_name" => nil
          }
        }
        |> Map.merge(limit_param)
        |> Map.merge(cursors)

      feed(feed_params, conn)
    end

    # Extract entries from either paginated or unpaginated results
    defp extract_entries(%{entries: entries}), do: entries
    defp extract_entries(list) when is_list(list), do: list
    defp extract_entries(_), do: []

    # Extract Mastodon pagination cursors and convert to GraphQL cursor format
    defp extract_mastodon_pagination_cursors(params) do
      params
      |> Map.take(["max_id", "since_id", "min_id"])
      |> Enum.reduce(%{}, fn
        {"max_id", id}, acc when is_binary(id) and id != "" ->
          case encode_id_as_cursor(id) do
            {:ok, cursor} -> Map.put(acc, :after, cursor)
            _ -> acc
          end

        {"min_id", id}, acc when is_binary(id) and id != "" ->
          case encode_id_as_cursor(id) do
            {:ok, cursor} -> Map.put(acc, :before, cursor)
            _ -> acc
          end

        {"since_id", id}, acc when is_binary(id) and id != "" ->
          # Only use since_id if min_id not already set
          if Map.has_key?(acc, :before) do
            acc
          else
            case encode_id_as_cursor(id) do
              {:ok, cursor} -> Map.put(acc, :before, cursor)
              _ -> acc
            end
          end

        _, acc ->
          acc
      end)
    end

    # Encode a plain ID as a GraphQL cursor
    # Bonfire uses cursor_fields: [{{:activity, :id}, :desc}]
    # Encode cursor for activity pagination (uses {:activity, :id} format)
    defp encode_id_as_cursor(id) when is_binary(id),
      do: encode_cursor(id, %{{:activity, :id} => id})

    defp encode_id_as_cursor(_), do: {:error, :invalid_id}

    # Build pagination opts for conversations query
    defp build_conversation_pagination_opts(params) do
      limit = validate_limit(params["limit"] || params[:limit])

      base_opts = [limit: limit]

      base_opts
      |> maybe_add_cursor(params, "max_id", :after)
      |> maybe_add_cursor(params, "since_id", :before)
      |> maybe_add_cursor(params, "min_id", :before)
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
