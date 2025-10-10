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
      field(:post_content, :post_content)

      field(:activity, :activity,
        description: "An activity associated with this post (usually the post creation)"
      )

      field(:activities, list_of(:activity),
        description: "All activities associated with this post (TODO)"
      )
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
             |> debug()
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
        resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      end

      field(:object_id, :string)

      field(:canonical_uri, :string) do
        resolve(fn activity, _, _ ->
          # IO.inspect(activity)
          {:ok, Bonfire.Common.URIs.canonical_url(activity)}
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
      field :object, :any_context do
        resolve(&the_activity_object/3)
      end

      # TODO
      # field :media, :media, description: "Media attached to this activity"

      field(:object_post_content, :post_content) do
        resolve(fn
          %{object: %{post_content: %{id: _} = post_content}}, _, _ ->
            {:ok, post_content |> debug("post_content detected")}

          %{object: %{post_content: _} = object}, _, _ ->
            {:ok,
             object
             |> repo().maybe_preload(:post_content)
             |> e(:post_content, nil)
             |> debug("post_content detected")}

          activity, _, _ ->
            {:ok,
             activity
             |> repo().maybe_preload(:object_post_content)
             |> e(:object_post_content, nil)
             |> debug(
               "no object with post_content detected, tried preloading :object_post_content"
             )}
        end)
      end

      field :replied, :replied,
        description: "Information about the thread, and replies to this activity (if any)"

      # field(:direct_replies, list_of(:replied)) do
      #   arg(:paginate, :paginate)

      #   # , args: %{my: :followed})
      #   resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      # end
    end

    connection(node_type: :activity)

    object :post_content do
      field(:name, :string)
      field(:summary, :string)
      field(:html_body, :string)
    end

    input_object :post_content_input do
      field(:name, :string)
      field(:summary, :string)
      field(:html_body, :string)
    end

    object :replied do
      field(:activity, :activity)
      field(:post, :post)
      field(:post_content, :post_content)

      field(:thread_id, :id)
      field(:reply_to_id, :id)

      # field(:reply_to, :activity)

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
      value(:date, description: "Sort by date")
      value(:num_likes, description: "Sort by number of likes")
      value(:num_boosts, description: "Sort by number of boosts")
      value(:num_replies, description: "Sort by number of replies")
      value(:num_flags, description: "Sort by flags (for moderators) (TODO)")

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

      field :subjects, list_of(:string),
        description: "Optionally filter by activity subject (TODO)"

      field :creators, list_of(:string),
        description: "Optionally filter by object creators (TODO)"

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
        default_value: :date,
        description: "Sort by date, likes, boosts, replies, etc..."
      )

      field(:sort_order, :sort_order,
        default_value: :desc,
        description: "Sort in ascending or descending order"
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
      field :object, :any_context do
        arg(:filter, :object_filter)
        resolve(&get_activity/3)
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

      @desc "Get media in a feed (TODO)"
      connection field :feed_media, node_type: :media do
        arg(:filter, :feed_filters)
        resolve(&feed_media/2)
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

      field :flag, :activity do
        arg(:id, non_null(:string))

        resolve(&flag/2)
      end
    end

    def list_posts(_parent, args, info) do
      {pagination_args, filters} =
        Pagination.pagination_args_filter(args)
        |> debug()

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

    def the_activity_object(%{activity: %{object: _object} = activity}, _, _) do
      do_the_activity_object(activity)
    end

    def the_activity_object(%{object: _object} = activity, _, _) do
      do_the_activity_object(activity)
    end

    defp do_the_activity_object(%{} = activity) do
      {:ok, Activities.object_from_activity(activity)}
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
        |> debug()

      filters = e(filters, :filter, [])

      Bonfire.Social.FeedActivities.feed(
        {feed_name ||
           Types.maybe_to_atom(
             e(filters, :feed_name, nil) ||
               Bonfire.Social.FeedLoader.feed_name_or_default(:default, current_user)
           ), filters},
        current_user: current_user,
        pagination: pagination_args,
        # we don't want to preload anything unnecessarily (relying instead on preloads in sub-field definitions)
        preload:
          case feed_type do
            :objects -> :per_object
            :media -> :per_media
            _activities -> false
          end
      )
      |> Pagination.connection_paginate(pagination_args,
        item_prepare_fun:
          case feed_type do
            :objects -> fn fp -> Activities.activity_under_object(e(fp, :activity, nil) || fp) end
            :media -> fn fp -> Activities.activity_under_media(e(fp, :activity, nil) || fp) end
            _activities -> fn fp -> e(fp, :activity, nil) || fp end
          end
      )
      |> debug("paginated_feed")
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
