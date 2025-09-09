defmodule Bonfire.Social.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  use Bonfire.Common.Localise

  alias Bonfire.Social.FeedFilters

  def config_module, do: true

  def config do
    import Config

    config :bonfire_social, Bonfire.Social.Feeds,
      query_with_deferred_join: true,
      feed_presets: [
        my: %{
          name: l("Following"),
          built_in: true,
          description: l("Activities of people I follow"),
          filters: %FeedFilters{
            feed_name: :my,
            exclude_activity_types: [:follow]
          },
          current_user_required: true,
          exclude_from_nav: false,
          icon: "ph:house-duotone",
          # New structured UI-specific settings
          assigns: [
            page: "following",
            feed_title: l("Following")
          ]
        },
        explore: %{
          name: l("Explore"),
          built_in: true,
          description: l("All activities"),
          filters: %FeedFilters{
            feed_name: :explore,
            exclude_activity_types: [:like, :follow, :request]
          },
          exclude_from_nav: false,
          icon: "ph:compass-duotone",
          assigns: [
            page: "explore",
            page_title: "Explore activities",
            feedback_title: l("There are no activities to explore"),
            feedback_message:
              l(
                "It seems like the paint is still fresh and there are no activities to explore..."
              )
          ]
        },
        local: %{
          name: l("Local"),
          built_in: true,
          description: l("Local instance activities"),
          filters: %FeedFilters{
            feed_name: :local,
            origin: :local,
            exclude_activity_types: [:like, :follow, :request]
          },
          exclude_from_nav: false,
          icon: "ph:campfire-duotone",
          assigns: [
            page: "local",
            page_title: l("Explore local activities"),
            feedback_title: l("Your local feed is empty"),
            feedback_message: l("It seems like the paint is still fresh on this instance...")
          ]
        },
        remote: %{
          name: l("Remote"),
          built_in: true,
          description: l("Remote activities from other federated instances"),
          filters: %FeedFilters{
            feed_name: :remote,
            origin: :remote,
            exclude_activity_types: [:like, :follow, :request]
          },
          icon: "ph:planet-duotone",
          assigns: [
            page: "remote",
            page_title: "Activities from the fediverse",
            feedback_title: l("Your fediverse feed is empty"),
            feedback_message:
              l(
                "It seems you and other local users do not follow anyone on a different federated instance"
              )
          ]
        },
        notifications: %{
          name: l("Notifications"),
          built_in: true,
          description: l("Notifications for me"),
          filters: %FeedFilters{
            feed_name: :notifications,
            show_objects_only_once: false,
            exclude_activity_types: false
          },
          current_user_required: true,
          opts: [include_flags: :mediate],
          icon: "ph:bell-duotone",
          assigns: [
            page: "notifications",
            showing_within: :notifications,
            back: true,
            page_header_icon: "carbon:notification",
            page_title: l("Notifications"),
            feedback_title: l("You have no notifications"),
            feedback_message:
              l(
                "Did you know you can customise which activities you want to be notified for in your settings ?"
              ),
            page_header_aside: [
              {Bonfire.UI.Social.HeaderAsideNotificationsSeenLive,
               [
                 feed_id: :notifications,
                 feed_name: "notifications"
               ]}
            ]
          ]
        },
        likes: %{
          name: l("Likes"),
          built_in: true,
          description: l("Activities I've liked"),
          filters: %FeedFilters{activity_types: [:like]},
          parameterized: %{subjects: [:me]},
          # exclude_from_nav: false,
          icon: "ph:fire-duotone",
          assigns: [
            hide_filters: true,
            showing_within: :feed_by_subject,
            page: "likes",
            page_title: "Likes",
            no_header: false,
            feedback_title: l("Have you not liked anything yet?")
          ]
        },
        bookmarks: %{
          name: l("Bookmarks"),
          built_in: true,
          description: l("Activities I've bookmarked"),
          filters: %FeedFilters{activity_types: :bookmark},
          current_user_required: true,
          parameterized: %{subjects: [:me]},
          exclude_from_nav: false,
          base_query_fun: &Bonfire.Social.Bookmarks.base_query/0,
          icon: "ph:bookmark-duotone",
          assigns: [
            hide_filters: true,
            showing_within: :feed_by_subject,
            page: "bookmarks",
            page_title: l("Bookmarks"),
            no_header: false,
            feedback_title: l("Have you not bookmarked anything yet?")
          ]
        },
        my_requests: %{
          name: l("Requests"),
          built_in: true,
          description: l("Pending requests for me"),
          filters: %FeedFilters{feed_name: :notifications, activity_types: [:request]},
          current_user_required: true,
          icon: "ph:user-plus-duotone"
        },
        my_boosts: %{
          name: l("My boosts"),
          built_in: true,
          description: l("Activities I've shared"),
          filters: %FeedFilters{activity_types: [:boost]},
          parameterized: %{subjects: [:me]},
          exclude_from_nav: false,
          icon: "ph:rocket-launch-duotone",
          assigns: [
            hide_filters: true,
            showing_within: :feed_by_subject,
            page: "boosts",
            page_title: l("My boosts"),
            no_header: false,
            feedback_title: l("Have you not boosted anything yet?")
          ]
        },

        # User-specific feeds
        user_activities: %{
          built_in: true,
          description: "A specific user's activities",
          # $username is replaced at runtime
          filters: %FeedFilters{exclude_activity_types: [:like, :follow]},
          parameterized: %{subjects: [:by]}
        },
        user_followers: %{
          built_in: true,
          description: "Followers of a specific user",
          filters: %FeedFilters{activity_types: [:follow]},
          parameterized: %{objects: [:by]}
        },
        user_following: %{
          built_in: true,
          description: "Users followed by a specific user",
          filters: %FeedFilters{activity_types: [:follow]},
          parameterized: %{subjects: [:by]}
        },
        user_by_object_type: %{
          built_in: true,
          description: "Posts by a specific user",
          filters: %FeedFilters{creators: [:by], object_types: [:post]},
          parameterized: %{creators: :by}
        },
        # user_research: %{
        #   built_in: true, description: "Publications by a specific user",
        #   filters: %{media_types: [:research]},
        #   parameterized: %{creators: :by}
        # },

        # Content type feeds
        posts: %{
          built_in: true,
          name: l("Posts"),
          description: l("Posts (not including replies)"),
          #  TODO: exclude articles?
          filters: %FeedFilters{object_types: [:post], exclude_activity_types: [:reply]},
          icon: "ph:note-duotone"
        },
        articles: %{
          name: l("Articles"),
          built_in: true,
          description: l("All known articles"),
          filters: %FeedFilters{
            # ActivityPub Event type
            object_types: ["article"],
            exclude_activity_types: [:like, :boost, :flag]
          },
          icon: "ph:article-ny-times-duotone",
          assigns: [
            page: "articles",
            page_title: l("Articles"),
            feedback_title: l("No articles found"),
            feedback_message:
              l(
                "There are no known articles to show. Articles from other federated platforms like WriteFreely or Ghost will appear here."
              )
          ]
        },
        # TODO?
        # discussions: %{
        #   built_in: true,
        #   name: l("Discussions"),
        #   description: l("Posts and replies"),
        #   filters: %FeedFilters{object_types: [:post]},
        #   icon: "mingcute:comment-fill"
        # },
        research: %{
          name: l("Research"),
          built_in: true,
          description: l("All known research publications"),
          filters: %FeedFilters{
            media_types: [:research]
          },
          icon: "ph:microscope-duotone"
        },
        images: %{
          name: l("Images"),
          built_in: true,
          description: l("All known images"),
          filters: %FeedFilters{
            media_types: ["image"]
          },
          icon: "ph:image-duotone"
        },
        videos: %{
          name: l("Videos"),
          built_in: true,
          description: l("All known videos"),
          filters: %FeedFilters{
            media_types: ["video"]
          },
          icon: "ph:video-duotone"
        },
        audio: %{
          name: l("Audio"),
          built_in: true,
          description: l("All known audio"),
          filters: %FeedFilters{
            media_types: ["audio"]
          },
          icon: "ph:waveform-duotone"
        },

        # Hashtag feeds
        hashtag: %{
          built_in: true,
          description: l("Activities with a specific hashtag"),
          filters: %FeedFilters{},
          parameterized: %{tags: [:tags]}
        },
        mentions: %{
          built_in: true,
          description: "Activities with a specific @ mention",
          filters: %FeedFilters{},
          parameterized: %{tags: [:tags]}
        },
        curated: %{
          name: l("Curated"),
          built_in: true,
          description: l("Curated activities"),
          icon: "ph:push-pin-duotone",
          filters: %FeedFilters{feed_name: :curated},
          assigns: [
            showing_within: :feed_by_subject,
            page: "curated",
            page_title: l("(Curated activities)"),
            no_header: :current_user_id,
            feedback_title: l("Nothing curated yet?")
          ]
        },
        books: %{
          name: l("Books"),
          built_in: true,
          description: l("All known books"),
          filters: %FeedFilters{
            # ActivityPub Event type
            object_types: ["Edition", "Book"],
            exclude_activity_types: [:like, :boost, :flag]
          },
          icon: "ph:book-duotone",
          assigns: [
            page: "books",
            page_title: l("Books"),
            feedback_title: l("No books found"),
            feedback_message:
              l(
                "There are no known books to show. Books from other federated platforms like BookWyrm will appear here."
              )
          ]
        },
        events: %{
          name: l("Events"),
          built_in: true,
          description: l("Events and gatherings"),
          filters: %FeedFilters{
            # ActivityPub Event type
            object_types: ["Event"],
            exclude_activity_types: [:like, :boost, :flag]
          },
          icon: "ph:calendar-blank-duotone",
          assigns: [
            page: "events",
            page_title: l("Events"),
            feedback_title: l("No events found"),
            feedback_message:
              l(
                "There are no upcoming events to show. Events from other federated platforms like Mobilizon will appear here."
              )
          ]
        },
        my_flags: %{
          name: l("My Flags"),
          built_in: true,
          description: "Content I've flagged",
          filters: %FeedFilters{
            activity_types: [:flag],
            show_objects_only_once: false
          },
          parameterized: %{subjects: [:me]},
          current_user_required: true,
          opts: [include_flags: true],
          icon: "ph:flag-duotone",
          assigns: [
            selected_tab: :flags,
            scope: :instance,
            page: "flags",
            feedback_title: l("You have not flagged any activities...")
          ]
        },
        flagged_content: %{
          name: l("All flags"),
          built_in: true,
          description: "Content flagged by anyone (mods only)",
          filters: %FeedFilters{
            activity_types: [:flag],
            show_objects_only_once: false
          },
          current_user_required: true,
          instance_permission_required: :mediate,
          opts: [include_flags: :mediate],
          icon: "ph:flag-duotone",
          assigns: [
            selected_tab: "all flags",
            scope: :instance,
            page: "flags",
            feedback_title: l("You have no flagged activities to review...")
          ]
        },

        # messages: %{
        #   name: l("Messages"),
        #   built_in: true, description: ("Messages for me"),
        #   filters: %FeedFilters{feed_name: :messages},
        #   current_user_required: true
        # },

        # Combined filters examples
        trending_discussions: %{
          name: l("Top discussions"),
          built_in: true,
          description: "Popular discussions from the last 7 days",
          filters: %FeedFilters{
            time_limit: 7,
            sort_by: :num_replies,
            sort_order: :desc,
            exclude_activity_types: [:boost, :like, :follow]
          },
          icon: "ph:chats-circle-duotone"
        },
        trending: %{
          name: l("Trending"),
          built_in: true,
          description: l("Most boosted activities from the last week"),
          filters: %FeedFilters{
            feed_name: :trending,
            exclude_activity_types: [:reply],
            sort_by: :num_boosts,
            sort_order: :desc,
            time_limit: 7
          },
          exclude_from_nav: false,
          icon: "ph:trend-up-duotone",
          assigns: [
            page: "trending",
            page_title: l("Trending"),
            feedback_title: l("No trending posts yet"),
            feedback_message: l("Posts need to be boosted to appear in trending")
          ]
        },
        news: %{
          name: l("News"),
          built_in: true,
          description: l("Most boosted posts with links"),
          filters: %FeedFilters{
            feed_name: :news,
            exclude_activity_types: [:reply],
            media_types: ["link"],
            sort_by: :num_boosts,
            sort_order: :desc
          },
          exclude_from_nav: false,
          icon: "ph:newspaper-duotone",
          assigns: [
            page: "news",
            page_title: l("News"),
            feedback_title: l("No news posts yet"),
            feedback_message: l("Share interesting links to see them here")
          ]
        },
        local_media: %{
          name: l("Local Media"),
          built_in: true,
          description: "All media shared on the local instance",
          filters: %FeedFilters{
            origin: :local,
            media_types: ["*"]
          },
          icon: "ph:file-duotone"
        }
      ]

    feed_default_include = [
      :with_subject,
      :with_creator,
      :with_object_more,
      :with_media,
      :with_replied,
      :with_reply_to,
      :with_object_peered,
      #  TODO: only if quote posts are enabled?
      :quote_tags
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
          match: %{origin: :local},
          include: [],
          exclude: [:with_object_peered]
        },
        "Remote Feed (From the Fediverse)" => %{
          match: %{origin: :remote},
          include: [:with_object_peered],
          exclude: []
        },
        "Notifications Feed (Only for me)" => %{
          match: %{feed_name: :notifications},
          include: [
            :with_seen,
            :with_replied,
            :with_reply_to,
            :emoji,
            :sensitivity,
            :activity_name
          ]
        },
        # "Messages Feed (Only for me)" => %{
        #   match: %{feed_name: :messages},
        #   include: [:with_seen, :tags],
        #   exclude: [:with_object, :with_object_more]
        # },

        # Custom Feeds
        "A Specific User's Activities" => %{
          match: %{subjects: "*"},
          include: [:with_creator],
          exclude: [:with_subject]
        },
        "Requests for Me" => %{
          match: %{activity_types: [:request]},
          include: [],
          exclude: [:with_object, :with_object_more, :with_media, :with_reply_to]
        },
        "Followed by a Specific User" => %{
          match: %{activity_types: :follow, subjects: "*"},
          include: [:with_object, :with_object_peered],
          exclude: [:with_subject, :with_creator, :with_object_more, :with_media, :with_reply_to]
        },
        "Followers of a Specific User" => %{
          match: %{activity_types: :follow, objects: "*"},
          include: [:with_subject],
          exclude: [
            :with_object,
            :with_creator,
            :with_object_more,
            :with_object_peered,
            :with_media,
            :with_reply_to
          ]
        },
        "Activities with a Specific Hashtag or @ mention" => %{
          match: %{tags: "*"},
          include: [],
          exclude: []
        },
        "Created by a Specific User" => %{
          match: %{creators: "*"},
          exclude: [:with_creator, :with_subject]
        },
        "Flags" => %{
          match: %{activity_types: [:flag]},
          include: [:sensitivity, :activity_name],
          exclude: []
        },
        "Events Feed" => %{
          match: %{feed_name: :events},
          include: [:with_object_more, :tags, :maybe_sensitive_for_me],
          exclude: [:with_parent, :notifications_object_creator]
        },
        # Different Types of Feeds
        "By object type" => %{
          match: %{object_types: "*"},
          include: [:with_object_more],
          exclude: []
        },
        "Posts" => %{
          match: %{object_types: :post},
          include: [:with_creator, :with_post_content, :with_media, :with_object_peered],
          exclude: [:with_object, :with_object_more]
        },
        "Media" => %{
          match: %{media_types: "*"},
          include: [
            :per_media,
            # :with_media,
            :with_creator,
            :with_post_content
            # :with_object_peered (since not loading the object)
          ],
          exclude: [
            :with_media,
            # :with_subject,
            :with_object,
            :with_object_more,
            :with_reply_to
          ]
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
          :with_replied,
          :per_media
          # :with_object_peered
        ]
      ]

    config :bonfire_social, Bonfire.Social.FeedLoader,
      preload_presets: [
        # Default groupings,
        # thread_postload: [
        #   :with_replied,
        #   :with_object_more
        # ],
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
          :with_post_content,
          :with_replied
        ],
        # posts_with_thread: [
        #   :with_subject,
        #   :with_post_content,
        #   :with_replied,
        #   :with_thread_name
        # ],
        posts: [
          :with_subject,
          :with_post_content
        ],
        extras: [:with_verb, :tags, :with_seen],
        default: [
          :with_subject,
          :with_post_content,
          :with_replied,
          :quote_tags
        ]
      ]
  end
end
