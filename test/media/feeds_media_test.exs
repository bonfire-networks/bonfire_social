defmodule Bonfire.Social.Feeds.MediaTest do
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
      when preset in [
             :audio,
             :videos,
             :images,
             #  :research,
             :local_media,
             :trending_links
           ] <-
        feed_preset_test_params() do
    #  :like_count, :reply_count, 
    sort_by = Faker.Util.pick([nil, :boost_count, :object_count, :trending_score])

    describe "feed preset `#{inspect(preset)}` (ordered by #{sort_by}) loads correct feed" do
      setup do
        %{preset: preset} = params = unquote(Macro.escape(params))
        sort_by = unquote(Macro.escape(sort_by))
        # _admin = fake_admin!("admin user")
        user = fake_admin!("main user")
        # user = fake_user!("main user")
        other_user = fake_user!("other_user")

        # Create test content based on the preset
        {object, activity} = create_test_content(preset, user, other_user)

        # Check media type before proceeding
        if object do
          assert %Bonfire.Files.Media{media_type: media_type} = object
          flood(media_type, "media type for preset #{preset}")
        end

        Map.merge(params, %{
          object: object,
          activity: activity,
          user: user,
          other_user: other_user,
          sort_by: sort_by
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
        other_user: other_user,
        sort_by: sort_by
      } do
        if preset && object do
          Process.put([:bonfire, :default_pagination_limit], 5)

          feed =
            FeedLoader.feed(preset, %{sort_by: sort_by},
              current_user: user,
              # limit: 3,
              by: other_user,
              tags: ["#test", other_user],
              show_objects_only_once: false
            )
            |> Bonfire.Social.Media.preload_newest_activity()
            |> debug("preset feed results")

          FeedLoader.feed(:explore, %{}, current_user: user)
          |> debug("unfiltered feed results")

          verify_feed(preset, feed, activity, object, user, other_user, preloads, postloads)
        end
      end

      sort_by =
        Faker.Util.pick([
          nil,
          :boost_count,
          :like_count,
          :reply_count,
          :object_count,
          :trending_score
        ])

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
          parameterized: parameterized,
          sort_by: sort_by
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
              |> Map.put(:sort_by, sort_by)
              |> flood("parameterized_filters for #{preset}")

            feed =
              FeedLoader.feed(:custom, filters, opts)
              |> Bonfire.Social.Media.preload_newest_activity()

            assert loaded_activity =
                     FeedLoader.feed_contains?(feed, activity || object,
                       current_user: user,
                       postload: false,
                       return_match_fun: fn m -> m end
                     ) ||
                       if(activity,
                         do:
                           FeedLoader.feed_contains?(feed, object,
                             current_user: user,
                             postload: false,
                             return_match_fun: fn m -> m end
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
    assert loaded_media =
             FeedLoader.feed_contains?(feed, activity || object,
               current_user: user,
               postload: false,
               return_match_fun: fn m -> m end
             ) ||
               if(activity,
                 do:
                   FeedLoader.feed_contains?(feed, object,
                     current_user: user,
                     postload: false,
                     return_match_fun: fn m -> m end
                   )
               )

    # Should be a Media struct at top level
    # assert %Bonfire.Files.Media{} = loaded_media
    assert loaded_media.id == object.id ||
             Enums.id(
               FeedLoader.feed_contains?(feed, object,
                 current_user: user,
                 postload: false,
                 return_match_fun: fn m -> m end
               )
             ) == object.id

    # Optionally, check for expected virtual fields
    assert is_integer(loaded_media.object_count)
    assert is_binary(loaded_media.newest_activity_id)

    # Preload activity if present and check
    loaded_media =
      Bonfire.Social.Activities.activity_preloads(loaded_media, postloads,
        current_user: user,
        activity_preloads: {preloads, nil}
      )

    # if Map.has_key?(loaded_media, :activity) and loaded_media.activity do
    #   assert loaded_media.activity.id == activity.id
    # end

    verify_data(preset, loaded_media, activity, object, user, other_user)

    # verify_preloads(loaded_activity, postloads)
  end

  defp verify_data(preset, loaded_media, activity, object, user, other_user) do
    case preset do
      :local_media ->
        assert %Bonfire.Files.Media{id: id} = loaded_media
        assert id == object.id

      # # Optionally, check activity association
      # if Map.has_key?(loaded_media, :activity) and loaded_media.activity do
      #   assert loaded_media.activity.id == activity.id
      # end
      _ ->
        debug(preset, "Missing verify_data case")
    end
  end
end
