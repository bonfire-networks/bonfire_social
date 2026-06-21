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
        resolve(fn
          # use-parent fast path: resolve from the preloaded assoc, skip Dataloader.
          %{post_content: pc}, _args, _info
          when is_struct(pc) and not is_struct(pc, Ecto.Association.NotLoaded) ->
            {:ok, pc}

          post, _args, %{context: %{loader: loader}} ->
            loader
            |> Dataloader.load(Needle.Pointer, :post_content, post)
            |> Helpers.on_load(fn loader ->
              {:ok, Dataloader.get(loader, Needle.Pointer, :post_content, post)}
            end)
        end)
      end

      # Use Dataloader to batch load activity association (prevents N+1)
      field :activity, :activity do
        description("An activity associated with this post (usually the post creation)")
        resolve(Helpers.dataloader(Needle.Pointer, :activity))
      end

      # Media is postloaded via Activities.activity_preloads in feed query
      # No custom resolver needed - just return the postloaded :media field
      field(:media, list_of(:media), description: "Media attached to this post")

      @desc "The post's author. Resolves synchronously from a `:with_creator`-preloaded `created.creator`; falls back to loading the `created` mixin."
      field :creator, :any_character do
        resolve(fn
          post, _args, %{context: %{loader: loader}} ->
            case e(post, :created, :creator, nil) || e(post, :creator, nil) do
              creator
              when is_struct(creator) and not is_struct(creator, Ecto.Association.NotLoaded) ->
                {:ok, creator}

              _ ->
                loader
                |> Dataloader.load(Needle.Pointer, :created, post)
                |> Helpers.on_load(fn loader ->
                  created = Dataloader.get(loader, Needle.Pointer, :created, post)
                  creator = e(created, :creator, nil)

                  if is_struct(creator) and
                       not is_struct(creator, Ecto.Association.NotLoaded) do
                    {:ok, creator}
                  else
                    # The :created mixin loads without its nested :creator (stays
                    # NotLoaded → null, e.g. a boosted post's author). Preload it.
                    {:ok,
                     e(
                       Bonfire.Common.Repo.maybe_preload(created,
                         creator: [:profile, :character]
                       ),
                       :creator,
                       nil
                     )}
                  end
                end)
            end
        end)
      end

      field(:activities, list_of(:activity),
        description: "All activities associated with this post (TODO)"
      )

      field :context, :any_context do
        resolve(fn post, _, _ ->
          subject_if_category =
            if e(post, :subject, :table_id, nil) == "2AGSCANBECATEG0RY0RHASHTAG",
              do: e(post, :subject, nil)

          context =
            e(post, :context, nil) || subject_if_category ||
              e(post, :tree, :parent, nil) ||
              e(post, :object, :tree, :parent, nil)

          context_id =
            Bonfire.Common.Enums.id(context) ||
              e(post, :context_id, nil) ||
              e(post, :tree, :parent_id, nil) ||
              e(post, :object, :tree, :parent_id, nil)

          cond do
            is_struct(context) -> {:ok, context}
            is_binary(context_id) -> {:ok, %{id: context_id}}
            true -> {:ok, nil}
          end
        end)
      end

      field :permission_grants, list_of(:boundary_permission) do
        resolve(fn post, _, _ ->
          acl_grants = e(post, :controlled, :acl, :grants, nil) || %{}

          if acl_grants == %{} do
            {:ok, []}
          else
            {verb_permissions, _} =
              Bonfire.Boundaries.VerbGrants.transform_acl_to_verb_format(acl_grants)

            grants =
              for {verb, circle_map} <- verb_permissions do
                can_ids = for {id, :can} <- circle_map, do: %{id: id, label: nil}
                cannot_ids = for {id, :cannot} <- circle_map, do: %{id: id, label: nil}
                %{permission: verb, can: can_ids, cannot: cannot_ids}
              end

            {:ok, grants}
          end
        end)
      end
    end

    object :other do
      field(:id, :id)
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
        resolve(fn
          # boost activities carry the subject as a bare Needle.Pointer (preloaded but not
          # followed); follow it to the concrete actor so the :any_character union resolves it.
          # MUST come before the is_struct/0 clause (a Pointer is itself a struct). Mirrors :object.
          %{subject: %Needle.Pointer{} = pointer}, _args, _info ->
            follow_pointer(pointer)

          # use-parent fast path: a real, already-followed actor struct.
          %{subject: subject}, _args, _info
          when is_struct(subject) and not is_struct(subject, Ecto.Association.NotLoaded) ->
            {:ok, subject}

          # A replied-to parent resolves to an OBJECT (e.g. a Post) — it has a
          # creator but no :subject assoc, so return the author instead of
          # crashing the Dataloader on a schema without :subject. Activities have
          # a :subject key so they never match this clause.
          %{__struct__: _} = obj, _args, _info when not is_map_key(obj, :subject) ->
            {:ok, e(obj, :created, :creator, nil)}

          parent, _args, %{context: %{loader: loader}} ->
            loader
            |> Dataloader.load(Needle.Pointer, :subject, parent)
            |> Helpers.on_load(fn loader ->
              Dataloader.get(loader, Needle.Pointer, :subject, parent) |> follow_pointer()
            end)
        end)
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
      field :object, :any_context do
        resolve(fn
          # use-parent fast path: resolve a feed-preloaded object synchronously (variant-D).
          %{object: %Needle.Pointer{} = pointer}, _args, _info ->
            follow_pointer(pointer)

          %{object: object}, _args, _info
          when is_struct(object) and not is_struct(object, Ecto.Association.NotLoaded) ->
            {:ok, object}

          activity, _args, %{context: %{loader: loader}} ->
            loader
            |> Dataloader.load(Needle.Pointer, :object, activity)
            |> Helpers.on_load(fn loader ->
              Dataloader.get(loader, Needle.Pointer, :object, activity) |> follow_pointer()
            end)
        end)
      end

      # The group/topic a post was published in (`activity.tree.parent`), rendered
      # as "in <group>" in feeds. Needs the feed to preload :with_parent (else nil).
      field :context, :any_context do
        resolve(fn activity, _args, _info ->
          {:ok, e(activity, :tree, :parent, nil)}
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

      @desc "The edge (Like/Boost/Follow/Request) backing this activity — lets the notifications layer distinguish follow_request vs quote."
      field :edge, :edge do
        resolve(fn
          %{edge: edge}, _args, _info
          when is_struct(edge) and not is_struct(edge, Ecto.Association.NotLoaded) ->
            {:ok, edge}

          parent, _args, %{context: %{loader: loader}} ->
            loader
            |> Dataloader.load(Needle.Pointer, :edge, parent)
            |> Helpers.on_load(fn loader ->
              {:ok, Dataloader.get(loader, Needle.Pointer, :edge, parent)}
            end)
        end)
      end

      field :replied, :replied do
        description("Information about the thread, and replies to this activity (if any)")

        resolve(fn
          # use-parent fast path: when the feed query preloaded `replied`
          # (:with_replied / :with_object_more), resolve it synchronously.
          %{replied: replied}, _args, _info
          when is_struct(replied) and not is_struct(replied, Ecto.Association.NotLoaded) ->
            {:ok, replied}

          parent, _args, %{context: %{loader: loader}} ->
            loader
            |> Dataloader.load(Needle.Pointer, :replied, parent)
            |> Helpers.on_load(fn loader ->
              {:ok, Dataloader.get(loader, Needle.Pointer, :replied, parent)}
            end)
        end)
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
          # use-parent fast path: :with_replied preloads the `replied` record,
          # which carries `direct_replies_count` — no Dataloader round needed.
          %{replied: %{direct_replies_count: count}}, _args, _info ->
            {:ok, (is_integer(count) && count) || 0}

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
            Dataloader.get(loader, Needle.Pointer, :object, edge) |> follow_pointer()
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
        description("The post being replied to")
        # reply_to points to the parent OBJECT (a Post). Load + follow the
        # pointer to the concrete struct (a bare Needle.Pointer has no
        # :subject/:object assoc, so sub-fields on it 500'd the whole query),
        # and preload its creator so `subject` can return the parent author.
        resolve(fn parent, _args, %{context: %{loader: loader}} ->
          loader
          |> Dataloader.load(Needle.Pointer, :reply_to, parent)
          |> Helpers.on_load(fn loader ->
            case Dataloader.get(loader, Needle.Pointer, :reply_to, parent)
                 |> follow_pointer() do
              {:ok, %{} = obj} ->
                {:ok,
                 Bonfire.Common.Repo.maybe_preload(obj,
                   created: [creator: [:profile, :character]]
                 )}

              other ->
                other
            end
          end)
        end)
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

    @doc "List of valid filter keys that can be passed to feed queries"
    def feed_filter_keys do
      [
        :feed_name,
        :feed_ids,
        :subjects,
        :subject_circles,
        :creators,
        :objects,
        :tags,
        :activity_types,
        :object_types,
        :media_types,
        :time_limit,
        :sort_by,
        :sort_order,
        :id_before,
        :id_after,
        :preload,
        :skip_current_user_preload
      ]
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
        complexity(&page_complexity/2)
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

      @desc "Get a single status (an object's create-activity) by object id, with the activity subtree preloaded so sub-fields resolve synchronously (variant-D)"
      field :status, :activity do
        arg(:id, non_null(:id))
        resolve(&get_status/3)
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
        complexity(&page_complexity/2)
        resolve(&feed/2)
      end

      @desc "Variant-D: feed with the activity subtree preloaded so sub-fields resolve synchronously (no Needle.Pointer Dataloader rounds)"
      connection field :feed_activities_preloaded, node_type: :activity do
        arg(:filter, :feed_filters)
        complexity(&page_complexity/2)
        resolve(&feed_preloaded/2)
      end

      @desc "Activities posted in a group (the group's outbox feed)"
      connection field :group_activities, node_type: :activity do
        arg(:group_id, non_null(:id))
        arg(:filter, :feed_filters)
        complexity(&page_complexity/2)
        resolve(&group_activities/2)
      end

      @desc "Get objects in a feed (TODO)"
      connection field :feed_objects, node_type: :any_context do
        arg(:filter, :feed_filters)
        complexity(&page_complexity/2)
        resolve(&feed_objects/2)
      end

      # @desc "Get media in a feed (TODO)"
      # connection field :feed_media, node_type: :media do
      #   arg(:filter, :feed_filters)
      #   resolve(&feed_media/2)
      # end

      @desc "List posts liked by the current user (favourites)"
      connection field :my_likes, node_type: :post do
        complexity(&page_complexity/2)
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
        arg(:boundary, :string)
        arg(:permissions, list_of(:boundary_permission_input))
        arg(:context_id, :id)
        arg(:uploaded_media, list_of(:id))
        # quote a post (FEP-044f)
        arg(:quote_id, :id)

        resolve(&create_post/2)
      end

      field :edit_post, :post do
        arg(:post_id, non_null(:id))
        arg(:post_content, :post_content_input)
        arg(:boundary, :string)

        resolve(&update_post/2)
      end

      field :follow, :activity do
        arg(:username, non_null(:string))
        arg(:id, non_null(:string))

        resolve(&Bonfire.Social.Graph.API.GraphQL.follow/2)
      end

      field :unfollow, :boolean do
        arg(:username, :string)
        arg(:id, non_null(:string))

        resolve(&Bonfire.Social.Graph.API.GraphQL.unfollow/2)
      end

      field :accept_follow_request, :boolean do
        arg(:id, non_null(:id))

        resolve(&Bonfire.Social.Graph.API.GraphQL.accept_follow_request/2)
      end

      field :reject_follow_request, :boolean do
        arg(:id, non_null(:id))

        resolve(&Bonfire.Social.Graph.API.GraphQL.reject_follow_request/2)
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

      field :bookmark, :activity do
        arg(:id, non_null(:string))

        resolve(&bookmark/2)
      end

      field :unbookmark, :boolean do
        arg(:id, non_null(:string))

        resolve(&unbookmark/2)
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

    # Read the OBJECT's create-activity (subject = author, so liking can't mis-attribute),
    # richly preloaded so the :activity sub-fields resolve synchronously (no Dataloader storm).
    # Single source of truth shared with the direct read path (`read_single_status`).
    @single_status_preloads Bonfire.API.MastoCompat.FeedPipeline.single_status_preloads()
    def get_status(_parent, %{id: id}, info) do
      current_user = GraphQL.current_user(info)

      case Bonfire.Social.Objects.read(id,
             current_user: current_user,
             preload: @single_status_preloads
           ) do
        {:ok, %{activity: activity} = object} when is_map(activity) ->
          {:ok, Map.put(activity, :object, object)}

        {:ok, object} ->
          {:ok, %{id: id, object_id: id, object: object}}

        _ ->
          {:error, :not_found}
      end
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
               preload: [:with_subject, :with_media, :with_reply_to]
             ) do
          %{edges: edges} when is_list(edges) ->
            edges
            |> Enum.map(fn edge ->
              case edge do
                %{id: _, object_id: _} = activity -> activity
                %{activity: activity} when not is_nil(activity) -> activity
                %{node: %{activity: activity}} when not is_nil(activity) -> activity
                %{node: %{id: _, object_id: _} = activity} -> activity
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

    def feed_preloaded(args, info), do: feed(:activities_preloaded, nil, args, info)

    @doc false
    # Complexity for paginated fields (Phase 3 security): cost = page size × per-node child
    # complexity, so abusive `first:`/`last:` or deep selections are bounded past `max_complexity`
    # on the PUBLIC endpoint. Inert for internal `Absinthe.run` reads (no complexity analysis).
    # Defaults to page size 20 when no pagination arg is given.
    def page_complexity(args, child_complexity) do
      limit = Map.get(args, :first) || Map.get(args, :last) || 20
      max(limit, 1) * child_complexity + 1
    end

    @doc "Resolver for the group_activities connection using the group's outbox feed ids."
    def group_activities(args, info) do
      current_user = GraphQL.current_user(info)
      group_id = args[:group_id]

      group =
        case maybe_apply(Bonfire.Classify.Categories, :get, [
               group_id,
               [preload: :character, current_user: current_user]
             ]) do
          {:ok, g} -> g
          %{} = g -> g
          _ -> nil
        end

      if group do
        # Include child topics' feeds for parity with the web group page.
        subcategories =
          maybe_apply(Bonfire.Classify.Categories, :list_tree, [
            [:default, parent_category: group_id, tree_max_depth: 1, preload: :character],
            [current_user: current_user]
          ])
          |> e(:edges, [])

        feed_ids =
          maybe_apply(Bonfire.Classify.Categories, :group_feed_ids, [
            group,
            subcategories
          ]) || [group_id]

        feed(:activities, feed_ids, args, info)
      else
        {:error, "Group not found"}
      end
    end

    def feed(feed_type \\ :activities, feed_name \\ nil, args, info) do
      current_user = GraphQL.current_user(info)

      # A list feed_name is an explicit feed-id scope, used by group/topic feeds.
      {explicit_feed_ids, feed_name} =
        case feed_name do
          ids when is_list(ids) -> {ids, :custom}
          other -> {nil, other}
        end

      {pagination_args, filters} =
        Pagination.pagination_args_filter(args)

      filters = e(filters, :filter, %{})
      filters = if is_map(filters), do: filters, else: Map.new(filters)

      # A present feed_name key, even nil, intentionally overrides the default.
      feed_name_explicitly_set? = is_map(filters) and Map.has_key?(filters, :feed_name)
      feed_name_from_filter = e(filters, :feed_name, nil)

      feed_name_resolved =
        feed_name ||
          if feed_name_explicitly_set? do
            Types.maybe_to_atom(feed_name_from_filter)
          else
            Types.maybe_to_atom(
              Bonfire.Social.FeedLoader.feed_name_or_default(:default, current_user)
            )
          end

      feed_opts = [
        current_user: current_user,
        # API feeds should not inherit the FeedLive UI's 7-day default window.
        time_limit: 0,
        paginate: feed_paginate_opts(pagination_args),
        # API feeds rely on field resolvers unless a caller asks for explicit preloads.
        preload:
          case e(filters, :preload, nil) || e(filters, "preload", nil) do
            preload_list when is_list(preload_list) and preload_list != [] ->
              # Convert string preload options to atoms (for Mastodon API N+1 optimization)
              Enum.map(preload_list, &Types.maybe_to_atom/1)

            _ ->
              # Fall back to existing logic based on feed_type
              case feed_type do
                :objects ->
                  :per_object

                :media ->
                  :per_media

                # Preload the activity subtree for synchronous API reads.
                :activities_preloaded ->
                  # :with_verb so the verb name resolves (e.g. "Boost") for reblog detection
                  [
                    :with_verb,
                    :with_subject,
                    :with_creator,
                    :with_object_more,
                    :with_post_content,
                    :with_replied
                  ]

                _activities ->
                  # Keep API feeds light; callers can opt into tree preloads when needed.
                  false
              end
          end
      ]

      feed_result =
        if is_list(explicit_feed_ids) and explicit_feed_ids != [] do
          # Bypass preset resolution for explicit group/topic feed ids.
          Bonfire.Social.FeedLoader.feed_filtered(explicit_feed_ids, filters, feed_opts)
        else
          Bonfire.Social.FeedActivities.feed(feed_name_resolved, filters, feed_opts)
        end

      case feed_result do
        {:error, _} = error ->
          error

        %{edges: edges} when is_list(edges) and length(edges) > 0 ->
          # Media requires postloading because it uses complex join logic.
          postloads = [:with_media]

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

    # Relay uses :first/:last; the Bonfire paginator reads :limit.
    defp feed_paginate_opts(pagination_args) when is_list(pagination_args) do
      case pagination_args[:first] || pagination_args[:last] do
        limit when is_integer(limit) -> Keyword.put_new(pagination_args, :limit, limit)
        _ -> pagination_args
      end
    end

    defp feed_paginate_opts(pagination_args), do: pagination_args || true

    # Follow a bare Needle.Pointer to its concrete object: boost subjects and object pointers
    # are loaded as unfollowed pointers that the :any_character/:any_context unions can't type,
    # so dereference them; pass a real (already-loaded) struct through; nil otherwise. Shared by
    # the :subject/:object resolvers and the :edge.object resolver.
    defp follow_pointer(%Needle.Pointer{} = pointer) do
      case Bonfire.Common.Needles.follow!(pointer, skip_boundary_check: true) do
        %{__struct__: _} = object -> {:ok, object}
        _ -> {:ok, nil}
      end
    end

    defp follow_pointer(object) when is_struct(object), do: {:ok, object}
    defp follow_pointer(_), do: {:ok, nil}

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
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
        verb_grants =
          case args[:permissions] do
            perms when is_list(perms) and perms != [] ->
              perms
              |> Map.new(fn %{permission: verb, can: can_ids, cannot: cannot_ids} ->
                circle_map =
                  Enum.map(can_ids || [], &{&1, :can}) ++
                    Enum.map(cannot_ids || [], &{&1, :cannot})

                {verb, Map.new(circle_map)}
              end)
              |> Bonfire.Boundaries.VerbGrants.transform_to_verb_grants_format()

            _ ->
              nil
          end

        with {:ok, post_attrs} <- post_attrs_with_uploaded_media(args, user),
             opts =
               [
                 post_attrs: post_attrs,
                 current_user: user,
                 context: info
               ]
               |> maybe_put(:boundary, args[:boundary])
               |> maybe_put(:verb_grants, verb_grants)
               |> maybe_put(:context_id, args[:context_id])
               |> maybe_put(:quotes, if(args[:quote_id], do: [args[:quote_id]])),
             {:ok, post} <- Bonfire.Posts.publish(opts) do
          {:ok, maybe_put(post, :context_id, args[:context_id])}
        end
      end
    end

    defp post_attrs_with_uploaded_media(%{uploaded_media: ids} = args, user)
         when is_list(ids) and ids != [] do
      with {:ok, media} <- fetch_owned_media(ids, user) do
        {:ok, Map.put(args, :uploaded_media, media)}
      end
    end

    defp post_attrs_with_uploaded_media(args, _user), do: {:ok, args}

    # Every requested upload must exist and belong to the posting user.
    defp fetch_owned_media(ids, user) do
      user_id = Bonfire.Common.Enums.id(user)

      ids
      |> List.wrap()
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
        with true <- Bonfire.Common.Types.is_uid?(id),
             {:ok, loaded_media} <- Bonfire.Files.Media.one(id: id),
             true <- Bonfire.Common.Enums.id(Map.get(loaded_media, :creator_id)) == user_id do
          {:cont, {:ok, [loaded_media | acc]}}
        else
          _ -> {:halt, {:error, "Media not found or not owned"}}
        end
      end)
      |> case do
        {:ok, media} -> {:ok, Enum.reverse(media)}
        error -> error
      end
    end

    defp update_post(%{post_id: post_id} = args, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, post} <- Bonfire.Common.Needles.get(post_id, current_user: user) do
        post =
          if content = args[:post_content] do
            case Bonfire.Posts.update(post, %{post_content: content}) do
              {:ok, updated} ->
                updated

              {:error, e} ->
                error(e, "Failed to update post content")

              e ->
                warn(e, "Unexpected error while updating post content")
                post
            end
          else
            post
          end

        if boundary = args[:boundary] do
          previous_preset = Bonfire.Boundaries.Controlleds.get_preset_on_object(post)

          if boundary != previous_preset,
            do:
              Bonfire.Social.Objects.reset_preset_boundary(user, post, previous_preset,
                to_boundaries: boundary
              )
        end

        {:ok, post}
      end
    end

    # Re-read the acted-on object so `*ByMe`/`*Count` reflect persisted reactions.
    defp reaction_status(reaction, id, info) do
      case get_status(nil, %{id: id}, info) do
        {:error, _} -> {:ok, e(reaction, :activity, nil) || reaction}
        other -> other
      end
    end

    defp boost(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Boosts.boost(user, id),
             do: reaction_status(f, id, info)
      else
        {:error, "Not authenticated"}
      end
    end

    defp like(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Likes.like(user, id),
             do: reaction_status(f, id, info)
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

    defp bookmark(%{id: id}, info) do
      user = GraphQL.current_user(info)

      if user do
        # Bookmarks.bookmark expects an object, while Likes.like accepts an id.
        with {:ok, object} <- Bonfire.Common.Needles.get(id, current_user: user),
             {:ok, f} <- Bonfire.Social.Bookmarks.bookmark(user, object) do
          reaction_status(f, id, info)
        end
      else
        {:error, "Not authenticated"}
      end
    end

    defp unbookmark(%{id: id}, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, _} <- Bonfire.Social.Bookmarks.unbookmark(user, id) do
        {:ok, true}
      end
    end

    def my_likes(args, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
        {pagination_args, _filters} = Pagination.pagination_args_filter(args)

        result =
          Bonfire.Social.Likes.list_my(
            current_user: user,
            paginate: pagination_args
          )

        # Batch-preload media on the liked posts so the `:post.media` sub-field resolves
        # without an N+1 (mirrors the previous direct favourites path).
        media_by_id =
          result
          |> e(:edges, [])
          |> Enum.map(&liked_post/1)
          |> Enum.reject(&is_nil/1)
          |> Bonfire.Common.Repo.maybe_preload(:media)
          |> Map.new(&{e(&1, :id, nil), &1})

        result
        |> Pagination.connection_paginate(pagination_args,
          item_prepare_fun: fn like ->
            # Return the liked post directly (node_type is :post), media-preloaded.
            post = liked_post(like)
            Map.get(media_by_id, e(post, :id, nil), post)
          end
        )
      end
    end

    defp liked_post(like), do: e(like, :edge, :object, nil) || e(like, :object, nil)

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
