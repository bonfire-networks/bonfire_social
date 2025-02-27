defmodule Bonfire.Social.FeedsPresetTest do
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
  # use Mneme

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
  @test_params (for {preset, %{filters: filters} = preset_details} <- @feed_presets do
                  filters =
                    Map.merge(filters, preset_details[:parameterized] || %{})
                    |> IO.inspect(label: "filters for #{preset}")

                  # |> Enums.struct_to_map()
                  # |> Map.drop([:__typename])

                  # Get preloads from preload rules based on feed config
                  postloads =
                    FeedLoader.preloads_from_filters(filters, @preload_rules)

                  context_preloads = @preload_by_context[:query] || []

                  preloads =
                    postloads
                    |> Enum.filter(&Enum.member?(context_preloads, &1))

                  preloads =
                    if preset in [:local, :remote] do
                      preloads ++ [:with_peered]
                    else
                      preloads
                    end

                  %{preset: preset, filters: filters, preloads: preloads, postloads: postloads}
                end) ++
                 [
                   # no filters
                   %{preset: nil, filters: %{}, preloads: [], postloads: []}
                 ]

  # Generate tests dynamically from feed presets - WIP: my, messages, user_following, user_followers, remote, my_requests, trending_discussions, local_images, publications
  # for %{preset: preset, filters: filters} = params when preset in [:my_bookmarks] <- @test_params do
  for %{preset: preset, filters: filters} = params <- @test_params do
    describe "feed preset `#{inspect(preset)}` loads feed and configured preloads" do
      setup do
        %{preset: preset} = params = unquote(Macro.escape(params))
        user = fake_user!("main user")
        other_user = fake_user!("other_user")

        # Create test content based on the preset
        {object, activity} = create_test_content(preset, user, other_user)

        Map.merge(params, %{
          object: object,
          activity: activity,
          user: user,
          other_user: other_user
        })
      end

      test "using preset name", %{
        preset: preset,
        filters: filters,
        preloads: preloads,
        postloads: postloads,
        object: object,
        activity: activity,
        user: user,
        other_user: other_user
      } do
        if preset && object do
          feed =
            FeedLoader.feed(preset, %{},
              current_user: user,
              # limit: 3,
              by: other_user,
              tags: "#test",
              show_objects_only_once: false
            )

          verify_feed(preset, feed, activity, object, user, other_user, preloads, postloads)
        end
      end

      test "using filters instead of the preset name", %{
        preset: preset,
        filters: filters,
        preloads: preloads,
        # postloads: postloads,
        object: object,
        activity: activity,
        user: user,
        other_user: other_user
      } do
        if object do
          opts = [
            current_user: user,
            # limit: 3,
            by: other_user,
            tags: ["test"],
            show_objects_only_once: false
          ]

          filters =
            FeedLoader.parameterize_filters(%{}, filters, opts)
            |> debug("parameterized_filters for #{preset}")

          feed = FeedLoader.feed(:custom, filters, opts)

          assert loaded_activity =
                   FeedLoader.feed_contains?(feed, activity || object, current_user: user)

          verify_preloads(loaded_activity, preloads)
        end
      end

      # TODO: add some extra cases like mixing a feed_name with filters from a different preset
      # test "returns error for invalid filters", %{user: user} do
      #   assert_raise RuntimeError, fn ->
      #     FeedLoader.feed(preset, %{invalid_filter: true}, current_user: user)
      #   end
      # end
    end
  end

  defp verify_feed(preset, feed, activity, object, user, other_user, preloads, postloads) do
    assert loaded_activity =
             FeedLoader.feed_contains?(feed, activity || object, current_user: user)

    verify_preloads(loaded_activity, preloads)
    verify_preloads(loaded_activity, postloads -- preloads, false)

    loaded_activity =
      Bonfire.Social.Activities.activity_preloads(loaded_activity, postloads,
        current_user: user,
        activity_preloads: {preloads, nil}
      )

    verify_data(preset, loaded_activity, activity, object, user, other_user)

    verify_preloads(loaded_activity, postloads)
  end

  defp verify_data(preset, loaded_activity, activity, object, user, other_user) do
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

        :with_object ->
          pattern_matched? =
            match?(
              %{
                object: %Needle.Pointer{}
              },
              activity
            )

          if assert?,
            do:
              assert(
                pattern_matched?,
                "expected object to be loaded, got #{inspect(activity)}"
              ),
            else:
              refute(
                pattern_matched?,
                "expected object to NOT be loaded, got #{inspect(activity)}"
              )

        :with_object_more ->
          pattern_matched? =
            match?(
              %{
                object: %Needle.Pointer{
                  post_content: %Bonfire.Data.Social.PostContent{}
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

        :with_post_content ->
          verify_preloads(activity, [:with_object_more], assert?)

        :with_media ->
          # has_media = match?(%{media: _}, activity)
          if assert? do
            # assert has_media
            assert(
              is_list(activity.media),
              "expected media to be loaded, got #{inspect(activity)}"
            )
          else
            refute(
              is_list(activity.media),
              "expected media to NOT be loaded, got #{inspect(activity)}"
            )
          end

        :with_reply_to ->
          pattern_matched? =
            match?(%{replied: %{reply_to: %Needle.Pointer{}}}, activity) or
              match?(%{replied: %{reply_to: nil}}, activity)

          if assert?,
            do:
              assert(
                pattern_matched?,
                "expected reply_to to be loaded, got #{inspect(activity)}"
              ),
            else:
              refute(
                pattern_matched?,
                "expected reply_to to NOT be loaded, got #{inspect(activity)}"
              )

        :with_peered ->
          pattern_matched? =
            match?(%{object: %{peered: nil}}, activity) or
              match?(%{object: %{peered: %{id: _}}}, activity)

          if assert?,
            do:
              assert(
                pattern_matched?,
                "expected object peered to be loaded, got #{inspect(activity)}"
              ),
            else:
              refute(
                pattern_matched?,
                "expected object peered to NOT be loaded, got #{inspect(activity)}"
              )

        :with_seen ->
          pattern_matched? =
            match?(
              %{
                seen: nil
              },
              activity
            ) or
              match?(
                %{
                  seen: %Bonfire.Data.Social.Seen{}
                },
                activity
              )

          if assert?,
            do:
              assert(
                pattern_matched?,
                "expected activity seen to be loaded, got #{inspect(activity)}"
              ),
            else:
              refute(
                pattern_matched?,
                "expected activity seen to NOT be loaded, got #{inspect(activity)}"
              )

        other ->
          raise "Missing verify_preloads case for #{inspect(other)}"
      end
    end
  end

  # Helper to create appropriate test content based on feed type
  defp create_test_content(preset, user, other_user) do
    case preset do
      :my ->
        other_user = fake_user!("other_user")

        assert {:ok, %Bonfire.Data.Social.Follow{} = follow} =
                 Bonfire.Social.Graph.Follows.follow(user, other_user)

        # assert {:ok, %Bonfire.Data.Social.Follow{} = follow} =
        #          Bonfire.Social.Graph.Follows.follow(other_user, user)

        assert post =
                 fake_post!(other_user, "public", %{
                   post_content: %{
                     name: "followed user post",
                     html_body: "content from someone I follow"
                   }
                 })

        # FIXME: why is post not appearing in my feed?
        {post, nil}

      :remote ->
        remote_user = fake_user!("remote_user")

        instance_domain = "example.local"
        instance_url = "https://#{instance_domain}"
        actor_url = "#{instance_url}/actors/other_user"

        {:ok, instance} =
          Bonfire.Federate.ActivityPub.Instances.get_or_create(instance_url)
          |> debug("instance created")

        {:ok, peered} =
          Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(remote_user, actor_url)
          |> debug("user attached to instance")

        remote_post =
          fake_post!(remote_user, "public", %{
            post_content: %{
              name: "remote post",
              html_body: "content from fediverse"
            }
          })

        post_url = "#{instance_url}/post/1"

        {:ok, peered} =
          Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(remote_post, post_url)
          |> debug("post attached to instance")

        {remote_post, nil}

      :notifications ->
        create_test_content(:mentions, user, other_user)

      :liked_by_me ->
        assert post =
                 fake_post!(other_user, "public", %{
                   post_content: %{name: "likeable post", html_body: "content"}
                 })

        assert {:ok, like} = Bonfire.Social.Likes.like(user, post)
        {post, like}

      :user_followers ->
        assert {:ok, follow} = Bonfire.Social.Graph.Follows.follow(user, other_user)

        {other_user, follow}

      :user_following ->
        assert {:ok, follow} = Bonfire.Social.Graph.Follows.follow(other_user, user)

        {user, follow}

      :my_requests ->
        # TODO
        {nil, nil}

      :my_bookmarks ->
        assert post =
                 fake_post!(user, "public", %{
                   post_content: %{name: "bookmarkable post", html_body: "content"}
                 })

        assert {:ok, bookmark} = Bonfire.Social.Bookmarks.bookmark(user, post)

        {post, nil}

      :hashtag ->
        assert post =
                 fake_post!(user, "public", %{
                   post_content: %{name: "tagged post", html_body: "post with #test"}
                 })

        {post, nil}

      :mentions ->
        assert post =
                 fake_post!(other_user, "public", %{
                   post_content: %{name: "mention me", html_body: "@#{user.character.username}"}
                 })

        {post, nil}

      :flagged_by_me ->
        assert post =
                 fake_post!(other_user, "public", %{
                   post_content: %{name: "flagged post", html_body: "content"}
                 })

        assert {:ok, flag} = Bonfire.Social.Flags.flag(user, post)
        {post, flag}

      :flagged_content ->
        assert post =
                 fake_post!(fake_user!(), "mentions", %{
                   post_content: %{name: "flagged post", html_body: "content"}
                 })

        assert {:ok, flag} = Bonfire.Social.Flags.flag(other_user, post)
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

      :research ->
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
        #   receiver = Fake.fake_user!()
        #   attrs = %{
        #     to_circles: [receiver.id],
        #     post_content: %{name: "test DM", html_body: "content"}
        #   }
        #   assert {:ok, message} = Messages.send(user, attrs)
        #   {receiver, message}

        # TODO?
        {nil, nil}

      other
      when is_nil(other) or other in [:local, :explore, :user_by_object_type, :user_activities] ->
        assert post =
                 fake_post!(other_user, "public", %{
                   post_content: %{name: "default post", html_body: "content"}
                 })

        {post, nil}

      other ->
        raise "Missing create_test_content case for #{inspect(other)}"
    end
  end
end
