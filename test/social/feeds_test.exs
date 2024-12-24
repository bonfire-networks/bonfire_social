defmodule Bonfire.Social.FeedsTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Files.Simulation
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Posts
  alias Bonfire.Social.Objects

  alias Bonfire.Me.Users
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake
  use Bonfire.Common.Utils
  import Tesla.Mock
  use Mneme

  @tag mneme: true #, capture_log: false
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

    feed = Bonfire.Social.FeedActivities.feed(:my, current_user: user)

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

    feed = Bonfire.Social.FeedActivities.feed(:local, current_user: user)

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
end
