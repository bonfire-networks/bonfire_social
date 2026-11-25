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
    sort_by = Faker.Util.pick([nil, :boost_count, :object_count, :popularity_score])

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
          debug(media_type, "media type for preset #{preset}")
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
          :popularity_score
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
              |> debug("parameterized_filters for #{preset}")

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

  # the aggregate reads only the newest activities for a page (`per_media_multiply_limit` of them per row of the page), so a media with older activities must still come in the pages after
  describe "media feed paging with few candidate activities" do
    test "pages through every media once, even when each page reads only a few activities" do
      me = fake_user!("pager")

      media =
        for name <- ~w(a b c d e) do
          url = "https://files.example.org/#{name}/#{Faker.UUID.v4()}"

          {:ok, media} =
            Bonfire.Files.Media.insert(me, url, %{media_type: "image/png", size: 0}, %{url: url})

          media
        end

      # oldest to newest, each media with two posts, so a page of two reads four activities at most
      for round <- 1..2, m <- media do
        fake_post!(me, "public", %{
          post_content: %{html_body: "#{id(m)} #{round}"},
          uploaded_media: [m]
        })
      end

      listed =
        Stream.unfold(:first, fn
          :done ->
            nil

          cursor ->
            paginate = [limit: 2] ++ if(cursor == :first, do: [], else: [after: cursor])

            %{edges: edges, page_info: info} =
              FeedLoader.feed(:local_media, %{},
                current_user: me,
                paginate: paginate,
                per_media_multiply_limit: 1
              )

            {edges, if(edges == [] or is_nil(e(info, :end_cursor, nil)), do: :done, else: e(info, :end_cursor, nil))}
        end)
        |> Enum.take(10)
        |> List.flatten()
        |> Enum.map(&id/1)

      assert Enum.sort(listed) == Enum.sort(Enum.map(media, &id/1)),
             "expected each media once across the pages, got #{inspect(listed)}"
    end
  end

  # a date-sorted media feed picks its newest candidate media by id first, so Postgres drives from those few media into their activities instead of reading every activity in the window
  describe "media feed candidate media" do
    @candidate_media ~r/IN \(SELECT \w+\."id" FROM "bonfire_files_media" AS \w+ .*?ORDER BY \w+\."id" DESC LIMIT \$\d+\)/s

    test "a date-sorted feed limits its activities to the newest media of the requested type" do
      {sql, _params} =
        FeedLoader.feed(:images, %{}, return: :query)
        |> then(&Ecto.Adapters.SQL.to_sql(:all, Bonfire.Common.Repo, &1))

      assert [candidates] = Regex.run(@candidate_media, sql)
      assert candidates =~ "ILIKE", "expected the media type in the candidates, got: #{candidates}"
    end

    test "a feed of any media limits its activities to the newest media too" do
      {sql, _params} =
        FeedLoader.feed(:local_media, %{}, return: :query)
        |> then(&Ecto.Adapters.SQL.to_sql(:all, Bonfire.Common.Repo, &1))

      assert sql =~ @candidate_media
    end

    test "a feed sorted by a metric has no candidate media" do
      {sql, _params} =
        FeedLoader.feed(:images, %{sort_by: :like_count}, return: :query)
        |> then(&Ecto.Adapters.SQL.to_sql(:all, Bonfire.Common.Repo, &1))

      refute sql =~ @candidate_media
    end

    test "pages through every visible media once, in media id order, across pages with no visible media" do
      me = fake_user!("viewer")
      author = fake_user!("author")

      media =
        for name <- ~w(m1 m2 m3 m4 m5 m6 m7 m8 m9), into: %{} do
          url = "https://files.example.org/#{name}/#{Faker.UUID.v4()}"

          {:ok, media} =
            Bonfire.Files.Media.insert(author, url, %{media_type: "image/png", size: 0}, %{
              url: url
            })

          {name, media}
        end

      # m4 to m7 are only on posts the viewer can't see: a whole window of candidates with nothing to show. m2 and m9 are on several posts
      posts = [
        {"m1", "public"},
        {"m2", "public"},
        {"m2", "public"},
        {"m2", "public"},
        {"m3", "public"},
        {"m4", "mentions"},
        {"m5", "mentions"},
        {"m6", "mentions"},
        {"m7", "mentions"},
        {"m8", "public"},
        {"m9", "public"},
        {"m9", "public"}
      ]

      for {{name, boundary}, i} <- Enum.with_index(posts) do
        fake_post!(author, boundary, %{
          post_content: %{html_body: "post #{i} of #{name}"},
          uploaded_media: [media[name]]
        })
      end

      visible = ~w(m9 m8 m3 m2 m1)
      expected = visible |> Enum.map(&id(media[&1])) |> Enum.sort(:desc)

      pages =
        Stream.unfold(:first, fn
          :done ->
            nil

          cursor ->
            paginate = [limit: 2] ++ if(cursor == :first, do: [], else: [after: cursor])

            # candidates per page: 2 * 2, fewer than the 9 media
            %{edges: edges, page_info: info} =
              FeedLoader.feed(:images, %{},
                current_user: me,
                paginate: paginate,
                per_media_multiply_limit: 2
              )

            {edges, e(info, :end_cursor, nil) || :done}
        end)
        |> Enum.take(10)

      listed = pages |> List.flatten()

      assert Enum.map(listed, &id/1) == expected
      assert Enum.all?(pages, &(length(&1) <= 2))

      counts = Map.new(listed, &{id(&1), &1.object_count})
      assert counts[id(media["m2"])] == 3
      assert counts[id(media["m9"])] == 2
      assert counts[id(media["m1"])] == 1
    end
  end

  describe "media feed query shape" do
    # an activity reaches its media either through an attachment (`files.id`) or by being the media itself (`media.id`): joining on either one with an OR can't use any index, so Postgres merge-joined every media row once per activity (48.8s for `local_media` on a large instance)
    test "joins activities to media without an OR across files and media" do
      query = FeedLoader.feed(:local_media, %{}, return: :query)
      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Bonfire.Common.Repo, query)

      assert sql =~ "bonfire_files_media", "expected the media query, got: #{sql}"

      refute sql =~ ~r/ON \(\w+\."id" = \w+\."id"\) OR \(\w+\."id" = \w+\."id"\)/,
             "expected no OR join, got: #{sql}"
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
