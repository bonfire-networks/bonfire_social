if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Social.API.GraphQL do
    @moduledoc "Social API fields/endpoints for GraphQL"

    use Absinthe.Schema.Notation
    use Absinthe.Relay.Schema.Notation, :modern
    use Bonfire.Common.Utils
    import Bonfire.Social
    import Untangle

    alias Absinthe.Resolution.Helpers
    alias Bonfire.API.GraphQL.Pagination

    alias Bonfire.API.GraphQL
    alias Bonfire.Common.Types
    alias Bonfire.Social.Activities

    # import_types(Absinthe.Type.Custom)

    # for pagination 
    connection(node_type: :any_context)

    object :post do
      field(:id, :id)

      # Use Dataloader to batch-load post content (prevents N+1 queries)
      field :post_content, :post_content do
        resolve(Helpers.dataloader(Needle.Pointer, :post_content))
      end

      # Use Dataloader to batch load activity association (prevents N+1)
      field :activity, :activity do
        description("An activity associated with this post (usually the post creation)")
        resolve(Helpers.dataloader(Needle.Pointer, :activity))
      end

      # Media is postloaded via Activities.activity_preloads in feed query
      # No custom resolver needed - just return the postloaded :media field
      field(:media, list_of(:media), description: "Media attached to this post")

      field(:activities, list_of(:activity),
        description: "All activities associated with this post (TODO)"
      )
    end

    object :other do
      field(:json, :json)
    end

    # for pagination 
    connection(node_type: :post)

    object :verb do
      field(:verb, :string)

      field :verb_display, :string do
        resolve(fn
          %{verb: verb}, _, _ ->
            {:ok,
             verb
             |> Activities.verb_maybe_modify()
             |> Activities.verb_display()}
        end)
      end
    end

    object :activity do
      field(:id, :id)

      field(:date, :datetime) do
        resolve(fn %{id: id}, _, _ ->
          {:ok, Bonfire.Common.DatesTimes.date_from_pointer(id)}
        end)
      end

      field(:subject_id, :string)

      field(:subject, :any_character) do
        resolve(Helpers.dataloader(Needle.Pointer))
      end

      field(:object_id, :string)

      field(:canonical_uri, :string) do
        resolve(fn activity, _, _ ->
          # Use preload_if_needed: false to rely on Dataloader batching
          # instead of lazy loading peered/created associations
          {:ok, Bonfire.Common.URIs.canonical_url(activity, preload_if_needed: false)}
        end)
      end

      field(:url, :string) do
        resolve(fn
          %{object: %{id: _} = object}, _, _ ->
            {:ok, Bonfire.Common.URIs.path(object) |> URIs.based_url()}

          activity, _, _ ->
            {:ok, Bonfire.Common.URIs.path(activity) |> URIs.based_url()}
        end)
      end

      field(:verb, :verb) do
        resolve(fn
          %{verb: %{id: _} = verb}, _, _ ->
            {:ok, verb}

          %{activity: %{verb: %{id: _} = verb}}, _, _ ->
            {:ok, verb}

          %{verb_id: verb}, _, _ ->
            {:ok, %{verb: verb}}

          %{verb: %{verb: verb}}, _, _ ->
            {:ok, %{verb: verb}}

          other, _, _ ->
            warn(other, "not verb detected")
            {:ok, nil}
        end)
      end

      # field(:object_id, :string)
      # Use Dataloader to batch-load object pointers, then follow them to get actual objects
      field :object, :any_object do
        resolve(fn activity, _args, %{context: %{loader: loader}} ->
          loader
          |> Dataloader.load(Needle.Pointer, :object, activity)
          |> Helpers.on_load(fn loader ->
            case Dataloader.get(loader, Needle.Pointer, :object, activity) do
              %Needle.Pointer{} = pointer ->
                # Follow the pointer to get the actual object (Boost, Like, Post, etc.)
                case Bonfire.Common.Needles.follow!(pointer, skip_boundary_check: true) do
                  %{__struct__: _} = object -> {:ok, object}
                  _ -> {:ok, nil}
                end

              object when is_struct(object) ->
                {:ok, object}

              _ ->
                {:ok, nil}
            end
          end)
        end)
      end

      # Use Dataloader to batch-load media attachments (prevents N+1 queries)
      # Skip boundary checks for internal API calls (REST layer already authenticated)
      # Media is postloaded via Activities.activity_preloads in feed query
      # No custom resolver needed - just return the postloaded :media field
      field(:media, list_of(:media), description: "Media attached to this activity")

      # Use Dataloader for association loading to prevent N+1 queries
      # Dataloader batches all post_content loads across activities in a single query
      field(:object_post_content, :post_content) do
        resolve(Helpers.dataloader(Needle.Pointer, :object_post_content))
      end

      # Dataloader fields for peered and created associations (prevents N+1 queries)
      field :peered, :peered do
        resolve(Helpers.dataloader(Needle.Pointer, :peered))
      end

      field :created, :created do
        resolve(Helpers.dataloader(Needle.Pointer, :created))
      end

      field :replied, :replied do
        description("Information about the thread, and replies to this activity (if any)")
        resolve(Helpers.dataloader(Needle.Pointer, :replied))
      end

      # field(:direct_replies, list_of(:replied)) do
      #   arg(:paginate, :paginate)

      #   # , args: %{my: :followed})
      #   resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      # end

      # User interaction flags (batch-loaded via Dataloader.KV to prevent N+1 queries)
      field :liked_by_me, :boolean do
        resolve(fn
          activity, _args, %{context: %{loader: loader, current_user: user}} = _info ->
            if user && user.id do
              loader
              |> Dataloader.load(:user_interactions, :liked, %{
                user_id: user.id,
                activity_id: activity.id
              })
              |> Helpers.on_load(fn loader ->
                result =
                  Dataloader.get(loader, :user_interactions, :liked, %{
                    user_id: user.id,
                    activity_id: activity.id
                  })

                {:ok, result || false}
              end)
            else
              {:ok, false}
            end

          _activity, _args, _info ->
            {:ok, false}
        end)
      end

      field :boosted_by_me, :boolean do
        resolve(fn
          activity, _args, %{context: %{loader: loader, current_user: user}} = _info ->
            if user && user.id do
              loader
              |> Dataloader.load(:user_interactions, :boosted, %{
                user_id: user.id,
                activity_id: activity.id
              })
              |> Helpers.on_load(fn loader ->
                result =
                  Dataloader.get(loader, :user_interactions, :boosted, %{
                    user_id: user.id,
                    activity_id: activity.id
                  })

                {:ok, result || false}
              end)
            else
              {:ok, false}
            end

          _activity, _args, _info ->
            {:ok, false}
        end)
      end

      field :bookmarked_by_me, :boolean do
        resolve(fn
          activity, _args, %{context: %{loader: loader, current_user: user}} = _info ->
            if user && user.id do
              loader
              |> Dataloader.load(:user_interactions, :bookmarked, %{
                user_id: user.id,
                activity_id: activity.id
              })
              |> Helpers.on_load(fn loader ->
                result =
                  Dataloader.get(loader, :user_interactions, :bookmarked, %{
                    user_id: user.id,
                    activity_id: activity.id
                  })

                {:ok, result || false}
              end)
            else
              {:ok, false}
            end

          _activity, _args, _info ->
            {:ok, false}
        end)
      end

      # Engagement counts (from EdgeTotal system)
      # Use Dataloader to batch-load count associations, then extract the count value
      field :like_count, :integer do
        resolve(fn
          activity, _args, %{context: %{loader: loader}} = _info ->
            loader
            |> Dataloader.load(Needle.Pointer, :like_count, activity)
            |> Helpers.on_load(fn loader ->
              case Dataloader.get(loader, Needle.Pointer, :like_count, activity) do
                %{object_count: count} when is_integer(count) -> {:ok, count}
                _ -> {:ok, 0}
              end
            end)

          _activity, _args, _info ->
            {:ok, 0}
        end)
      end

      field :boost_count, :integer do
        resolve(fn
          activity, _args, %{context: %{loader: loader}} = _info ->
            loader
            |> Dataloader.load(Needle.Pointer, :boost_count, activity)
            |> Helpers.on_load(fn loader ->
              case Dataloader.get(loader, Needle.Pointer, :boost_count, activity) do
                %{object_count: count} when is_integer(count) -> {:ok, count}
                _ -> {:ok, 0}
              end
            end)

          _activity, _args, _info ->
            {:ok, 0}
        end)
      end

      field :replies_count, :integer do
        resolve(fn
          activity, _args, %{context: %{loader: loader}} = _info ->
            loader
            |> Dataloader.load(Needle.Pointer, :replied, activity)
            |> Helpers.on_load(fn loader ->
              case Dataloader.get(loader, Needle.Pointer, :replied, activity) do
                %{direct_replies_count: count} when is_integer(count) -> {:ok, count}
                _ -> {:ok, 0}
              end
            end)

          _activity, _args, _info ->
            {:ok, 0}
        end)
      end
    end

    connection(node_type: :activity)

    object :post_content do
      field(:name, :string)
      field(:summary, :string)

      @desc "The raw content as stored (may be markdown or HTML depending on editor)"
      field :raw_body, :string do
        resolve(fn post_content, _, _ ->
          {:ok, Map.get(post_content, :html_body)}
        end)
      end

      @desc "The content converted to HTML (for display)"
      field :html_body, :string do
        resolve(fn post_content, _, _ ->
          raw = Map.get(post_content, :html_body)

          html =
            if is_binary(raw) and raw != "" do
              Bonfire.Common.Text.maybe_markdown_to_html(raw, sanitize: true)
            else
              raw
            end

          {:ok, html}
        end)
      end
    end

    input_object :post_content_input do
      field(:name, :string)
      field(:summary, :string)
      field(:html_body, :string)
    end

    object :boost do
      field(:id, :id)

      field :edge, :edge do
        resolve(Helpers.dataloader(Needle.Pointer, :edge))
      end
    end

    object :like do
      field(:id, :id)

      field :edge, :edge do
        resolve(Helpers.dataloader(Needle.Pointer, :edge))
      end
    end

    object :follow do
      field(:id, :id)

      field :edge, :edge do
        resolve(Helpers.dataloader(Needle.Pointer, :edge))
      end
    end

    object :edge do
      field(:id, :id)
      field(:subject_id, :id)
      field(:object_id, :id)
      field(:table_id, :id)

      field :subject, :any_character do
        resolve(Helpers.dataloader(Needle.Pointer, :subject))
      end

      field :object, :any_context do
        resolve(fn edge, _args, %{context: %{loader: loader}} ->
          loader
          |> Dataloader.load(Needle.Pointer, :object, edge)
          |> Helpers.on_load(fn loader ->
            case Dataloader.get(loader, Needle.Pointer, :object, edge) do
              %Needle.Pointer{} = pointer ->
                # Follow the pointer to get the actual object
                case Bonfire.Common.Needles.follow!(pointer, skip_boundary_check: true) do
                  %{__struct__: _} = object -> {:ok, object}
                  _ -> {:ok, nil}
                end

              object when is_struct(object) ->
                {:ok, object}

              _ ->
                {:ok, nil}
            end
          end)
        end)
      end
    end

    object :replied do
      field(:activity, :activity)
      field(:post, :post)
      field(:post_content, :post_content)

      field(:thread_id, :id)
      field(:reply_to_id, :id)

      field :reply_to, :activity do
        description("The activity being replied to")
        resolve(Helpers.dataloader(Needle.Pointer, :reply_to))
      end

      field(:direct_replies_count, :integer)
      field(:nested_replies_count, :integer)

      field(:total_replies_count, :integer)

      # FIXME
      # field(:direct_replies, list_of(:replied)) do
      #   arg(:paginate, :paginate)

      #   # , args: %{my: :followed})
      #   resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      # end
    end

    object :thread_context do
      @desc "Activities that are ancestors of the specified activity (from newest to oldest, towards the root)"
      field(:ancestors, list_of(:activity))

      @desc "Activities that are descendants/replies to the specified activity"
      field(:descendants, list_of(:activity))
    end

    # NOTE: :media object and connection moved to Bonfire.Files.API.GraphQL

    # object :media do
    #   field :id, non_null(:id)

    #   field :path, :string

    #   field :size, :integer

    #   field :media_type, :string

    #   field :metadata, :json

    #   field :creator, :any_character do
    #     resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
    #   end

    #   field(:activity, :activity, description: "An activity associated with this media")

    #   field(:activities, list_of(:activity),
    #     description: "All activities associated with this media (TODO)"
    #   )

    #   field(:objects, list_of(:any_context),
    #     description: "All objects associated with this media (TODO)"
    #   )
    # end

    # connection(node_type: :media)

    # object :posts_page do
    #   field(:page_info, non_null(:page_info))
    #   field(:edges, non_null(list_of(non_null(:post))))
    #   field(:total_count, non_null(:integer))
    # end

    input_object :object_filter do
      field(:object_id, :id, description: "The ID of the object")
    end

    input_object :activity_filter do
      field(:activity_id, :id, description: "The ID of the activity")
      field(:object_id, :id, description: "The ID of the object")
    end

    enum :sort_order do
      value(:asc, description: "Ascending order")
      value(:desc, description: "Descending order")
    end

    enum :sort_by do
      value(:date_created, description: "Sort by date created")
      value(:like_count, description: "Sort by number of likes")
      value(:boost_count, description: "Sort by number of boosts")
      value(:reply_count, description: "Sort by number of replies")
      value(:num_flags, description: "Sort by flags (for moderators) (TODO)")
      value(:latest_reply, description: "Sort by latest reply")

      value(:num_activities,
        description:
          "Sort by number of associated activities, only when querying by object or media (TODO)"
      )
    end

    input_object :feed_filters do
      field(:feed_name, :string,
        description: "Specify which feed to query. For example: explore, my, local, remote"
      )

      field(:feed_ids, list_of(:id),
        description: "Optionally specify feed IDs (overrides feedName) (TODO)"
      )

      field :subjects, list_of(:string), description: "Optionally filter by activity subject IDs"

      field :subject_circles, list_of(:id),
        description:
          "Optionally filter by circle IDs (show posts from users in the specified circles)"

      field :creators, list_of(:string), description: "Optionally filter by object creator IDs"

      field :objects, list_of(:string),
        description: "Optionally filter by the username of the object (TODO)"

      field :tags, list_of(:string),
        description: "Optionally filter by hashtags or @ mentions (TODO)"

      field(:activity_types, list_of(:string),
        description: "Filter by activity type (eg. create, boost, follow) (TODO)"
      )

      field(:object_types, list_of(:string),
        description: "Filter by object type (eg. post, poll) (TODO)"
      )

      field :media_types, list_of(:string),
        description: "Filter by media type (eg. image, video, link) (TODO)"

      field(:time_limit, :integer,
        default_value: nil,
        description: "Include only recent activities (time limit in days) (TODO)"
      )

      field(:sort_by, :sort_by,
        default_value: :date_created,
        description: "Sort by date, likes, boosts, replies, etc..."
      )

      field(:sort_order, :sort_order,
        default_value: :desc,
        description: "Sort in ascending or descending order"
      )

      field(:id_before, :string,
        description:
          "Filter activities with ID less than this (for Mastodon max_id pagination compatibility)"
      )

      field(:id_after, :string,
        description:
          "Filter activities with ID greater than this (for Mastodon since_id/min_id pagination compatibility)"
      )

      field(:preload, list_of(:string),
        description:
          "Preload options to avoid N+1 queries (eg. with_subject, with_creator, with_media)"
      )

      field(:skip_current_user_preload, :boolean,
        default_value: nil,
        description:
          "Set to false to load current user's subject data in feeds (needed for notifications)"
      )
    end

    input_object :post_filters do
      field(:id, :id)
    end

    object :social_queries do
      @desc "Get all posts"
      # field :posts, list_of(:post) do
      #   arg(:paginate, :paginate)
      #   resolve(&list_posts/3)
      # end
      connection field :posts, node_type: :post do
        resolve(&list_posts/3)
      end

      @desc "Get a post"
      field :post, :post do
        arg(:filter, :post_filters)
        resolve(&get_post/3)
      end

      @desc "Get an activity"
      field :activity, :activity do
        arg(:filter, :activity_filter)
        resolve(&get_activity/3)
      end

      @desc "Get an object"
      field :object, :any_object do
        arg(:filter, :object_filter)
        resolve(&get_activity/3)
      end

      @desc "Get thread context (ancestors and descendants) for an activity"
      field :thread_context, :thread_context do
        arg(:id, non_null(:id))
        resolve(&get_thread_context/3)
      end

      @desc "Get activities in a feed"
      # field :feed, list_of(:activity) do
      #   arg(:filter, :feed_filters)
      #   arg(:paginate, :paginate)
      #   resolve(&feed/2)
      # end
      connection field :feed_activities, node_type: :activity do
        arg(:filter, :feed_filters)
        resolve(&feed/2)
      end

      @desc "Get objects in a feed (TODO)"
      connection field :feed_objects, node_type: :any_context do
        arg(:filter, :feed_filters)
        resolve(&feed_objects/2)
      end

      # @desc "Get media in a feed (TODO)"
      # connection field :feed_media, node_type: :media do
      #   arg(:filter, :feed_filters)
      #   resolve(&feed_media/2)
      # end

      @desc "List posts liked by the current user (favourites)"
      connection field :my_likes, node_type: :post do
        resolve(&my_likes/2)
      end

      @desc "List users who liked a specific post/activity"
      field :likers_of, list_of(:user) do
        arg(:id, non_null(:id))
        resolve(&likers_of/3)
      end

      @desc "List users who boosted a specific post/activity"
      field :boosters_of, list_of(:user) do
        arg(:id, non_null(:id))
        resolve(&boosters_of/3)
      end
    end

    object :social_mutations do
      field :create_post, :post do
        arg(:post_content, non_null(:post_content_input))

        arg(:reply_to, :id)
        arg(:to_circles, list_of(:id))

        resolve(&create_post/2)
      end

      field :follow, :activity do
        arg(:username, non_null(:string))
        arg(:id, non_null(:string))

        resolve(&follow/2)
      end

      field :boost, :activity do
        arg(:id, non_null(:string))

        resolve(&boost/2)
      end

      field :like, :activity do
        arg(:id, non_null(:string))

        resolve(&like/2)
      end

      field :unlike, :boolean do
        arg(:id, non_null(:string))

        resolve(&unlike/2)
      end

      field :flag, :activity do
        arg(:id, non_null(:string))

        resolve(&flag/2)
      end
    end

    def list_posts(_parent, args, info) do
      {pagination_args, filters} =
        Pagination.pagination_args_filter(args)

      Bonfire.Posts.list_paginated(filters,
        current_user: GraphQL.current_user(info),
        pagination: pagination_args
      )
      |> Pagination.connection_paginate(pagination_args)
    end

    def get_post(_parent, %{filter: %{id: id}} = _args, info) do
      Bonfire.Posts.read(id, GraphQL.current_user(info))
    end

    def get_activity(_parent, %{filter: %{activity_id: id}} = _args, info) do
      Bonfire.Social.Activities.get(id, GraphQL.current_user(info))
    end

    def get_activity(_parent, %{filter: %{object_id: id}} = _args, info) do
      Bonfire.Social.Activities.read(id, GraphQL.current_user(info))
    end

    def get_thread_context(_parent, %{id: id} = _args, info) do
      current_user = GraphQL.current_user(info)

      # Get ancestors (walking up the reply chain to root)
      ancestor_activities =
        case Bonfire.Social.Threads.determine_thread_path(id, current_user: current_user) do
          path when is_list(path) and length(path) > 0 ->
            # Fetch each ancestor activity with preloads for N+1 prevention
            path
            |> Enum.map(fn ancestor_id ->
              case Bonfire.Social.Activities.read(ancestor_id,
                     current_user: current_user,
                     preload: [:with_subject, :with_media, :with_reply_to]
                   ) do
                {:ok, ancestor_activity} -> ancestor_activity
                _ -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      # Get descendants (replies to this activity)
      # Include with_reply_to preload for threading information
      descendant_activities =
        case Bonfire.Social.Threads.list_replies(id,
               current_user: current_user,
               preload: [:with_reply_to]
             ) do
          %{edges: edges} when is_list(edges) ->
            edges
            |> Enum.map(fn edge ->
              # Extract activity from edge
              case edge do
                %{activity: activity} when not is_nil(activity) -> activity
                %{node: %{activity: activity}} when not is_nil(activity) -> activity
                _ -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      {:ok,
       %{
         ancestors: ancestor_activities,
         descendants: descendant_activities
       }}
    end

    # defp feed(args, info) do
    #   user = GraphQL.current_user(info)
    #   debug(args)

    #   Bonfire.Social.FeedActivities.feed(
    #     Types.maybe_to_atom(e(args, :filter, :feed_name, :local)),
    #     current_user: user,
    #     paginate: e(args, :paginate, nil)
    #   )
    #   |> feed()
    # end
    # defp feed(%{edges: feed}) when is_list(feed) do
    #   {:ok, Enum.map(feed, &Map.get(&1, :activity))}
    # end

    def feed(feed_type \\ :activities, feed_name \\ nil, args, info) do
      current_user = GraphQL.current_user(info)

      {pagination_args, filters} =
        Pagination.pagination_args_filter(args)

      filters = e(filters, :filter, [])

      # Check if feed_name was explicitly provided (even if nil) vs not provided at all
      # This allows callers to explicitly disable feed_name filtering by passing nil
      feed_name_explicitly_set? = is_map(filters) and Map.has_key?(filters, :feed_name)
      feed_name_from_filter = e(filters, :feed_name, nil)

      feed_name_resolved =
        feed_name ||
          if feed_name_explicitly_set? do
            # feed_name was explicitly provided (could be nil to disable filtering)
            Types.maybe_to_atom(feed_name_from_filter)
          else
            # feed_name not provided, use default
            Types.maybe_to_atom(
              Bonfire.Social.FeedLoader.feed_name_or_default(:default, current_user)
            )
          end

      feed_result =
        Bonfire.Social.FeedActivities.feed(
          feed_name_resolved,
          filters,
          current_user: current_user,
          paginate: pagination_args || true,
          # we don't want to preload anything unnecessarily (relying instead on preloads in sub-field definitions)
          preload:
            case e(filters, :preload, nil) || e(filters, "preload", nil) do
              preload_list when is_list(preload_list) and preload_list != [] ->
                # Convert string preload options to atoms (for Mastodon API N+1 optimization)
                Enum.map(preload_list, &Types.maybe_to_atom/1)

              _ ->
                # Fall back to existing logic based on feed_type
                case feed_type do
                  :objects -> :per_object
                  :media -> :per_media
                  _activities -> false
                end
            end
        )
        |> flood("feed_result")

      # Handle error tuples from FeedActivities.feed/3 (e.g., {:error, :unauthorized})
      case feed_result do
        {:error, _} = error ->
          error

        %{edges: edges} when is_list(edges) and length(edges) > 0 ->
          # Apply postloads (same pattern as LiveHandler.do_preload_extras)
          # Media requires postloading because it uses complex join logic
          postloads = [:with_media]

          # Apply postloads to raw feed items before pagination
          # Use preload_nested to tell activity_preloads about the structure
          edges =
            edges
            |> Activities.activity_preloads(postloads,
              current_user: current_user,
              skip_boundary_check: true,
              preload_nested: {[:activity], []}
            )

          feed_paginate(feed_type, %{feed_result | edges: edges}, pagination_args)

        _ ->
          feed_paginate(feed_type, feed_result, pagination_args)
      end
    end

    defp feed_paginate(feed_type \\ nil, feed, pagination_args) do
      Pagination.connection_paginate(feed, pagination_args,
        item_prepare_fun:
          case feed_type do
            :objects ->
              fn fp -> Activities.activity_under_object(e(fp, :activity, nil) || fp) end

            :media ->
              fn fp -> Activities.activity_under_media(e(fp, :activity, nil) || fp) end

            _activities ->
              fn fp -> e(fp, :activity, nil) || fp end
          end
      )
    end

    def feed_objects(feed_name \\ nil, args, info) do
      feed(:objects, feed_name, args, info)
    end

    def feed_media(feed_name \\ nil, args, info) do
      feed(:media, feed_name, args, info)
    end

    # defp my_feed(%{} = parent, _args, _info) do
    #   Bonfire.Social.FeedActivities.my_feed(parent)
    #   |> feed()
    # end

    # defp my_notifications(%User{} = user, _args, _info) do
    #   Bonfire.Social.FeedActivities.feed(:notifications, user)
    #   |> feed()
    # end

    # defp all_flags(%{} = user_or_account, _args, _info) do
    #   Bonfire.Social.Flags.list(user_or_account)
    #   |> feed()
    # end

    # defp feed(%{edges: feed}) when is_list(feed) do
    #   {:ok, Enum.map(feed, &Map.get(&1, :activity))}
    # end
    # defp feed(_), do: {:ok, nil}

    defp create_post(args, info) do
      if user = GraphQL.current_user(info) do
        Bonfire.Posts.publish(post_attrs: args, current_user: user, context: info)
      else
        {:error, "Not authenticated"}
      end
    end

    defp follow(%{username: username_to_follow}, info) do
      # Follows.follow already supports username
      follow(%{id: username_to_follow}, info)
    end

    defp follow(%{id: to_follow}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Graph.Follows.follow(user, to_follow),
             do: {:ok, e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end

    defp boost(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Boosts.boost(user, id),
             do: {:ok, e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end

    defp like(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Likes.like(user, id),
             do: {:ok, e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end

    defp unlike(%{id: id}, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, _} <- Bonfire.Social.Likes.unlike(user, id) do
        {:ok, true}
      end
    end

    def my_likes(args, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
        {pagination_args, _filters} = Pagination.pagination_args_filter(args)

        Bonfire.Social.Likes.list_my(
          current_user: user,
          paginate: pagination_args
        )
        |> Pagination.connection_paginate(pagination_args,
          item_prepare_fun: fn like ->
            # Return the liked post directly (node_type is now :post)
            e(like, :edge, :object, nil) || e(like, :object, nil)
          end
        )
      end
    end

    defp likers_of(_parent, %{id: id}, info) do
      list_interaction_subjects(Bonfire.Social.Likes, id, info)
    end

    defp boosters_of(_parent, %{id: id}, info) do
      list_interaction_subjects(Bonfire.Social.Boosts, id, info)
    end

    # Shared helper for listing users who performed an interaction (like/boost) on an object
    defp list_interaction_subjects(module, id, info) do
      case module.list_of(id, current_user: GraphQL.current_user(info), preload: :subject) do
        %{edges: edges} ->
          users =
            edges
            |> Enum.map(fn edge -> e(edge, :edge, :subject, nil) || e(edge, :subject, nil) end)
            |> Enum.reject(&is_nil/1)

          {:ok, users}

        _ ->
          {:ok, []}
      end
    end

    defp flag(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Flags.flag(user, id),
             do: {:ok, e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end
  end
end
