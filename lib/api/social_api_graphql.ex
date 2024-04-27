if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Social.API.GraphQL do
    use Absinthe.Schema.Notation
    use Absinthe.Relay.Schema.Notation, :modern
    use Bonfire.Common.Utils
    import Bonfire.Social.Integration
    import Untangle

    alias Absinthe.Resolution.Helpers
    alias Bonfire.API.GraphQL.Pagination

    alias Bonfire.API.GraphQL
    alias Bonfire.Common.Types
    alias Bonfire.Social.Activities

    # import_types(Absinthe.Type.Custom)

    object :post do
      field(:id, :id)
      field(:post_content, :post_content)
      field(:activity, :activity)
    end

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
            {:ok, Bonfire.Common.URIs.path(object)}

          activity, _, _ ->
            {:ok, Bonfire.Common.URIs.path(activity)}
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
        resolve(&activity_object/3)
      end

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
            warn(activity, "no post_content detected")
            {:ok, nil}
        end)
      end

      field(:direct_replies, list_of(:replied)) do
        # TODO
        arg(:paginate, :paginate)

        # , args: %{my: :followed})
        resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      end
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

      field(:direct_replies, list_of(:replied)) do
        # TODO
        arg(:paginate, :paginate)

        # , args: %{my: :followed})
        resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      end
    end

    # object :posts_page do
    #   field(:page_info, non_null(:page_info))
    #   field(:edges, non_null(list_of(non_null(:post))))
    #   field(:total_count, non_null(:integer))
    # end

    input_object :activity_filters do
      field(:activity_id, :id)
      field(:object_id, :id)
    end

    input_object :feed_filters do
      # TODO: other filters?
      field(:feed_name, :string)
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
        arg(:filter, :activity_filters)
        resolve(&get_activity/3)
      end

      @desc "Get activities in a feed"
      # field :feed, list_of(:activity) do
      #   arg(:filter, :feed_filters)
      #   arg(:paginate, :paginate)
      #   resolve(&feed/2)
      # end
      connection field :feed, node_type: :activity do
        arg(:filter, :feed_filters)
        resolve(&feed/2)
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

    def activity_object(%{activity: %{object: _object} = activity}, _, _) do
      activity_object(activity)
    end

    def activity_object(%{object: _object} = activity, _, _) do
      activity_object(activity)
    end

    def activity_object(activity) do
      {:ok, Activities.object_from_activity(activity)}
    end

    # defp feed(args, info) do
    #   user = GraphQL.current_user(info)
    #   debug(args)

    #   Bonfire.Social.FeedActivities.feed(
    #     Types.maybe_to_atom(Utils.e(args, :filter, :feed_name, :local)),
    #     current_user: user,
    #     paginate: Utils.e(args, :paginate, nil)
    #   )
    #   |> feed()
    # end
    # defp feed(%{edges: feed}) when is_list(feed) do
    #   {:ok, Enum.map(feed, &Map.get(&1, :activity))}
    # end

    def feed(feed_name \\ nil, args, info) do
      {pagination_args, filters} =
        Pagination.pagination_args_filter(args)
        |> debug()

      Bonfire.Social.FeedActivities.feed(
        feed_name || Types.maybe_to_atom(Utils.e(filters, :filter, :feed_name, :local)),
        current_user: GraphQL.current_user(info),
        pagination: pagination_args
      )
      |> Pagination.connection_paginate(pagination_args,
        item_prepare_fun: fn fp -> e(fp, :activity, nil) || fp end
      )
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
      user = GraphQL.current_user(info)

      if user do
        Bonfire.Posts.publish(post_attrs: args, current_user: user)
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
             do: {:ok, Utils.e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end

    defp boost(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Boosts.boost(user, id),
             do: {:ok, Utils.e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end

    defp like(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Likes.like(user, id),
             do: {:ok, Utils.e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end

    defp flag(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Flags.flag(user, id),
             do: {:ok, Utils.e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end
  end
end
