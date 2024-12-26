defmodule Bonfire.Social.FeedsTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Files.Simulation
  # import Bonfire.Federate.ActivityPub.Simulate
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Posts
  alias Bonfire.Messages
  alias Bonfire.Social.Objects

  alias Bonfire.Me.Users
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake, except: [fake_remote_user!: 0]
  import Tesla.Mock
  use Mneme

  setup_all do
    Tesla.Mock.mock_global(fn
      %{url: "https://doi.org/10.1080/1047840X.2012.720832"} ->
        %Tesla.Env{
          status: 200,
          body: """
          [{"key":"BHXLJBJ6","version":0,"itemType":"journalArticle","creators":[{"firstName":"Michael F.","lastName":"Steger","creatorType":"author"}],"tags":[],"title":"","date":"2012-10-01","ISSN":["1047-840X"],"libraryCatalog":"Taylor and Francis+NEJM","accessDate":"2024-12-26","identifiers":{"url":"https://doi.org/10.1080/1047840X.2012.720832","doi":"10.1080/1047840x.2012.720832"}}]
          """
        }

      env ->
        error(env, "Request not mocked")
    end)

    :ok
  end

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
      Bonfire.Social.Activities.activity_preloads(feed, postloads1, current_user: user)

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
                  |> dump("feed_contains in me after postloads?")

    feed =
      Bonfire.Social.Activities.activity_preloads(feed, :all,
        current_user: user,
        activity_loaded_preloads: postloads1
      )

    # NOTE: by running postloads instead of preloading in original query, we are loading unecessary data sonce

    assert %Bonfire.Data.Social.Activity{
             subject: %Needle.Pointer{
               character: %Bonfire.Data.Identity.Character{},
               profile: %Bonfire.Data.Social.Profile{}
             },
             verb: %Bonfire.Data.AccessControl.Verb{},
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
             |> dump("feed_contains in me after postloads?")

    feed = Bonfire.Social.FeedLoader.feed(:local, limit: 3, current_user: user)

    auto_assert %Bonfire.Data.Social.Activity{
                  subject: %Needle.Pointer{character: %Bonfire.Data.Identity.Character{}},
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

  # Get feed presets from config and transform them into test parameters
  @feed_presets Application.compile_env(:bonfire_social, Bonfire.Social.Feeds)[:feed_presets]
  @preload_rules Application.compile_env(:bonfire_social, Bonfire.Social.FeedLoader)[
                   :preload_rules
                 ]
  @preload_default_include Application.compile_env(:bonfire_social, Bonfire.Social.FeedLoader)[
                             :preload_defaults
                           ][:feed][:include]
  @preload_by_context Application.compile_env(:bonfire_social, Bonfire.Social.FeedLoader)[
                        :preload_by_context
                      ]

  # Generate test parameters from config
  @test_params (for {preset, %{filters: filters}} <- @feed_presets do
                  # Get preloads from preload rules based on feed config
                  postloads =
                    Bonfire.Social.FeedLoader.preloads_from_filters(filters, @preload_rules)

                  context_preloads = @preload_by_context[:query] || []

                  preloads =
                    postloads
                    |> Enum.filter(&Enum.member?(context_preloads, &1))

                  %{preset: preset, filters: filters, preloads: preloads, postloads: postloads}
                end) ++
                 [
                   # no filters
                   %{preset: nil, filters: %{}, preloads: [], postloads: []}
                 ]

  # Generate tests dynamically from feed presets - WIP: my, user_posts, messages, user_following, user_followers, remote, my_requests, trending_discussions, local_images, publications
  # for %{preset: preset, filters: filters} = params when preset in [:user_posts] <- @test_params do
  for %{preset: preset, filters: filters} = params <- @test_params do
    describe "feed preset `#{inspect(preset)}` loads feed and configured preloads" do
      setup do
        %{preset: preset} = params = unquote(Macro.escape(params))
        user = fake_user!()

        # Create test content based on the preset
        {object, activity} = create_test_content(preset, user)
        Map.merge(params, %{object: object, activity: activity, user: user})
      end

      test "using preset name", %{
        preset: preset,
        filters: filters,
        preloads: preloads,
        postloads: postloads,
        object: object,
        activity: activity,
        user: user
      } do
        if preset && object do
          feed = Bonfire.Social.FeedLoader.feed(preset, %{}, current_user: user, limit: 3)

          verify_feed(preset, feed, activity, object, user, preloads, postloads)
        end
      end

      # test "`using filters: #{inspect(filters)}", %{preset: preset, filters: filters, preloads: preloads, postloads: postloads, object: object, activity: activity, user: user} do
      #   feed = Bonfire.Social.FeedLoader.feed(nil, filters, current_user: user)

      #     assert loaded_activity = Bonfire.Social.FeedLoader.feed_contains?(feed, object, current_user: user)

      #     verify_preloads(loaded_activity, preloads)

      # end

      # TODO: add some extra cases like mixing a feed_name with filters from a different preset
      # test "returns error for invalid filters", %{user: user} do
      #   assert_raise RuntimeError, fn ->
      #     Bonfire.Social.FeedLoader.feed(preset, %{invalid_filter: true}, current_user: user)
      #   end
      # end
    end
  end

  defp verify_feed(preset, feed, activity, object, user, preloads, postloads) do
    assert loaded_activity =
             Bonfire.Social.FeedLoader.feed_contains?(feed, activity || object,
               current_user: user
             )

    verify_preloads(loaded_activity, preloads)
    verify_preloads(loaded_activity, postloads -- preloads, false)

    loaded_activity =
      Bonfire.Social.Activities.activity_preloads(loaded_activity, postloads,
        current_user: user,
        activity_loaded_preloads: preloads
      )

    verify_data(preset, loaded_activity, activity, object)

    verify_preloads(loaded_activity, postloads)
  end

  defp verify_data(preset, loaded_activity, activity, object) do
    case preset do
      :local_media ->
        assert %{media: [%{id: id}]} = loaded_activity
        assert id == object.id

      _ ->
        debug(preset, "Missing verify_data case")
    end
  end

  defp verify_preloads(activity, expected_preloads, assert? \\ true) do
    debug(expected_preloads, "making sure we are #{if !assert?, do: "NOT "}preloading these")

    for preload <- expected_preloads || [] do
      case preload do
        :with_subject ->
          pattern_matched? =
            match?(
              %{
                subject: %Needle.Pointer{
                  character: %Bonfire.Data.Identity.Character{},
                  profile: %Bonfire.Data.Social.Profile{}
                }
              },
              activity
            ) or match?(%{subject: nil}, activity)

          if assert?,
            do:
              assert(pattern_matched?, "expected subject to be loaded, got #{inspect(activity)}"),
            else:
              refute(
                pattern_matched?,
                "expected subject to NOT be loaded, got #{inspect(activity)}"
              )

        :with_creator ->
          pattern_matched? =
            match?(
              %{
                object: %Needle.Pointer{
                  created: %{
                    creator: %Needle.Pointer{
                      character: %Bonfire.Data.Identity.Character{},
                      profile: %Bonfire.Data.Social.Profile{}
                    }
                  }
                }
              },
              activity
            ) or
              match?(
                %{
                  object: %Needle.Pointer{
                    created: %{creator: nil}
                  }
                },
                activity
              )

          if assert?,
            do:
              assert(pattern_matched?, "expected creator to be loaded, got #{inspect(activity)}"),
            else:
              refute(
                pattern_matched?,
                "expected creator to NOT be loaded, got #{inspect(activity)}"
              )

        :with_post_content ->
          pattern_matched? =
            match?(
              %{
                object: %Needle.Pointer{
                  post_content: %Bonfire.Data.Social.PostContent{}
                }
              },
              activity
            )

          if assert?,
            do:
              assert(
                pattern_matched?,
                "expected post_content to be loaded, got #{inspect(activity)}"
              ),
            else:
              refute(
                pattern_matched?,
                "expected post_content to NOT be loaded, got #{inspect(activity)}"
              )

        :with_object_more ->
          pattern_matched? =
            match?(
              %{
                object: %Needle.Pointer{
                  post_content: %{}
                }
              },
              activity
            ) or
              match?(
                %{
                  object: %Needle.Pointer{
                    post_content: nil
                  }
                },
                activity
              )

          if assert?,
            do:
              assert(
                pattern_matched?,
                "expected object & post_content to be loaded, got #{inspect(activity)}"
              ),
            else:
              refute(
                pattern_matched?,
                "expected object & post_content to NOT be loaded, got #{inspect(activity)}"
              )

        :with_media ->
          # has_media = match?(%{media: _}, activity)
          if assert? do
            # assert has_media
            assert is_list(activity.media)
          else
            refute is_list(activity.media)
          end

        :with_reply_to ->
          pattern_matched? =
            match?(%{replied: %{reply_to: %Needle.Pointer{}}}, activity) or
              match?(%{replied: %{reply_to: nil}}, activity)

          if assert?, do: assert(pattern_matched?), else: refute(pattern_matched?)

        :with_peered ->
          pattern_matched? = match?(%{peer: _}, activity)
          if assert?, do: assert(pattern_matched?), else: refute(pattern_matched?)

        :with_seen ->
          pattern_matched? = Map.has_key?(activity, :seen)
          if assert?, do: assert(pattern_matched?), else: refute(pattern_matched?)

        other ->
          raise "Missing verify_preloads case for #{inspect(other)}"
      end
    end
  end

  # Helper to create appropriate test content based on feed type
  defp create_test_content(preset, user) do
    case preset do
      :my ->
        followed_user = fake_user!()

        assert {:ok, %Bonfire.Data.Social.Follow{} = follow} =
                 Bonfire.Social.Graph.Follows.follow(user, followed_user)

        assert post =
                 fake_post!(followed_user, "public", %{
                   post_content: %{
                     name: "followed user post",
                     html_body: "content from someone I follow"
                   }
                 })

        # FIXME: why is post not appearing in my feed?
        {post, nil}

      :remote ->
        #   remote_user = fake_remote_user!()

        #   post =
        #     fake_post!(remote_user, "public", %{
        #       post_content: %{
        #         name: "remote post",
        #         html_body: "content from fediverse"
        #       }
        #     })

        # TODO
        {nil, nil}

      :notifications ->
        create_test_content(:mentions, user)

      :liked_by_me ->
        assert post =
                 fake_post!(user, "public", %{
                   post_content: %{name: "likeable post", html_body: "content"}
                 })

        assert {:ok, like} = Bonfire.Social.Likes.like(user, post)
        {post, like}

      :user_followers ->
        followed_user = fake_user!()
        assert {:ok, follow} = Bonfire.Social.Graph.Follows.follow(user, followed_user)

        {followed_user, follow}

      :user_following ->
        follower_user = fake_user!()
        assert {:ok, follow} = Bonfire.Social.Graph.Follows.follow(follower_user, user)

        {follower_user, follow}

      :my_requests ->
        # TODO
        {nil, nil}

      :my_bookmarks ->
        assert post =
                 fake_post!(user, "public", %{
                   post_content: %{name: "bookmarkable post", html_body: "content"}
                 })

        assert {:ok, bookmark} = Bonfire.Social.Bookmarks.bookmark(user, post)
        {post, bookmark}

      :hashtag ->
        assert post =
                 fake_post!(user, "public", %{
                   post_content: %{name: "tagged post", html_body: "post with #test"}
                 })

        {post, nil}

      :mentions ->
        other = fake_user!()

        assert post =
                 fake_post!(other, "public", %{
                   post_content: %{name: "mention me", html_body: "@#{user.character.username}"}
                 })

        {post, nil}

      :flagged_by_me ->
        assert post =
                 fake_post!(fake_user!(), "public", %{
                   post_content: %{name: "flagged post", html_body: "content"}
                 })

        assert {:ok, flag} = Bonfire.Social.Flags.flag(user, post)
        {post, flag}

      :flagged_content ->
        assert post =
                 fake_post!(fake_user!(), "public", %{
                   post_content: %{name: "flagged post", html_body: "content"}
                 })

        assert {:ok, flag} = Bonfire.Social.Flags.flag(fake_user!(), post)
        {post, flag}

      :local_images ->
        # assert {:ok, media} = Bonfire.Files.upload(ImageUploader, user, icon_file())
        # post =
        #   fake_post!(user, "public", %{
        #     post_content: %{name: "media post", html_body: "content"},
        #     uploaded_media: [media]
        #   })
        # {media, nil}

        # TODO: images or open science publications attached to a post aren't directly linked to an activity (as opposed to open science publications fetched from ORCID API) so not included in current feed query, so need to adapt the feed query...
        {nil, nil}

      :publications ->
        #   assert {:ok, media} = Bonfire.OpenScience.APIs.fetch_and_publish_work(user, "https://doi.org/10.1080/1047840X.2012.720832")
        #   {media, nil} 

        #  FIXME: feed ends up empty
        {nil, nil}

      :local_media ->
        # TODO: with both image and publication?
        {nil, nil}

      :trending_discussions ->
        # TODO
        {nil, nil}

      :messages ->
        receiver = Fake.fake_user!()

        attrs = %{
          to_circles: [receiver.id],
          post_content: %{name: "test DM", html_body: "content"}
        }

        assert {:ok, message} = Messages.send(user, attrs)

        {receiver, message}

      other when is_nil(other) or other in [:local, :explore, :user_posts, :user_activities] ->
        assert post =
                 fake_post!(user, "public", %{
                   post_content: %{name: "default post", html_body: "content"}
                 })

        {post, nil}

      other ->
        raise "Missing create_test_content case for #{inspect(other)}"
    end
  end
end
