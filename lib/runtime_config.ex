defmodule Bonfire.Social.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  def config do
    import Config

    config :bonfire_social, Bonfire.Social.Feeds,
      feed_presets: [
        my: %{
          description: "Activities of people I follow",
          filters: %{feed_name: :my},
          current_user_required: true
        },
        explore: %{
          description: "All activities",
          filters: %{feed_name: :explore, exclude_verbs: [:like]}
        },
        local: %{
          description: "Local instance activities",
          filters: %{feed_name: :local, exclude_verbs: [:like]}
        },
        remote: %{
          description: "Remote/Fediverse activities",
          filters: %{feed_name: :remote, exclude_verbs: [:like]}
        },
        notifications: %{
          description: "Notifications for me",
          filters: %{feed_name: :notifications},
          current_user_required: true
        },
        messages: %{
          description: "Messages for me",
          filters: %{feed_name: :messages},
          current_user_required: true
        },

        # User interaction feeds
        liked_by_me: %{
          description: "Posts I've liked",
          filters: %{activity_types: :like, subjects: :me},
          parameterized: true
        },
        my_bookmarks: %{
          description: "Posts I've bookmarked",
          filters: %{activity_types: :bookmark, subjects: :me},
          current_user_required: true,
          parameterized: true,
          show_in_main_menu: true
        },
        my_requests: %{
          description: "Pending requests for me",
          filters: %{feed_name: :notifications, activity_types: :request},
          current_user_required: true
        },

        # User-specific feeds
        user_activities: %{
          description: "A specific user's activities",
          # $username is replaced at runtime
          filters: %{subjects: :by},
          parameterized: true
        },
        user_followers: %{
          description: "Followers of a specific user",
          filters: %{object_types: :follow, objects: :by},
          parameterized: true
        },
        user_following: %{
          description: "Users followed by a specific user",
          filters: %{activity_types: :follow, subjects: :by},
          parameterized: true
        },
        user_posts: %{
          description: "Posts by a specific user",
          filters: %{creators: :by, object_types: :post},
          parameterized: true
        },
        # user_publications: %{
        #   description: "Publications by a specific user",
        #   filters: %{creators: :by, media_types: :publication},
        #   parameterized: true
        # },

        # Content type feeds
        # publications: %{
        #   description: "All known publications",
        #   filters: %{media_types: :publication]}
        # },
        images: %{
          description: "All known images",
          filters: %{media_types: "image"}
        },

        # Hashtag feeds
        hashtag: %{
          description: "Activities with a specific hashtag",
          filters: %{tags: :hashtag},
          parameterized: true
        },
        mentions: %{
          description: "Activities with a specific @ mention",
          filters: %{tags: :mentioned},
          parameterized: true
        },

        # Moderation feeds
        flagged_by_me: %{
          description: "Content I've flagged",
          filters: %{activity_types: :flag, subjects: :me},
          parameterized: true,
          current_user_required: true
        },
        flagged_content: %{
          description: "Content flagged by anyone (mods only)",
          filters: %{activity_types: :flag},
          current_user_required: true,
          role_required: :mod
        },

        # Combined filters examples
        trending_discussions: %{
          description: "Popular discussions from the last 7 days",
          filters: %{
            time_limit: 7,
            sort_by: :num_replies,
            sort_order: :desc
          }
        },
        local_media: %{
          description: "Media from local instance",
          filters: %{
            feed_name: :local,
            media_types: "*"
          }
        }
      ]

    config :bonfire_social, Bonfire.Social.FeedLoader,
      preload_rules: %{
        "All Activities (default preloads, should be excluded in other rules as needed)" => %{
          match: %{},
          include: [
            :with_subject,
            :with_creator,
            :with_object_more,
            :with_media,
            :with_reply_to,
            :with_peered
          ]
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
          exclude: [:with_subject, :with_object_more, :with_media, :with_reply_to]
        },
        "Followers of a Specific User" => %{
          match: %{object_types: :follow, objects: "*"},
          include: [:with_subject],
          exclude: [:with_object, :with_object_more, :with_peered, :with_media, :with_reply_to]
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
          include: [:with_creator, :with_peered],
          exclude: [:with_subject, :with_media, :with_object, :with_object_more]
        }
      }

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
        notifications: [
          :feed_by_subject,
          :with_reply_to,
          :with_seen
        ],
        object_with_creator: [
          :with_object_posts,
          :with_creator
        ],
        posts_with_reply_to: [
          :with_subject,
          :with_object_posts
        ],
        posts_with_thread: [
          :with_subject,
          :with_object_posts,
          :with_replied,
          :with_thread_name
        ],
        posts: [
          :with_subject,
          :with_object_posts
        ],
        default: [
          :with_subject,
          :with_object_posts,
          :with_replied
        ]
      ]
  end
end
