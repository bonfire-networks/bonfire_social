defmodule Bonfire.Social.Feeds.PreloadPresetTest do
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

  alias Bonfire.Social.Feeds.PresetFiltersTest

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

  # Generate tests dynamically from feed presets - WIP: my, messages, user_following, user_followers, remote, my_requests, trending_discussions, images, publications
  # for %{preset: preset, filters: filters} = params when preset in [:images] <- feed_preset_test_params() do
  for %{preset: preset, filters: filters} = params
      when preset not in [:user_followers, :user_following, :audio, :videos] <-
        feed_preset_test_params() do
    describe "feed preset `#{inspect(preset)}` loads feed and configured preloads" do
      setup do
        %{preset: preset} = params = unquote(Macro.escape(params))
        # _ = fake_admin!("an admin to be notified of flags")
        user = fake_admin!("main user")
        other_user = fake_user!("other_user")
        third_user = fake_user!("third_user")

        # Create test content based on the preset
        {object, activity} = create_test_content(preset, user, other_user)

        Map.merge(params, %{
          object: object,
          activity: activity,
          user: user,
          other_user: other_user,
          third_user: third_user
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
              tags: ["#test", other_user],
              show_objects_only_once: false
            )

          assert loaded_activity =
                   FeedLoader.feed_contains?(feed, activity || object, current_user: user) ||
                     FeedLoader.feed_contains?(feed, object, current_user: user)

          verify_preloads(loaded_activity, preloads)
          verify_preloads(loaded_activity, postloads -- preloads, false)

          loaded_activity =
            Bonfire.Social.Activities.activity_preloads(loaded_activity, postloads,
              current_user: user,
              activity_preloads: {preloads, nil}
            )

          verify_preloads(loaded_activity, postloads)
        end
      end

      if preset not in [:flagged_content, :flagged_by_me] do
        test "using filters instead of the preset name", %{
          preset: preset,
          filters: filters,
          preloads: preloads,
          # postloads: postloads,
          object: object,
          activity: activity,
          user: user,
          other_user: other_user,
          third_user: third_user
        } do
          if object do
            opts = [
              current_user: user,
              # limit: 3,
              by: other_user,
              tags: ["#test", other_user],
              show_objects_only_once: false
            ]

            filters =
              FeedLoader.parameterize_filters(%{}, filters, opts)
              |> debug("parameterized_filters for #{preset}")

            feed = FeedLoader.feed(:custom, filters, opts)

            assert loaded_activity =
                     FeedLoader.feed_contains?(feed, activity || object, current_user: user) ||
                       FeedLoader.feed_contains?(feed, object, current_user: user)

            verify_preloads(loaded_activity, preloads, true, true) ||
              (
                feed = FeedLoader.feed(:custom, filters, opts)

                if loaded_activity =
                     FeedLoader.feed_contains?(feed, activity || object, current_user: third_user) ||
                       FeedLoader.feed_contains?(feed, object, current_user: user) do
                  verify_preloads(loaded_activity, preloads, true, false)
                end
              )
          end
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

  defp verify_preloads(activity, expected_preloads, expected? \\ true, return_bool? \\ false) do
    debug(expected_preloads, "making sure we are #{if !expected?, do: "NOT "}preloading these")

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

          if return_bool? do
            if expected?, do: pattern_matched?, else: !pattern_matched?
          else
            if expected?,
              do:
                assert(
                  pattern_matched?,
                  "expected subject to be loaded, got #{inspect(activity)}"
                ),
              else:
                refute(
                  pattern_matched?,
                  "expected subject to NOT be loaded, got #{inspect(activity)}"
                )

            true
          end

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

          if return_bool? do
            if expected?, do: pattern_matched?, else: !pattern_matched?
          else
            if expected?,
              do:
                assert(
                  pattern_matched?,
                  "expected creator to be loaded, got #{inspect(activity)}"
                ),
              else:
                refute(
                  pattern_matched?,
                  "expected creator to NOT be loaded, got #{inspect(activity)}"
                )

            true
          end

        :with_object ->
          pattern_matched? =
            match?(
              %{
                object: %Needle.Pointer{}
              },
              activity
            )

          if expected?,
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

          if expected?,
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
          verify_preloads(activity, [:with_object_more], expected?)

        :with_media ->
          # has_media = match?(%{media: _}, activity)
          if expected? do
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

        :per_media ->
          verify_preloads(activity, [:with_media], expected?)

        :with_reply_to ->
          pattern_matched? =
            match?(%{replied: %{reply_to: %Needle.Pointer{}}}, activity) or
              match?(%{replied: %{reply_to: nil}}, activity)

          if expected?,
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

          if expected?,
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

          if expected?,
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
end
