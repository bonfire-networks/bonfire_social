defmodule Bonfire.Social.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule

  alias Bonfire.Social.FeedFilters

  def config_module, do: true

  def config do
    import Config

    config :bonfire_social, Bonfire.Social.Feeds,
      feed_presets: [
        my: %{
          description: "Activities of people I follow",
          filters: %FeedFilters{feed_name: :my},
          current_user_required: true
        },
        explore: %{
          description: "All activities",
          filters: %FeedFilters{feed_name: :explore, exclude_activity_types: [:like]}
        },
        local: %{
          description: "Local instance activities",
          filters: %FeedFilters{
            feed_name: :local,
            origin: :local,
            exclude_activity_types: [:like]
          }
        },
        remote: %{
          description: "Remote activities from other federated instances",
          filters: %FeedFilters{
            feed_name: :remote,
            origin: :remote,
            exclude_activity_types: [:like]
          }
        },
        notifications: %{
          description: "Notifications for me",
          filters: %FeedFilters{
            feed_name: :notifications,
            # so we can show flags to admins in notifications
            include_flags: :mod,
            show_objects_only_once: false
          },
          current_user_required: true
        },
        messages: %{
          description: "Messages for me",
          filters: %FeedFilters{feed_name: :messages},
          current_user_required: true
        },

        # User interaction feeds
        liked_by_me: %{
          description: "Posts I've liked",
          filters: %FeedFilters{activity_types: [:like]},
          parameterized: %FeedFilters{subjects: [:me]}
        },
        my_bookmarks: %{
          description: "Posts I've bookmarked",
          filters: %FeedFilters{activity_types: :bookmark},
          current_user_required: true,
          parameterized: %FeedFilters{subjects: [:me]},
          show_in_main_menu: true
        },
        my_requests: %{
          description: "Pending requests for me",
          filters: %FeedFilters{feed_name: :notifications, activity_types: [:request]},
          current_user_required: true
        },

        # User-specific feeds
        user_activities: %{
          description: "A specific user's activities",
          # $username is replaced at runtime
          filters: %FeedFilters{},
          parameterized: %FeedFilters{subjects: [:by]}
        },
        user_followers: %{
          description: "Followers of a specific user",
          filters: %FeedFilters{activity_types: [:follow]},
          parameterized: %FeedFilters{objects: [:by]}
        },
        user_following: %{
          description: "Users followed by a specific user",
          filters: %FeedFilters{activity_types: [:follow]},
          parameterized: %FeedFilters{subjects: [:by]}
        },
        user_by_object_type: %{
          description: "Posts by a specific user",
          filters: %{creators: [:by]},
          parameterized: %FeedFilters{creators: :by, object_types: [:post]}
        },
        # user_research: %{
        #   description: "Publications by a specific user",
        #   filters: %{media_types: [:research]},
        #   parameterized: %{creators: :by}
        # },

        # Content type feeds
        research: %{
          description: "All known research publications",
          filters: %FeedFilters{media_types: [:research]}
        },
        local_images: %{
          description: "All known images",
          filters: %FeedFilters{media_types: ["image"]}
        },

        # Hashtag feeds
        hashtag: %{
          description: "Activities with a specific hashtag",
          filters: %FeedFilters{},
          parameterized: %{tags: [:hashtag]}
        },
        mentions: %{
          description: "Activities with a specific @ mention",
          filters: %FeedFilters{},
          parameterized: %{tags: [:mentioned]}
        },

        # Moderation feeds
        flagged_by_me: %{
          description: "Content I've flagged",
          filters: %FeedFilters{
            activity_types: [:flag],
            include_flags: true,
            show_objects_only_once: false
          },
          parameterized: %FeedFilters{subjects: [:me]},
          current_user_required: true
        },
        flagged_content: %{
          description: "Content flagged by anyone (mods only)",
          filters: %FeedFilters{
            activity_types: [:flag],
            # so we can show flags to admins in notifications
            include_flags: :mod,
            show_objects_only_once: false
          },
          current_user_required: true,
          role_required: :mod
        },

        # Combined filters examples
        trending_discussions: %{
          description: "Popular discussions from the last 7 days",
          filters: %FeedFilters{
            time_limit: 7,
            sort_by: :num_replies,
            sort_order: :desc
          }
        },
        local_media: %{
          description: "Media from local instance",
          filters: %FeedFilters{
            feed_name: :local,
            media_types: ["*"]
          }
        }
      ]

    feed_default_include = [
      :with_subject,
      :with_creator,
      :with_object_more,
      :with_media,
      :with_reply_to,
      :with_peered
    ]

    config :bonfire_social, Bonfire.Social.FeedLoader,
      preload_defaults: [
        feed: [
          include: feed_default_include
        ]
      ]

    config :bonfire_social, Bonfire.Social.FeedLoader,
      preload_rules: %{
        "All Activities (default preloads, should be excluded in other rules as needed)" => %{
          match: %{},
          include: feed_default_include
        },

        # Specific Feeds
        "My Feed (Activities of people I follow)" => %{
          match: %{feed_name: :my},
          include: []
        },
        "Explore Feed (All activities)" => %{
          match: %{feed_name: :explore},
          include: []
        },
        "Local Feed (From the local instance)" => %{
          match: %{feed_name: :local},
          include: [],
          exclude: [:with_peered]
        },
        "Remote Feed (From the Fediverse)" => %{
          match: %{feed_name: [:remote]},
          include: [],
          exclude: []
        },
        "Notifications Feed (Only for me)" => %{
          match: %{feed_name: :notifications},
          include: [:with_seen]
        },
        "Messages Feed (Only for me)" => %{
          match: %{feed_name: :messages},
          include: [:with_seen, :tags],
          exclude: [:with_object, :with_object_more]
        },

        # Custom Feeds
        "A Specific User's Activities" => %{
          match: %{subjects: "*"},
          include: [:with_creator],
          exclude: [:with_subject, :with_peered]
        },
        "Requests for Me" => %{
          match: %{feed_name: "notifications", activity_types: [:request]},
          include: [],
          exclude: [:with_object, :with_object_more, :with_media, :with_reply_to]
        },
        "Followed by a Specific User" => %{
          match: %{activity_types: :follow, subjects: "*"},
          include: [:with_object, :with_peered],
          exclude: [:with_subject, :with_creator, :with_object_more, :with_media, :with_reply_to]
        },
        "Followers of a Specific User" => %{
          match: %{activity_types: :follow, objects: "*"},
          include: [:with_subject],
          exclude: [
            :with_object,
            :with_creator,
            :with_object_more,
            :with_peered,
            :with_media,
            :with_reply_to
          ]
        },
        "Activities with a Specific Hashtag or @ mention" => %{
          match: %{tags: "*"},
          include: [],
          exclude: [:with_subject]
        },
        "Created by a Specific User" => %{
          match: %{creators: "*"},
          exclude: [:with_creator, :with_subject, :with_peered]
        },

        # Different Types of Feeds
        "By object type" => %{
          match: %{object_types: "*"},
          include: [:with_object_more],
          exclude: []
        },
        "Posts" => %{
          match: %{object_types: :post},
          include: [:with_creator, :with_post_content, :with_media, :with_peered],
          exclude: [:with_object, :with_object_more]
        },
        "Media" => %{
          match: %{media_types: "*"},
          include: [:per_media, :with_creator, :with_peered],
          exclude: [:with_subject, :with_media, :with_object, :with_object_more]
        }
      }

    config :bonfire_social, Bonfire.Social.FeedLoader,
      preload_by_context: [
        query: [
          :with_subject,
          #  so we're able to load conditionally (eg not when same as subject)
          :with_creator,
          # we join in first query to filter out deleted objects and/or filter by type
          :with_object,
          #  FIXME? why media?
          :per_media
          # :with_peered
        ]
      ]

    config :bonfire_social, Bonfire.Social.FeedLoader,
      preload_presets: [
        # Default groupings, 
        thread_postload: [
          :with_replied,
          :with_object_more
        ],
        feed: [
          :with_subject,
          :feed_by_subject,
          :with_replied
        ],
        feed_postload: [
          :with_thread_name,
          :with_reply_to,
          :with_media,
          :with_parent,
          :maybe_with_labelled
        ],
        feed_metadata: [
          :with_subject,
          :with_creator,
          :with_thread_name
        ],
        feed_by_subject: [
          :with_creator,
          :feed_by_creator
        ],
        feed_by_creator: [
          :with_object_more,
          :with_media
        ],
        # notifications: [
        #   :feed_by_subject,
        #   :with_reply_to,
        #   :with_seen
        # ],
        object_with_creator: [
          :with_post_content,
          :with_creator
        ],
        posts_with_reply_to: [
          :with_subject,
          :with_post_content
        ],
        posts_with_thread: [
          :with_subject,
          :with_post_content,
          :with_replied,
          :with_thread_name
        ],
        posts: [
          :with_subject,
          :with_post_content
        ],
        extras: [:with_verb, :tags, :with_seen],
        default: [
          :with_subject,
          :with_post_content,
          :with_replied
        ]
      ]
  end
end
