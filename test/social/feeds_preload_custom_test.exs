defmodule Bonfire.Social.Feeds.PreloadCustomTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Files.Simulation
  # import Bonfire.Federate.ActivityPub.Simulate
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Posts
  alias Bonfire.Messages
  alias Bonfire.Social.Objects

  alias Bonfire.Me.Users
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake, except: [fake_remote_user!: 0]
  import Tesla.Mock
  use Mneme

  # , capture_log: false
  @moduletag mneme: true

  test "shows a public post in local feed with manually requested preloads" do
    user = fake_user!()
    another_local_user = fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          name: "name",
          html_body: "epic html"
        }
      })

    post_id = id(post)

    reply =
      fake_post!(user, "public", %{
        reply_to_id: post_id,
        post_content: %{
          # name: "name",
          html_body: "epic html"
        }
      })

    feed = FeedLoader.feed(:my, current_user: user)

    activity = FeedLoader.feed_contains?(feed, post, current_user: user)

    auto_assert %Bonfire.Data.Social.Activity{
                  # because current_user is the subject
                  subject: nil,
                  verb: %Ecto.Association.NotLoaded{},
                  object: %Needle.Pointer{
                    created: %Bonfire.Data.Social.Created{creator: nil},
                    peered: %Ecto.Association.NotLoaded{},
                    #  because :with_creator preloads the object
                    post_content: %Ecto.Association.NotLoaded{}
                  },
                  replied: %Ecto.Association.NotLoaded{},
                  labelled: %Ecto.Association.NotLoaded{},
                  sensitive: %Ecto.Association.NotLoaded{}
                } <- activity

    # |> IO.inspect(label: "feed_contains in me?")
    postloads1 = [:with_subject, :with_object_more, :with_peered]

    activity =
      Bonfire.Social.Activities.activity_preloads(activity, postloads1, current_user: user)

    auto_assert %Bonfire.Data.Social.Activity{
                  # subject: %Needle.Pointer{
                  #   character: %Bonfire.Data.Identity.Character{},
                  #   profile: %Bonfire.Data.Social.Profile{}
                  # },
                  # because current_user is the subject
                  subject: nil,
                  verb: %Ecto.Association.NotLoaded{},
                  object: %Needle.Pointer{
                    created: %Bonfire.Data.Social.Created{creator: nil},
                    peered: nil,
                    post_content: %Bonfire.Data.Social.PostContent{}
                  },
                  replied: %Bonfire.Data.Social.Replied{},
                  labelled: %Ecto.Association.NotLoaded{},
                  sensitive: %Ecto.Association.NotLoaded{}
                } <- activity

    # |> dump("after postloads?")

    assert activity =
             FeedLoader.feed_contains?(feed, reply, current_user: user)
             |> Bonfire.Social.Activities.activity_preloads(:all,
               current_user: user,
               activity_preloads: {postloads1, nil}
             )

    # NOTE: by running postloads instead of preloading in original query, we are loading unecessary data sonce

    assert %Bonfire.Data.Social.Activity{
             # because current_user is the subject
             subject: nil,
             verb: %Bonfire.Data.AccessControl.Verb{verb: "Create"},
             object: %Needle.Pointer{
               post_content: %Bonfire.Data.Social.PostContent{html_body: "epic html"},
               created: %Bonfire.Data.Social.Created{creator: nil}
             },
             replied: %Bonfire.Data.Social.Replied{
               # FIXME: create named mixin only when not empty
               thread: %Needle.Pointer{named: nil},
               #  thread: %Needle.Pointer{named: %Bonfire.Data.Identity.Named{name: nil}},
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
             sensitive: %Bonfire.Data.Social.Sensitive{is_sensitive: false},
             media: [],
             tags: [],
             seen: nil
           } = activity

    feed = FeedLoader.feed(:local, limit: 5, current_user: user)

    auto_assert %Bonfire.Data.Social.Activity{
                  subject: %Needle.Pointer{character: %Bonfire.Data.Identity.Character{}},
                  verb: %Ecto.Association.NotLoaded{},
                  object: %Needle.Pointer{post_content: %Ecto.Association.NotLoaded{}},
                  replied: %Ecto.Association.NotLoaded{},
                  labelled: %Ecto.Association.NotLoaded{},
                  sensitive: %Ecto.Association.NotLoaded{}
                } <-
                  FeedLoader.feed_contains?(feed, post, current_user: user)

    # |> dump( "feed_contains in local?")

    # check that we show it to others
    assert FeedLoader.feed_contains?(:local, post, current_user: another_local_user)
  end
end
