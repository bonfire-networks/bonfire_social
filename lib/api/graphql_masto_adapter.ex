if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQLMasto.Adapter do
    @moduledoc "Social API endpoints for Mastodon-compatible client apps, powered by the GraphQL API (see `Bonfire.Social.API.GraphQL`)"

    use Arrows
    import Untangle
    use Bonfire.Common.Repo

    use AbsintheClient,
      schema: Bonfire.API.GraphQL.Schema,
      action: [mode: :internal]

    # Custom pipeline to ensure context has dataloader for both authenticated and unauthenticated requests
    def absinthe_pipeline(schema, opts) do
      context = Keyword.get(opts, :context, %{})

      context_with_loader =
        if Map.has_key?(context, :loader) do
          context
        else
          schema.context(context)
        end

      AbsintheClient.default_pipeline(schema, Keyword.put(opts, :context, context_with_loader))
    end

    alias Bonfire.API.GraphQL.RestAdapter

    alias Bonfire.API.MastoCompat.{
      Schemas,
      Mappers,
      InteractionHandler,
      Helpers,
      PaginationHelpers,
      Fragments
    }

    import Helpers, only: [get_field: 2]
    alias Bonfire.Common.Utils

    # Use centralized fragments from bonfire_api_graphql
    @post_content Fragments.post_content()
    @user Fragments.user_profile()
    @media Fragments.media()

    @activity_in_object "
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
    "

    # NOTE: not needed since we load object_post_content and media on activity
    # @on_post "
    # ... on Post {
    #     id
    #     post_content {
    #       #{@post_content}
    #     }
    #     media {
    #       #{@media}
    #     }
    #     @activity_in_object
    #   }
    # "

    # TODO: add support for Polls and other object types here
    @on_object_types "
    ... on Other {
      json
    }
    "

    # Activity fragment for feeds - includes Boost spread for timeline items
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
      #{@on_object_types}
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

    # Simpler activity fragment for thread context (ancestors/descendants are posts, not boosts)
    # The any_context union doesn't include Boost type, so we can't spread on it
    @thread_activity "
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
      #{@on_object_types}
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
      current_user = conn.assigns[:current_user]
      notification_filters = extract_notification_filters(conn.params)

      graphql(conn, :notifications, params)
      |> process_feed_edges_with_batch_loading(current_user, "notification")
      |> apply_notification_filters(notification_filters)
      |> then(&respond_with_feed(conn, params, &1))
    end

    @doc "Get a single notification by ID"
    def notification(id, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case Bonfire.Social.Activities.get(id, current_user: current_user) do
          {:ok, activity} ->
            notification =
              Mappers.Notification.from_activity(
                activity,
                current_user: current_user
              )

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

    defp apply_notification_filters({:ok, items, page_info}, filters) do
      filtered_items = filter_notifications(items, filters)
      {:ok, filtered_items, page_info}
    end

    defp apply_notification_filters({:error, _} = error, _filters), do: error

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

    defp filter_notifications(notifications, %{types: nil, exclude_types: nil, account_id: nil}) do
      notifications
    end

    defp filter_notifications(notifications, filters) do
      Enum.filter(notifications, fn notification ->
        type = Map.get(notification, "type")
        account = Map.get(notification, "account")
        account_id = if account, do: Map.get(account, "id"), else: nil

        type_match =
          cond do
            filters.types != nil -> type in filters.types
            filters.exclude_types != nil -> type not in filters.exclude_types
            true -> true
          end

        account_match = is_nil(filters.account_id) || account_id == filters.account_id

        type_match && account_match
      end)
    end

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

    defp process_favourites_result(response, current_user) do
      case response do
        %{data: %{my_likes: %{edges: edges, page_info: page_info}}} when is_list(edges) ->
          object_ids =
            edges
            |> Enum.flat_map(fn edge ->
              post = Map.get(edge, :node) || edge
              post_id = Map.get(post, :id)
              activity_object_id = get_in(post, [:activity, :object_id])
              [post_id, activity_object_id]
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          interaction_states =
            batch_load_interaction_states(current_user, object_ids)
            |> then(fn states ->
              Enum.reduce(object_ids, states, fn id, acc ->
                Map.update(acc, id, %{favourited: true}, &Map.put(&1, :favourited, true))
              end)
            end)

          mentions_by_object = batch_load_mentions(object_ids)

          statuses =
            edges
            |> Enum.flat_map(fn edge ->
              post = Map.get(edge, :node) || edge
              activity = Map.get(post, :activity)

              activity_data =
                if activity do
                  Map.put(activity, :object, post)
                else
                  %{id: Map.get(post, :id), object_id: Map.get(post, :id), object: post}
                end

              status =
                Mappers.Status.from_activity(%{node: activity_data},
                  current_user: current_user,
                  interaction_states: interaction_states,
                  mentions_by_object: mentions_by_object
                )

              case Schemas.Status.validate(status) do
                {:ok, valid_status} ->
                  [valid_status]

                {:error, {:missing_fields, fields}} ->
                  warn(fields, "Favourites status missing required fields")
                  []

                {:error, _} ->
                  []
              end
            end)

          page_info_with_cursor = Map.put(page_info, :cursor_fields, id: :desc)
          {:ok, statuses, page_info_with_cursor}

        %{errors: errors} ->
          {:error, errors}

        other ->
          error(other, "Unexpected result from my_likes GraphQL query")
          {:error, :unexpected_response}
      end
    end

    @graphql "query ($filter: ActivityFilter) {
      activity(filter: $filter) {
        #{@activity}
      }
    }"
    @doc "Get single status by ID"
    def show_status(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      case graphql(conn, :show_status, %{"filter" => %{"object_id" => id}}) do
        %{data: %{activity: activity}} when not is_nil(activity) ->
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
          error(errors, "GraphQL query failed in show_status")
          RestAdapter.error_fn({:error, errors}, conn)

        other ->
          error(other, "Unexpected GraphQL response in show_status")
          RestAdapter.error_fn({:error, :unexpected_response}, conn)
      end
    end

    @doc "Get the source (raw text) of a status for editing"
    def status_source(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      # Use direct database query - simpler and doesn't require user for public posts
      case Bonfire.Posts.read(id, current_user: current_user, preload: [:post_content]) do
        {:ok, post} ->
          post_content = Map.get(post, :post_content) || %{}

          source = %{
            "id" => id,
            "text" => Map.get(post_content, :html_body) || "",
            "spoiler_text" => Map.get(post_content, :summary) || ""
          }

          Phoenix.Controller.json(conn, source)

        {:error, :not_found} ->
          RestAdapter.error_fn({:error, :not_found}, conn)

        {:error, _reason} ->
          RestAdapter.error_fn({:error, :not_found}, conn)
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

        case Bonfire.Social.PostContents.edit(current_user, id, attrs) do
          {:ok, post} ->
            # Reload with associations for mapping
            case Bonfire.Posts.read(post.id, current_user: current_user, preload: [:post_content, :activity]) do
              {:ok, post} ->
                status = Mappers.Status.from_post(post, current_user: current_user)
                Phoenix.Controller.json(conn, status)

              _ ->
                # Fallback - return minimal status
                Phoenix.Controller.json(conn, %{"id" => id})
            end

          {:error, :not_found} ->
            RestAdapter.error_fn({:error, :not_found}, conn)

          {:error, _reason} ->
            RestAdapter.error_fn({:error, :forbidden}, conn)
        end
      end
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

    @graphql "query ($id: ID!) {
      thread_context(id: $id) {
        ancestors {
          #{@thread_activity}
        }
        descendants {
          #{@thread_activity}
        }
      }
    }"
    @doc "Get thread context (ancestors and descendants)"
    def status_context(%{"id" => id}, conn) do
      current_user = conn.assigns[:current_user]

      case graphql(conn, :status_context, %{"id" => id}) do
        %{data: %{thread_context: %{ancestors: ancestors, descendants: descendants}}} ->
          all_activities = (ancestors || []) ++ (descendants || [])
          object_ids = all_activities |> Enum.map(&get_activity_id/1) |> Enum.reject(&is_nil/1)
          interaction_states = batch_load_interaction_states(current_user, object_ids)
          map_opts = [current_user: current_user, interaction_states: interaction_states]

          context = %{
            "ancestors" => Enum.map(ancestors || [], &Mappers.Status.from_activity(&1, map_opts)),
            "descendants" =>
              Enum.map(descendants || [], &Mappers.Status.from_activity(&1, map_opts))
          }

          Phoenix.Controller.json(conn, context)

        %{data: %{thread_context: nil}} ->
          Phoenix.Controller.json(conn, %{"ancestors" => [], "descendants" => []})

        %{errors: errors} ->
          error(errors, "GraphQL query failed in status_context")
          RestAdapter.error_fn({:error, errors}, conn)

        other ->
          error(other, "Unexpected GraphQL response in status_context")
          Phoenix.Controller.json(conn, %{"ancestors" => [], "descendants" => []})
      end
    end

    @graphql "query ($id: ID!) {
      likers_of(id: $id) {
        #{@user}
      }
    }"
    def status_favourited_by(%{"id" => id}, conn) do
      list_status_interactors(conn, :status_favourited_by, :likers_of, id)
    end

    @graphql "query ($id: ID!) {
      boosters_of(id: $id) {
        #{@user}
      }
    }"
    def status_reblogged_by(%{"id" => id}, conn) do
      list_status_interactors(conn, :status_reblogged_by, :boosters_of, id)
    end

    defp list_status_interactors(conn, query_name, data_key, id) do
      current_user = conn.assigns[:current_user]

      case graphql(conn, query_name, %{"id" => id}) do
        %{data: data} when is_map(data) ->
          users = Map.get(data, data_key, [])

          accounts =
            users
            |> Enum.map(
              &Mappers.Account.from_user(&1,
                current_user: current_user,
                skip_expensive_stats: true
              )
            )
            |> Enum.reject(&is_nil/1)

          Phoenix.Controller.json(conn, accounts)

        %{errors: errors} ->
          RestAdapter.error_fn({:error, errors}, conn)

        _other ->
          Phoenix.Controller.json(conn, [])
      end
    end

    defp get_activity_id(%{object_id: id}), do: id
    defp get_activity_id(%{id: id}), do: id
    defp get_activity_id(_), do: nil

    defp get_all_object_ids(activity) do
      main_id = get_activity_id(activity)
      nested_ids = extract_nested_object_ids(activity)
      [main_id | nested_ids]
    end

    defp extract_nested_object_ids(activity) do
      object = Map.get(activity, :object) || %{}
      typename = Map.get(object, :__typename) || Map.get(object, "__typename")

      case typename do
        "Boost" ->
          edge = Map.get(object, :edge) || %{}
          nested_object = Map.get(edge, :object) || %{}
          nested_id = Map.get(nested_object, :id)
          if nested_id, do: [nested_id], else: []

        "Post" ->
          post_id = Map.get(object, :id)
          if post_id, do: [post_id], else: []

        _ ->
          []
      end
    end

    defp batch_load_interaction_states(nil, _object_ids), do: %{}
    defp batch_load_interaction_states(_user, []), do: %{}

    defp batch_load_interaction_states(current_user, object_ids) do
      liked_ids = batch_load_liked(current_user, object_ids)
      boosted_ids = batch_load_boosted(current_user, object_ids)
      bookmarked_ids = batch_load_bookmarked(current_user, object_ids)

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

    defp batch_load_interaction(current_user, object_ids, interaction_module) do
      Bonfire.Social.Edges.batch_exists?(interaction_module, current_user, object_ids)
    end

    defp batch_load_liked(current_user, object_ids),
      do: batch_load_interaction(current_user, object_ids, Bonfire.Data.Social.Like)

    defp batch_load_boosted(current_user, object_ids),
      do: batch_load_interaction(current_user, object_ids, Bonfire.Data.Social.Boost)

    defp batch_load_bookmarked(current_user, object_ids),
      do: batch_load_interaction(current_user, object_ids, Bonfire.Data.Social.Bookmark)

    defp batch_load_mentions([]), do: %{}

    defp batch_load_mentions(object_ids) do
      import Ecto.Query
      alias Bonfire.Tag.Tagged

      base_map = Map.new(object_ids, fn id -> {id, []} end)

      tagged_records =
        from(t in Tagged,
          where: t.id in ^object_ids,
          preload: [tag: [:character, :profile]]
        )
        |> repo().all()

      mentions_map =
        tagged_records
        |> Enum.group_by(& &1.id)
        |> Enum.map(fn {object_id, tags} ->
          mentions =
            tags
            |> Enum.filter(fn tagged ->
              tag = tagged.tag
              character = tag && Map.get(tag, :character)

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

      Map.merge(base_map, mentions_map)
    end

    defp batch_load_subjects([]), do: %{}

    defp batch_load_subjects(subject_ids) do
      import Ecto.Query
      alias Bonfire.Data.Identity.User

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

      found_user_ids = Map.keys(users_map)
      missing_ids = Enum.reject(subject_ids, &(&1 in found_user_ids))

      characters_map =
        if missing_ids != [] do
          pointers =
            from(p in Needle.Pointer,
              where: p.id in ^missing_ids
            )
            |> repo().all()
            |> repo().maybe_preload([:character, :profile, :peered])

          pointers
          |> Enum.filter(fn p ->
            char = Map.get(p, :character)
            is_map(char) && !match?(%Ecto.Association.NotLoaded{}, char)
          end)
          |> Enum.map(fn p ->
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

      Map.merge(characters_map, users_map)
    end

    defp extract_subject_ids_for_batch_load(edges) do
      edges
      |> Enum.flat_map(fn edge ->
        activity = Map.get(edge, :node) || edge
        account = Map.get(activity, :account)
        subject_id = Map.get(activity, :subject_id)

        if subject_id && (is_nil(account) || account == %{} || !is_map(account)) do
          [subject_id]
        else
          []
        end
      end)
      |> Enum.uniq()
    end

    defp batch_load_post_content([]), do: %{}

    defp batch_load_post_content(post_ids) do
      import Ecto.Query
      alias Bonfire.Data.Social.PostContent

      from(pc in PostContent, where: pc.id in ^post_ids)
      |> repo().all()
      |> Enum.map(fn pc -> {pc.id, pc} end)
      |> Map.new()
    end

    defp extract_object_ids_for_content_batch_load(edges) do
      edges
      |> Enum.flat_map(fn edge ->
        activity = Map.get(edge, :node) || edge
        object = Map.get(activity, :object) || %{}
        object_post_content = Map.get(activity, :object_post_content)
        object_id = Map.get(activity, :object_id)

        object_has_content =
          is_map(object) && map_size(object) > 0 &&
            (Map.get(object, :post_content) || Map.get(object, "post_content"))

        if object_id && !object_has_content && is_nil(object_post_content) do
          [object_id]
        else
          []
        end
      end)
      |> Enum.uniq()
    end

    defp process_feed_edges_with_batch_loading(feed_response, current_user, feed_type) do
      case feed_response do
        %{data: %{feed_activities: %{edges: edges}}} when is_list(edges) ->
          object_ids =
            edges
            |> Enum.flat_map(fn edge ->
              activity = Map.get(edge, :node) || edge
              get_all_object_ids(activity)
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          interaction_states = batch_load_interaction_states(current_user, object_ids)
          mentions_by_object = batch_load_mentions(object_ids)

          prepare_fn =
            case feed_type do
              "notification" ->
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

          process_feed_edges(feed_response, prepare_fn, feed_type)

        other ->
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

    defp process_feed_edges(feed_response, prepare_fn, feed_type) do
      case feed_response do
        %{data: %{feed_activities: %{edges: edges, page_info: page_info}}} when is_list(edges) ->
          items =
            edges
            |> Enum.flat_map(fn edge ->
              case prepare_fn.(edge) do
                nil ->
                  []

                item when is_map(item) ->
                  [item]

                other ->
                  warn(other, "#{String.capitalize(feed_type)} mapper returned unexpected type")
                  []
              end
            end)

          {:ok, items, page_info}

        %{errors: errors} ->
          {:error, errors}

        other ->
          warn(other, "unexpected_#{feed_type}_response, returning empty list")
          {:ok, [], %{}}
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

    def pin_status(%{"id" => id} = params, conn) do
      debug(params, "pin_status called with params")
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        # Wrap in try/rescue to handle federation errors gracefully
        # The pin creation may succeed but federation may fail
        result =
          try do
            Bonfire.Social.Pins.pin(current_user, id)
          rescue
            e in RuntimeError ->
              # Check if pin was actually created despite federation error
              if Bonfire.Social.Pins.pinned?(current_user, id) do
                {:ok, :already_pinned}
              else
                {:error, e.message}
              end
          end

        case result do
          {:ok, _pin} ->
            fetch_and_respond_with_pin_state(conn, current_user, id, true)

          {:error, reason} ->
            error(reason, "pin_status error")
            RestAdapter.error_fn({:error, reason}, conn)
        end
      end
    end

    def unpin_status(%{"id" => id} = params, conn) do
      debug(params, "unpin_status called with params")
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
        preload: [
          :with_subject,
          :with_creator,
          :with_media,
          :with_object_more,
          :with_object_peered,
          :with_reply_to
        ]
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

    @graphql "query ($filter: SearchFilters!) {
      search_activities(filter: $filter) {
        #{@activity}
      }
    }"
    def search_activities_gql(params, conn) do
      graphql(conn, :search_activities_gql, params)
    end

    @graphql "query ($filter: SearchFilters!) {
      search_users(filter: $filter) {
        #{@user}
      }
    }"
    def search_users_gql(params, conn) do
      graphql(conn, :search_users_gql, params)
    end

    @doc "Search for statuses/posts, called by the Search adapter."
    def search_statuses_for_api(query, opts, conn) do
      search_statuses(query, opts, conn)
    end

    defp search_statuses(query, opts, conn) do
      current_user = opts[:current_user]

      case search_via_graphql_raw(conn, :search_activities_gql, :search_activities, query, opts) do
        {:ok, activities} when is_list(activities) and activities != [] ->
          object_ids =
            activities
            |> Enum.map(&get_activity_id/1)
            |> Enum.reject(&is_nil/1)

          interaction_states = batch_load_interaction_states(current_user, object_ids)

          activities
          |> Enum.flat_map(fn activity ->
            case Mappers.Status.from_activity(activity,
                   current_user: current_user,
                   interaction_states: interaction_states
                 ) do
              status when is_map(status) and map_size(status) > 0 ->
                if Map.get(status, "id"), do: [status], else: []

              _ ->
                []
            end
          end)

        _ ->
          []
      end
    end

    defp search_via_graphql_raw(conn, query_name, response_key, query, opts) do
      filter = %{
        "query" => query,
        "limit" => opts[:limit] || 20,
        "offset" => opts[:offset] || 0
      }

      case graphql(conn, query_name, %{"filter" => filter}) do
        %{data: data} when is_map(data) ->
          {:ok, Map.get(data, response_key, [])}

        _ ->
          {:error, :no_results}
      end
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
    def list_reports(params, conn) do
      current_user = conn.assigns[:current_user]

      with {:ok, current_user} <- require_user(current_user) do
        result =
          Flags.list_by(current_user,
            current_user: current_user,
            paginate?: false,
            skip_boundary_check: true,
            preload: :object_with_creator
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
  end
end
