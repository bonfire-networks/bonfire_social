defmodule Bonfire.Social.FeedsTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Files.Simulation
  # import Bonfire.Federate.ActivityPub.Simulate
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Posts
  alias Bonfire.Social.Objects

  alias Bonfire.Me.Users
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake, except: [fake_remote_user!: 0]
  use Bonfire.Common.Utils
  import Tesla.Mock
  use Mneme

  @moduletag mneme: true #, capture_log: false

  test "shows a public post in local feed" do
    user = fake_user!()
    another_local_user = fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "summary",
          name: "name",
          html_body: "epic html"
        }
      })

    post_id = id(post)

    reply =
      fake_post!(user, "public", %{
        reply_to_id: post_id,
        post_content: %{
          summary: "summary",
          name: "name",
          html_body: "epic html"
        }
      })

    feed = Bonfire.Social.FeedLoader.feed(:my, current_user: user)

    auto_assert %Bonfire.Data.Social.Activity{
                  subject: %Ecto.Association.NotLoaded{},
                  verb: %Ecto.Association.NotLoaded{},
                  object: %Ecto.Association.NotLoaded{},
                  replied: %Ecto.Association.NotLoaded{},
                  labelled: %Ecto.Association.NotLoaded{},
                  sensitive: %Ecto.Association.NotLoaded{}
                } <-
                  Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)

    # |> IO.inspect(label: "feed_contains in me?")
    postloads1 = [:with_subject, :with_object_more]
    feed =
      Bonfire.Social.Activities.activity_preloads(feed, postloads1,
        current_user: user
      )

    auto_assert %Bonfire.Data.Social.Activity{
                  subject: %Needle.Pointer{
                    character: %Bonfire.Data.Identity.Character{},
                    profile: %Bonfire.Data.Social.Profile{}
                  },
                  verb: %Ecto.Association.NotLoaded{},
                  object: %Needle.Pointer{post_content: %Bonfire.Data.Social.PostContent{}},
                  replied: %Bonfire.Data.Social.Replied{},
                  labelled: %Ecto.Association.NotLoaded{},
                  sensitive: %Ecto.Association.NotLoaded{}
                } <-
                  Bonfire.Social.FeedLoader.feed_contains?(feed, reply, current_user: user)
                  |> dump( "feed_contains in me after postloads?")

    feed = Bonfire.Social.Activities.activity_preloads(feed, :all, current_user: user, activity_loaded_preloads: postloads1)

    # NOTE: by running postloads instead of preloading in original query, we are loading unecessary data sonce

    assert %Bonfire.Data.Social.Activity{
             subject: %Needle.Pointer{
               character: %Bonfire.Data.Identity.Character{},
               profile: %Bonfire.Data.Social.Profile{}
             },
             verb: %Bonfire.Data.AccessControl.Verb{verb: _},
             object: %Needle.Pointer{
               post_content: %Bonfire.Data.Social.PostContent{},
               created: %Bonfire.Data.Social.Created{creator: nil}
             },
             replied: %Bonfire.Data.Social.Replied{
               # thread: %Needle.Pointer{named: nil}, # FIXME: create named mixin only when not empty
               thread: %Needle.Pointer{named: %{name: nil}},
               reply_to: %Needle.Pointer{
                 id: post_id,
                 post_content: %Bonfire.Data.Social.PostContent{},
                 created: %Bonfire.Data.Social.Created{
                   creator: %Needle.Pointer{
                     character: %Bonfire.Data.Identity.Character{},
                     profile: %Bonfire.Data.Social.Profile{}
                   }
                 }
               }
             },
             labelled: nil,
             sensitive: %Bonfire.Data.Social.Sensitive{is_sensitive: true},
             media: [],
             tags: [],
             seen: nil
           } =
             Bonfire.Social.FeedLoader.feed_contains?(feed, reply, current_user: user)
             |> dump( "feed_contains in me after postloads?")

    feed = Bonfire.Social.FeedLoader.feed(:local, current_user: user)

    auto_assert %Bonfire.Data.Social.Activity{
                  subject: %Needle.Pointer{character: %{id: _}},
                  verb: %Ecto.Association.NotLoaded{},
                  object: %Needle.Pointer{post_content: %Ecto.Association.NotLoaded{}},
                  replied: %Ecto.Association.NotLoaded{},
                  labelled: %Ecto.Association.NotLoaded{},
                  sensitive: %Ecto.Association.NotLoaded{}
                } <-
                  Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)

    # |> dump( "feed_contains in local?")

    # check that we show it to others
    assert Bonfire.Social.FeedLoader.feed_contains?(:local, post,
             current_user: another_local_user
           )
  end


  test "shows activities in my feed (people I follow)" do
    user = fake_user!()
    followed_user = fake_user!()
    Bonfire.Social.Graph.Follows.follow(user, followed_user)

    post = fake_post!(followed_user, "public", %{
      post_content: %{
        summary: "followed user post",
        html_body: "content from someone I follow"
      }
    })

    feed = Bonfire.Social.FeedLoader.feed(:my, current_user: user)
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)
  end

  @tag mneme: true 
  test "shows activities in explore feed" do
    user = fake_user!()
    another_user = fake_user!()

    post = fake_post!(another_user, "public", %{
      post_content: %{
        summary: "public post",
        html_body: "visible in explore"
      }
    })

    feed = Bonfire.Social.FeedLoader.feed(:explore, current_user: user)
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)
  end

  test "filters feed by hashtag" do
    user = fake_user!()
    post = fake_post!(user, "public", %{
      post_content: %{
        summary: "tagged post",
        html_body: "post with #test hashtag"
      }
    })

    
    feed = Bonfire.Social.FeedLoader.feed(:explore, %{tags: ["test"]}, current_user: user)
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)
  end

  test "filters feed by activity type (likes)" do
    user = fake_user!()
    liker = fake_user!()
    post = fake_post!(user, "public", %{
      post_content: %{
        summary: "likeable post",
        html_body: "content to be liked"
      }
    })

    {:ok, like} = Bonfire.Social.Likes.like(liker, post)
    
    feed = Bonfire.Social.FeedLoader.feed(:explore, %{activity_types: ["like"]}, 
      current_user: user
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, like, current_user: user)
  end

  test "filters feed by media type" do
    user = fake_user!()
    image_post = fake_post!(user, "public", %{
      post_content: %{
        summary: "image post",
        html_body: "post with image"
      },
      media: [%{type: "image", url: "test.jpg"}]
    })
    
    feed = Bonfire.Social.FeedLoader.feed(:explore, %{media_types: ["image"]}, 
      current_user: user
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, image_post, current_user: user)
  end

  test "filters feed by time limit" do
    user = fake_user!()
    old_post = fake_post!(user, "public", %{
      post_content: %{
        summary: "old post",
        html_body: "old content"
      },
      inserted_at: DateTime.add(DateTime.utc_now(), -40, :day) # FIXME
    })
    
    new_post = fake_post!(user, "public", %{
      post_content: %{
        summary: "new post",
        html_body: "new content"
      }
    })
    
    feed = Bonfire.Social.FeedLoader.feed(:explore, %{time_limit: 30}, 
      current_user: user
    )
    
    refute Bonfire.Social.FeedLoader.feed_contains?(feed, old_post, current_user: user)
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, new_post, current_user: user)
  end

  # test "shows notifications for user" do
  #   user = fake_user!()
  #   notifier = fake_user!()
    
  #   notification = fake_notification!(
  #     from: notifier,
  #     to: user,
  #     type: "mention",
  #     content: "mentioned you in a post"
  #   )
    
  #   feed = Bonfire.Social.FeedLoader.feed(:notifications, current_user: user)
    
  #   assert Bonfire.Social.FeedLoader.feed_contains?(feed, notification, current_user: user)
  # end

  # test "shows messages for user" do
  #   user = fake_user!()
  #   sender = fake_user!()
    
  #   message = fake_message!(
  #     from: sender,
  #     to: user,
  #     content: "direct message content"
  #   )
    
  #   feed = Bonfire.Social.FeedLoader.feed(:messages, current_user: user)
    
  #   assert Bonfire.Social.FeedLoader.feed_contains?(feed, message, current_user: user)
  # end

  test "shows specific user's activities" do
    user = fake_user!()
    target_user = fake_user!()
    
    post = fake_post!(target_user, "public", %{
      post_content: %{
        summary: "user specific post",
        html_body: "content from specific user"
      }
    })
    
    feed = Bonfire.Social.FeedLoader.feed(:user_activities, %{by: target_user.id},
      current_user: user
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)
  end

  test "shows flagged content (mods only)" do
    mod = fake_user!(%{is_moderator: true})
    user = fake_user!()
    user2 = fake_user!()
    
    post = fake_post!(user, "public", %{
      post_content: %{
        summary: "flagged post",
        html_body: "potentially problematic content"
      }
    })
    
    {:ok, flag} = Bonfire.Social.Flags.flag(user2, post)
    
    feed = Bonfire.Social.FeedLoader.feed(:flagged_content, %{activity_types: ["flag"]}, 
      current_user: mod
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, flag, current_user: mod)
  end


  test "shows remote/fediverse feed" do
    user = fake_user!()
    remote_user = fake_remote_user!()

    post = fake_post!(remote_user, "public", %{
      post_content: %{
        summary: "remote post",
        html_body: "content from fediverse"
      }
    })

    feed = Bonfire.Social.FeedLoader.feed(:remote, current_user: user)
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)
  end

  test "shows bookmarked by me feed" do
    user = fake_user!()
    another_user = fake_user!()
    
    post = fake_post!(another_user, "public", %{
      post_content: %{
        summary: "bookmarkable post",
        html_body: "content to bookmark"
      }
    })

    {:ok, bookmark} = Bonfire.Social.Bookmarks.bookmark(user, post)
    
    feed = Bonfire.Social.FeedLoader.feed(:my_bookmarks,  %{activity_types: ["bookmark"], subjects: [user.id]}, 
      current_user: user
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, bookmark, current_user: user)
  end

  test "shows followed by specific user feed" do
    user = fake_user!()
    follower = fake_user!()
    followed_user = fake_user!()
    
    {:ok, follow} = Bonfire.Social.Graph.Follows.follow(follower, followed_user)
    
    feed = Bonfire.Social.FeedLoader.feed(:user_following, %{activity_types: ["follow"], subjects: [follower.id]}, 
      current_user: user
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, follow, current_user: user)
  end

  test "shows followers of specific user feed" do
    user = fake_user!()
    target_user = fake_user!()
    follower = fake_user!()
    
    {:ok, follow} = Bonfire.Social.Graph.Follows.follow(follower, target_user)
    
    feed = Bonfire.Social.FeedLoader.feed(:user_followers, %{object_types: ["follow"], objects: [target_user.id]}, 
      current_user: user
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, follow, current_user: user)
  end

  # test "shows all known publications feed" do
  #   user = fake_user!()
  #   publisher = fake_user!()
    
  #   publication = fake_post!(publisher, "public", %{
  #     post_content: %{
  #       summary: "publication post",
  #       html_body: "published content"
  #     },
  #     type: "publication"
  #   })
    
  #   feed = Bonfire.Social.FeedLoader.feed(:explore, %{object_types: ["publication"]}, 
  #     current_user: user
  #   )
    
  #   assert Bonfire.Social.FeedLoader.feed_contains?(feed, publication, current_user: user)
  # end

  test "can filter with multiple hashtags" do
    user = fake_user!()
    post = fake_post!(user, "public", %{
      post_content: %{
        summary: "multi-tagged post",
        html_body: "post with a tag #test"
      }
    })

    post2 = fake_post!(user, "public", %{
      post_content: %{
        summary: "multi-tagged post",
        html_body: "post with a tag #example"
      }
    })

    feed = Bonfire.Social.FeedLoader.feed(:explore, %{tags: ["#test", "#example"]}, 
      current_user: user
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, post2, current_user: user)
  end

  test "shows feed with multiple activity types" do
    user = fake_user!()
    target_user = fake_user!()
    post = fake_post!(target_user, "public", %{
      post_content: %{
        summary: "multi-action post",
        html_body: "content for multiple actions"
      }
    })

    {:ok, like} = Bonfire.Social.Likes.like(user, post)
    {:ok, boost} = Bonfire.Social.Boosts.boost(user, post)
    
    feed = Bonfire.Social.FeedLoader.feed(:explore,  %{activity_types: ["like", "boost"]}, 
      current_user: user
    )
    

    assert Bonfire.Social.FeedLoader.feed_contains?(feed, like, current_user: user)
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, boost, current_user: user)
  end

  test "shows feed sorted by boosts count" do
    user = fake_user!()
    post1 = fake_post!(user, "public", %{
      post_content: %{
        summary: "popular post",
        html_body: "content with many boosts"
      }
    })
    
    post2 = fake_post!(user, "public", %{
      post_content: %{
        summary: "less popular post",
        html_body: "content with fewer boosts"
      }
    })

    # Create multiple boosts for post1
    Enum.each(1..3, fn _ ->
      booster = fake_user!()
      Bonfire.Social.Boosts.boost(booster, post1)
    end)

    # Create single boost for post2
    booster = fake_user!()
    Bonfire.Social.Boosts.boost(booster, post2)
    
    %{edges: [first_result | _]} = Bonfire.Social.FeedLoader.feed(:explore,  %{sort_by: :boosts_count, sort_order: :desc}, 
      current_user: user
    )
    
    assert first_result.activity.object_id == post1.id
  end

  test "shows feed with both tag and media type filters" do
    user = fake_user!()
    post = fake_post!(user, "public", %{
      post_content: %{
        summary: "tagged image post",
        html_body: "post with image and tag #photography"
      },
      media: [%{type: "image", url: "test.jpg"}]
    })
    
    feed = Bonfire.Social.FeedLoader.feed(:explore, %{
        tags: ["photography"],
        media_types: ["image"]
      }, 
      current_user: user
    )
    
    assert Bonfire.Social.FeedLoader.feed_contains?(feed, post, current_user: user)
  end

  # test "shows requested activities feed" do
  #   user = fake_user!()
  #   requester = fake_user!()
    
  #   request = fake_request!(
  #     from: requester,
  #     to: user,
  #     type: "follow_request"
  #   )
    
  #   feed = Bonfire.Social.FeedLoader.feed(:notifications, %{activity_types: ["request"]}, 
  #     current_user: user
  #   )
    
  #   assert Bonfire.Social.FeedLoader.feed_contains?(feed, request, current_user: user)
  # end

  # test "shows publications by specific user" do
  #   user = fake_user!()
  #   publisher = fake_user!()
    
  #   publication = fake_post!(publisher, "public", %{
  #     post_content: %{
  #       summary: "user publication",
  #       html_body: "published content"
  #     },
  #     type: "publication"
  #   })
    
  #   feed = Bonfire.Social.FeedLoader.feed(:user_activities, %{
  #       object_types: ["publication"],
  #       creators: [publisher.id]
  #     }, 
  #     current_user: user
  #   )
    
  #   assert Bonfire.Social.FeedLoader.feed_contains?(feed, publication, current_user: user)
  # end



end
