defmodule Bonfire.Social.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  use Bonfire.Common.Localise

  alias Bonfire.Social.FeedFilters

  def config_module, do: true

  def config do
    import Config

    # `config/0` runs once at boot under the default locale, so user-facing strings here use
    # `l_noop/1` (mark for extraction, return the msgid untranslated) rather than `l/1` (which
    # would freeze the boot-locale value). The actual per-request translation happens at the point
    # of display, via `Bonfire.Social.Feeds.localise_preset/1` — which covers `name`/`description`
    # plus the `assigns` display keys (`page_title`/`feed_title`/`feedback_title`/`feedback_message`).
    config :bonfire_social, Bonfire.Social.Feeds,
      query_with_deferred_join: true,
      feed_presets: [
        my: %{
          name: l_noop("Following"),
          built_in: true,
          description: l_noop("Activities of people I follow"),
          filters: %FeedFilters{
            feed_name: :my,
            exclude_activity_types: [:follow]
          },
          current_user_required: true,
          exclude_from_nav: false,
          icon: "ph:rss-duotone",
          # New structured UI-specific settings
          assigns: [
            page: "following",
            feed_title: l_noop("Following"),
            enable_marker: true
          ]
        },
        explore: %{
          name: l_noop("Explore"),
          built_in: true,
          description: l_noop("All activities"),
          filters: %FeedFilters{
            feed_name: :explore,
            exclude_activity_types: [:like, :follow, :request]
          },
          exclude_from_nav: false,
          icon: "ph:compass-duotone",
          assigns: [
            page: "explore",
            page_title: l_noop("Explore activities"),
            feedback_title: l_noop("There are no activities to explore"),
            feedback_message:
              l_noop(
                "It seems like the paint is still fresh and there are no activities to explore..."
              ),
            enable_marker: true
          ]
        },
        local: %{
          name: l_noop("Local"),
          built_in: true,
          description: l_noop("Local instance activities"),
          filters: %FeedFilters{
            feed_name: :local,
            origin: :local,
            exclude_activity_types: [:like, :follow, :request]
          },
          exclude_from_nav: false,
          icon: "ph:campfire-duotone",
          assigns: [
            page: "local",
            page_title: l_noop("Explore local activities"),
            feedback_title: l_noop("Your local feed is empty"),
            feedback_message:
              l_noop("It seems like the paint is still fresh on this instance..."),
            enable_marker: true
          ]
        },
        remote: %{
          name: l_noop("Remote"),
          built_in: true,
          description: l_noop("Remote activities from other federated instances"),
          filters: %FeedFilters{
            feed_name: :remote,
            origin: :remote,
            exclude_activity_types: [:like, :follow, :request]
          },
          icon: "ph:planet-duotone",
          assigns: [
            page: "remote",
            page_title: l_noop("Activities from the fediverse"),
            feedback_title: l_noop("Your fediverse feed is empty"),
            feedback_message:
              l_noop(
                "It seems you and other local users do not follow anyone on a different federated instance"
              ),
            enable_marker: true
          ]
        },
        notifications: %{
          name: l_noop("Notifications"),
          built_in: true,
          description: l_noop("Notifications for me"),
          filters: %FeedFilters{
            feed_name: :notifications,
            show_objects_only_once: false,
            exclude_activity_types: false
          },
          current_user_required: true,
          opts: [include_flags: :mediate, include_requests: true],
          icon: "ph:bell-duotone",
          assigns: [
            hide_filters: true,
            page: "notifications",
            showing_within: :notifications,
            back: true,
            page_header_icon: "carbon:notification",
            page_title: l_noop("Notifications"),
            feedback_title: l_noop("You have no notifications"),
            feedback_message:
              l_noop(
                "Did you know you can customise which activities you want to be notified for in your settings ?"
              )
            # page_header_aside: [
            #   {Bonfire.UI.Social.HeaderAsideNotificationsSeenLive,
            #    [
            #      feed_id: :notifications,
            #      feed_name: "notifications"
            #    ]}
            # ]
          ]
        },
        likes: %{
          name: l_noop("Liked"),
          built_in: true,
          description: l_noop("Things I've liked"),
          filters: %FeedFilters{activity_types: [:like]},
          parameterized: %{subjects: [:me]},
          current_user_required: true,
          # exclude_from_nav: false,
          icon: "ph:fire-duotone",
          assigns: [
            hide_filters: true,
            showing_within: :feed_by_subject,
            page: "likes",
            page_title: l_noop("Likes"),
            no_header: false,
            feedback_title: l_noop("Have you not liked anything yet?")
          ]
        },
        bookmarks: %{
          name: l_noop("Bookmarked"),
          built_in: true,
          description: l_noop("Content I've bookmarked"),
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
            page_title: l_noop("Bookmarks"),
            no_header: false,
            feedback_title: l_noop("Have you not bookmarked anything yet?")
          ]
        },
        # saved: %{ # TODO: seems we can't query by multiple activity types here?
        #   name: l_noop("Saved"),
        #   built_in: true,
        #   description: l_noop("Activities I've found interesting and bookmarked, liked, or boosted"),
        #   filters: %FeedFilters{activity_types: [ :bookmark, :like, :boost ]},
        #   current_user_required: true,
        #   parameterized: %{subjects: [:me]},
        #   exclude_from_nav: false,
        #   base_query_fun: &Bonfire.Social.Bookmarks.base_query/0,
        #   icon: "ph:bookmark-duotone",
        #   assigns: [
        #     # hide_filters: true,
        #     showing_within: :feed_by_subject,
        #     page: "saved",
        #     page_title: l_noop("Saved"),
        #     no_header: false,
        #     feedback_title: l_noop("Have you not saved anything yet?")
        #   ]
        # },
        my_requests: %{
          name: l_noop("Requests"),
          built_in: true,
          description: l_noop("Pending requests for me"),
          filters: %FeedFilters{feed_name: :notifications, activity_types: [:request]},
          current_user_required: true,
          icon: "ph:user-plus-duotone"
        },
        my_boosts: %{
          name: l_noop("Boosted"),
          built_in: true,
          description: l_noop("Activities I've shared"),
          filters: %FeedFilters{activity_types: [:boost]},
          parameterized: %{subjects: [:me]},
          current_user_required: true,
          # exclude_from_nav: false,
          icon: "ph:rocket-launch-duotone",
          assigns: [
            hide_filters: true,
            showing_within: :feed_by_subject,
            page: "boosts",
            page_title: l_noop("Boosted"),
            no_header: false,
            feedback_title: l_noop("Have you not boosted anything yet?")
          ]
        },

        # User-specific feeds
        user_activities: %{
          name: l_noop("User activities"),
          built_in: true,
          description: l_noop("A specific user's activities"),
          icon: "ph:user-duotone",
          # $username is replaced at runtime
          filters: %FeedFilters{exclude_activity_types: [:like, :follow]},
          parameterized: %{subjects: [:by]}
        },
        user_followers: %{
          name: l_noop("Followers"),
          built_in: true,
          description: l_noop("Followers of a specific user"),
          icon: "ph:users-duotone",
          filters: %FeedFilters{activity_types: [:follow]},
          parameterized: %{objects: [:by]}
        },
        user_following: %{
          name: l_noop("Following"),
          built_in: true,
          description: l_noop("Users followed by a specific user"),
          icon: "ph:user-plus-duotone",
          filters: %FeedFilters{activity_types: [:follow]},
          parameterized: %{subjects: [:by]}
        },
        user_by_object_type: %{
          name: l_noop("User posts"),
          built_in: true,
          description: l_noop("Posts by a specific user"),
          icon: "ph:note-duotone",
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
          name: l_noop("Posts"),
          description: l_noop("Posts (not including replies)"),
          #  TODO: exclude articles?
          filters: %FeedFilters{object_types: [:post], exclude_activity_types: [:reply]},
          icon: "ph:note-duotone",
          assigns: [
            enable_marker: true
          ]
        },
        articles: %{
          name: l_noop("Articles"),
          built_in: true,
          description: l_noop("All known articles"),
          filters: %FeedFilters{
            # ActivityPub Event type
            object_types: ["article"],
            exclude_activity_types: [:like, :boost, :flag]
          },
          icon: "ph:article-ny-times-duotone",
          assigns: [
            page: "articles",
            page_title: l_noop("Articles"),
            feedback_title: l_noop("No articles found"),
            feedback_message:
              l_noop(
                "There are no known articles to show. Articles from other federated platforms like WriteFreely or Ghost will appear here."
              ),
            enable_marker: true
          ]
        },
        # TODO?
        # discussions: %{
        #   built_in: true,
        #   name: l_noop("Discussions"),
        #   description: l_noop("Posts and replies"),
        #   filters: %FeedFilters{object_types: [:post]},
        #   icon: "mingcute:comment-fill"
        # },
        research: %{
          name: l_noop("Research"),
          built_in: true,
          description: l_noop("All known research publications"),
          filters: %FeedFilters{
            media_types: [:research]
          },
          icon: "ph:microscope-duotone",
          assigns: [
            enable_marker: true
          ]
        },
        # TEMPORARILY DISABLED:
        # images: %{
        #   name: l_noop("Images"),
        #   built_in: true,
        #   description: l_noop("All known images"),
        #   filters: %FeedFilters{
        #     media_types: ["image"]
        #   },
        #   icon: "ph:image-duotone"
        # },
        # videos: %{
        #   name: l_noop("Videos"),
        #   built_in: true,
        #   description: l_noop("All known videos"),
        #   filters: %FeedFilters{
        #     media_types: ["video"]
        #   },
        #   icon: "ph:video-duotone"
        # },
        # audio: %{
        #   name: l_noop("Audio"),
        #   built_in: true,
        #   description: l_noop("All known audio"),
        #   filters: %FeedFilters{
        #     media_types: ["audio"]
        #   },
        #   icon: "ph:waveform-duotone"
        # },

        # Hashtag feeds
        hashtag: %{
          name: l_noop("Hashtag"),
          built_in: true,
          description: l_noop("Activities with a specific hashtag"),
          icon: "ph:hash-duotone",
          filters: %FeedFilters{},
          parameterized: %{tags: [:tags]}
        },
        mentions: %{
          name: l_noop("Mentions"),
          built_in: true,
          description: l_noop("Activities with a specific @ mention"),
          icon: "ph:at-duotone",
          filters: %FeedFilters{},
          parameterized: %{tags: [:tags]}
        },
        curated: %{
          name: l_noop("Curated"),
          built_in: true,
          description: l_noop("Curated activities"),
          icon: "ph:push-pin-duotone",
          filters: %FeedFilters{feed_name: :curated},
          assigns: [
            showing_within: :feed_by_subject,
            page: "curated",
            page_title: l_noop("(Curated activities)"),
            no_header: :current_user_id,
            feedback_title: l_noop("Nothing curated yet?")
          ]
        },
        books: %{
          name: l_noop("Books"),
          built_in: true,
          description: l_noop("All known books"),
          filters: %FeedFilters{
            # ActivityPub Event type
            object_types: ["Edition", "Book"],
            exclude_activity_types: [:like, :boost, :flag]
          },
          icon: "ph:book-duotone",
          assigns: [
            page: "books",
            page_title: l_noop("Books"),
            feedback_title: l_noop("No books found"),
            feedback_message:
              l_noop(
                "There are no known books to show. Books from other federated platforms like BookWyrm will appear here."
              ),
            enable_marker: true
          ]
        },
        events: %{
          name: l_noop("Events"),
          built_in: true,
          description: l_noop("Events and gatherings"),
          filters: %FeedFilters{
            # ActivityPub Event type
            object_types: ["Event"],
            exclude_activity_types: [:like, :boost, :flag]
          },
          icon: "ph:calendar-blank-duotone",
          assigns: [
            page: "events",
            page_title: l_noop("Events"),
            feedback_title: l_noop("No events found"),
            feedback_message:
              l_noop(
                "There are no upcoming events to show. Events from other federated platforms like Mobilizon will appear here."
              )
          ],
          enable_marker: true
        },
        polls: %{
          name: l_noop("Polls"),
          built_in: true,
          description: l_noop("Polls and group decisions"),
          filters: %FeedFilters{
            # Bonfire.Poll.Question pointable; federated AP `Question` objects
            # land here too via Bonfire.Poll.Questions.federation_module/0.
            object_types: [Bonfire.Poll.Question],
            exclude_activity_types: [:like, :boost, :flag, :reply]
          },
          icon: "ph:list-checks-duotone",
          assigns: [
            page: "polls",
            page_title: l_noop("Polls"),
            feedback_title: l_noop("No polls yet"),
            feedback_message: l_noop("There are no polls to show. Create one to start a vote!"),
            enable_marker: true
          ]
        },
        my_flags: %{
          name: l_noop("Flagged"),
          built_in: true,
          description: l_noop("Content I've flagged"),
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
            hide_filters: true,
            page: "flags",
            feedback_title: l_noop("You have not flagged any activities...")
          ]
        },
        flagged_content: %{
          name: l_noop("Flagged (all)"),
          built_in: true,
          description: l_noop("Content flagged by anyone (for mods only)"),
          filters: %FeedFilters{
            activity_types: [:flag],
            show_objects_only_once: false
          },
          current_user_required: true,
          instance_permission_required: :mediate,
          opts: [include_flags: :mediate],
          icon: "ph:flag-duotone",
          assigns: [
            selected_tab: "flagged_content",
            scope: :instance,
            hide_filters: true,
            page: "flags",
            feedback_title: l_noop("You have no flagged activities to review...")
          ]
        },

        # messages: %{
        #   name: l_noop("Messages"),
        #   built_in: true, description: ("Messages for me"),
        #   filters: %FeedFilters{feed_name: :messages},
        #   current_user_required: true
        # },

        # Combined filters examples
        trending_discussions: %{
          name: l_noop("Top discussions"),
          built_in: true,
          description: l_noop("Popular discussions from the last 7 days"),
          filters: %FeedFilters{
            time_limit: 7,
            sort_by: :reply_count,
            sort_order: :desc,
            exclude_activity_types: [:boost, :like, :follow, :reply]
          },
          icon: "ph:chats-circle-duotone",
          assigns: [
            hide_filters: true,
            custom_preview: Bonfire.UI.Social.Activity.DiscussionPreviewLive
          ]
        },
        recent_discussions: %{
          name: l_noop("Recent discussions"),
          built_in: true,
          description: l_noop("Threads sorted by most recent activity"),
          filters: %FeedFilters{
            sort_order: :desc,
            # NOTE: should not include :boost to work in groups (maybe can later dynamic exlude it from the exclusions when constructing a group query)
            exclude_activity_types: [:like, :follow],
            dedup_by_thread: true
          },
          icon: "ph:chats-circle-duotone",
          assigns: [
            hide_filters: true,
            custom_preview: Bonfire.UI.Social.Activity.DiscussionPreviewLive
          ]
        },
        # TEMPORARILY DISABLED:
        # trending: %{
        #   name: l_noop("Trending"),
        #   built_in: true,
        #   description: l_noop("Most boosted activities from the last week"),
        #   filters: %FeedFilters{
        #     feed_name: :trending,
        #     exclude_activity_types: [:reply],
        #     sort_by: :popularity_score,
        #     sort_order: :desc,
        #     time_limit: 7
        #   },
        #   exclude_from_nav: false,
        #   icon: "ph:trend-up-duotone",
        #   assigns: [
        #     page: "trending",
        #     page_title: l_noop("Trending"),
        #     feedback_title: l_noop("No trending posts yet"),
        #     feedback_message: l_noop("Posts need to be boosted to appear in trending")
        #   ]
        # },
        # trending_links: %{
        #   name: l_noop("Trending links"),
        #   built_in: true,
        #   description: l_noop("Most boosted posts with links"),
        #   filters: %FeedFilters{
        #     feed_name: :trending_links,
        #     exclude_activity_types: [:reply, :boost],
        #     media_types: [:link],
        #     sort_by: :popularity_score,
        #     sort_order: :desc,
        #     time_limit: 2,
        #     show_objects_only_once: false
        #   },
        #   exclude_from_nav: false,
        #   icon: "ph:newspaper-duotone",
        #   assigns: [
        #     page: "trending_links",
        #     page_title: l_noop("Trending links"),
        #     feedback_title: l_noop("No trending links yet"),
        #     feedback_message: l_noop("Share interesting links to see them here")
        #     # hide_filters: true
        #   ]
        # },
        local_media: %{
          name: l_noop("Local Media"),
          built_in: true,
          description: l_noop("All media shared on the local instance"),
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
      :with_thread_post,
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

        # Thread-deduped feeds: skip reply context joins since we show thread roots only
        "Thread-deduped feed" => %{
          match: %{dedup_by_thread: true},
          include: [],
          exclude: [:with_reply_to, :with_thread_name, :with_thread_post]
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
            :activity_name,
            :with_quote_post_requested
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
          # NOTE: include parent to show "published in" for posts in group
          include: [:with_creator, :with_parent],
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
          include: [:with_parent],
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
        # "Links" => %{
        #   match: %{media_types: [:link]},
        #   include: [
        #     :per_media,
        #     # :with_media,
        #     :with_creator,
        #     :with_post_content
        #     # :with_object_peered (since not loading the object)
        #   ],
        #   exclude: [
        #     :with_media,
        #     # :with_subject,
        #     :with_object,
        #     :with_object_more,
        #     :with_reply_to
        #   ]
        # },
        # Only trending_links uses per_media aggregation (returns Media structs)
        # Other media feeds (images, videos, audio) use standard activity format
        "Media" => %{
          match: %{media_types: "*"},
          # "Trending Links" => %{
          # match: %{feed_name: :trending_links},
          include: [
            :per_media,
            :with_creator,
            :with_post_content
          ],
          exclude: [
            :with_media,
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

    config :bonfire_social, Bonfire.Social.Media,
      default_time_limit:
        System.get_env("TRENDING_LINKS_TIME_LIMIT_DAYS", "7") |> String.to_integer(),
      default_cache_ttl:
        to_timeout(
          hour: System.get_env("TRENDING_LINKS_CACHE_TTL_HOURS", "1") |> String.to_integer()
        )
  end
end
