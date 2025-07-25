defmodule Bonfire.Social.Feeds.PresetFiltersTest do
  use Bonfire.Social.DataCase, async: false
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

  # Generate tests dynamically from feed presets - WIP: my, messages, user_following, user_followers, remote, my_requests, trending_discussions, images, publications, my_flags, flagged_content
  # flagged_content, my_flags
  # for %{preset: preset, filters: filters} = params when preset in [:images, :local_media] <- 
  for %{preset: preset, filters: filters} = params
      when preset not in [:audio, :videos, :mentions, :curated, :user_following, :events] <-
        feed_preset_test_params() do
    describe "feed preset `#{inspect(preset)}` loads correct feed" do
      setup do
        %{preset: preset} = params = unquote(Macro.escape(params))
        # _admin = fake_admin!("admin user")
        user = fake_admin!("main user")
        # user = fake_user!("main user")
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
          Process.put([:bonfire, :default_pagination_limit], 5)

          feed =
            FeedLoader.feed(preset, %{},
              current_user: user,
              # limit: 3,
              by: other_user,
              tags: ["#test", other_user],
              show_objects_only_once: false
            )
            |> debug("preset feed results")

          FeedLoader.feed(:explore, %{}, current_user: user)
          |> debug("unfiltered feed results")

          verify_feed(preset, feed, activity, object, user, other_user, preloads, postloads)
        end
      end

      if preset not in [:flagged_content, :my_flags, :bookmarks] do
        test "using filters instead of the preset name", %{
          preset: preset,
          filters: filters,
          preloads: preloads,
          # postloads: postloads,
          object: object,
          activity: activity,
          user: user,
          other_user: other_user,
          parameterized: parameterized
        } do
          if object do
            Process.put([:bonfire, :default_pagination_limit], 5)

            opts = [
              current_user: user,
              # limit: 3,
              by: other_user,
              tags: ["#test", other_user],
              show_objects_only_once: false
            ]

            filters =
              FeedLoader.parameterize_filters(filters, parameterized || %{}, opts)
              |> debug("parameterized_filters for #{preset}")

            feed = FeedLoader.feed(:custom, filters, opts)

            assert loaded_activity =
                     FeedLoader.feed_contains?(feed, activity || object,
                       current_user: user,
                       postload: false
                     ) ||
                       if(activity,
                         do:
                           FeedLoader.feed_contains?(feed, object,
                             current_user: user,
                             postload: false
                           )
                       )

            # verify_preloads(loaded_activity, preloads)
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

  defp verify_feed(preset, feed, activity, object, user, other_user, preloads, postloads) do
    assert loaded_activity =
             FeedLoader.feed_contains?(feed, activity || object,
               current_user: user,
               postload: false
             ) ||
               if(activity,
                 do:
                   FeedLoader.feed_contains?(feed, object,
                     current_user: user,
                     postload: false
                   )
               )

    # verify_preloads(loaded_activity, preloads)
    # verify_preloads(loaded_activity, postloads -- preloads, false)

    loaded_activity =
      Bonfire.Social.Activities.activity_preloads(loaded_activity, postloads,
        current_user: user,
        activity_preloads: {preloads, nil}
      )

    verify_data(preset, loaded_activity, activity, object, user, other_user)

    # verify_preloads(loaded_activity, postloads)
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
end
