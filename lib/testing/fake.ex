defmodule Bonfire.Social.Fake do
  # import Bonfire.Files.Simulation
  import Untangle
  use Bonfire.Common.E
  # alias Bonfire.Posts
  # alias Bonfire.Social.Graph.Follows
  alias Bonfire.Common
  # alias Common.Types

  def fake_remote_user!() do
    {:ok, user} =
      Common.Utils.maybe_apply(Bonfire.Federate.ActivityPub.Simulate, :fake_remote_user, [])

    user
  end

  def feed_preset_test_params do
    # Get feed presets from config and transform them into test parameters
    feed_presets = Application.fetch_env!(:bonfire_social, Bonfire.Social.Feeds)[:feed_presets]

    preload_rules =
      Application.fetch_env!(:bonfire_social, Bonfire.Social.FeedLoader)[
        :preload_rules
      ]

    # preload_default_include = Application.compile_env(:bonfire_social, Bonfire.Social.FeedLoader)[
    #                            :preload_defaults
    #                          ][:feed][:include]
    preload_by_context =
      Application.fetch_env!(:bonfire_social, Bonfire.Social.FeedLoader)[
        :preload_by_context
      ]

    # Generate test parameters from config
    for {preset, %{filters: filters} = preset_details} <- feed_presets do
      # filters =
      #   Map.merge(filters, preset_details[:parameterized] || %{})
      #   |> debug("filters for #{preset}")

      # |> Enums.struct_to_map()
      # |> Map.drop([:__typename])

      # Get preloads from preload rules based on feed config
      postloads =
        Bonfire.Social.FeedLoader.preloads_from_filters(filters, preload_rules)

      context_preloads = preload_by_context[:query] || []

      preloads =
        postloads
        |> Enum.filter(&Enum.member?(context_preloads, &1))

      # preloads =
      #   if preset in [:local, :remote] do
      #     preloads ++ [:with_object_peered]
      #   else
      #     preloads
      #   end

      %{
        preset: preset,
        filters: filters,
        preloads: preloads,
        postloads: postloads,
        parameterized: preset_details[:parameterized]
      }
    end ++
      [
        # no filters
        %{preset: nil, filters: %{}, preloads: [], postloads: [], parameterized: %{}}
      ]
  end

  # Helper to create appropriate test content based on feed type
  def create_test_content(preset, user, other_user, i \\ 1) do
    case preset do
      :my ->
        {:ok, %Bonfire.Data.Social.Follow{} = follow} =
          Bonfire.Social.Graph.Follows.follow(user, other_user)

        #  {:ok, %Bonfire.Data.Social.Follow{} = follow} =
        #          Bonfire.Social.Graph.Follows.follow(other_user, user)

        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{
              name: "followed user post #{i}",
              html_body: "content from someone I follow #{i}"
            }
          })

        {post, nil}

      :remote ->
        remote_user = Bonfire.Me.Fake.fake_user!("test_remote_user")

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
          Bonfire.Posts.Fake.fake_post!(remote_user, "public", %{
            post_content: %{
              name: "remote post #{i}",
              html_body: "content from fediverse #{i}"
            }
          })

        post_url = "#{instance_url}/post/1"

        # NOTE: it should still work without this
        # {:ok, peered} =
        #   Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(remote_post, post_url)
        #   |> debug("post attached to instance")

        {remote_post, nil}

      :notifications ->
        create_test_content(:likes, other_user, user, i)

        create_test_content(:mentions, user, other_user, i)
        create_test_content(:my_boosts, other_user, user, i)

      :likes ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{name: "likeable post #{i}", html_body: "likeable content #{i}"}
          })

        {:ok, like} = Bonfire.Social.Likes.like(user, post)
        {post, like}

      :my_boosts ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{name: "boostable post #{i}", html_body: "boostable content #{i}"}
          })

        {:ok, boost} = Bonfire.Social.Boosts.boost(user, post)
        {post, boost}

      :user_followers ->
        {:ok, follow} = Bonfire.Social.Graph.Follows.follow(user, other_user)

        {other_user, follow}

      :user_following ->
        {:ok, follow} = Bonfire.Social.Graph.Follows.follow(other_user, user)

        {user, follow}

      :my_requests ->
        # TODO
        {nil, nil}

      :bookmarks ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{
              name: "bookmarkable post #{i}",
              html_body: "bookmarkable content #{i}"
            }
          })

        {:ok, bookmark} = Bonfire.Social.Bookmarks.bookmark(user, post)

        {post, nil}

      :hashtag ->
        post =
          Bonfire.Posts.Fake.fake_post!(user, "public", %{
            post_content: %{name: "tagged post #{i}", html_body: "post with #test #{i}"}
          })

        {post, nil}

      :mentions ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{
              name: "mention me #{i}",
              html_body: "@#{user.character.username} hey #{i}"
            }
          })

        {post, nil}

      :trending_links ->
        post =
          Bonfire.Posts.Fake.fake_post!(user, "public", %{
            post_content: %{
              name: "link post #{i}",
              html_body: "post with link https://doi.org/10.1080/1047840X.2012.720832 #{i}"
            }
          })
          |> flood("created post with link")

        media = e(post, :media, nil) || e(post, :activity, :media, nil) || []

        {List.first(media), post}

      :my_flags ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{name: "flagged post #{i}", html_body: "content #{i}"}
          })

        # {:ok, post} = Bonfire.Posts.read(post.id, current_user: user)

        {:ok, flag} = Bonfire.Social.Flags.flag(user, post)
        {post, flag}

      :flagged_content ->
        post =
          Bonfire.Posts.Fake.fake_post!(
            Bonfire.Me.Fake.fake_user!("author of flagged content #{i}"),
            "mentions",
            %{
              post_content: %{name: "flagged post #{i}", html_body: "content #{i}"}
            }
          )

        {:ok, flag} = Bonfire.Social.Flags.flag(other_user, post)
        {post, flag}

      :image_standalone ->
        media = upload_media(:images, user, "Image Media #{i}")
        activity = publish_media(user, media)

        {media, activity}

      :image_post ->
        media = upload_media(:images, user, "Post Media #{i}")
        post = post_with_media(user, media, "Post with image #{i}")

        {media, post}

      :images ->
        create_media_content(user, other_user, i, :image_standalone, :image_post)

      :video_standalone ->
        media = upload_media(:videos, user, "Video Media #{i}")
        activity = publish_media(user, media)

        {media, activity}

      :video_post ->
        media = upload_media(:videos, user, "Video Media #{i}")
        post = post_with_media(user, media, "Post with video #{i}")

        {media, post}

      :videos ->
        create_media_content(user, other_user, i, :video_standalone, :video_post)

      :audio_standalone ->
        media = upload_media(:audio, user, "Audio Media #{i}")
        activity = publish_media(user, media)

        {media, activity}

      :audio_post ->
        media = upload_media(:audio, user, "Audio Media #{i}")
        post = post_with_media(user, media, "Post with audio #{i}")

        {media, post}

      :audio ->
        create_media_content(user, other_user, i, :audio_standalone, :audio_post)

      :research ->
        {:ok, media} =
          Bonfire.OpenScience.APIs.fetch_and_publish_work(
            user,
            "https://doi.org/10.1080/1047840X.2012.720832"
          )

        {media, nil}

      #  FIXME? feed ends up empty
      # {nil, nil}

      :local_media ->
        # create_media_content(user, other_user, i, :audio_standalone, :audio_post) # TODO: more content?
        create_media_content(user, other_user, i, :image_standalone, :image_post)

      :trending_discussions ->
        # TODO
        {nil, nil}

      :events ->
        # TODO
        {nil, nil}

      :books ->
        # TODO
        {nil, nil}

      :messages ->
        #   receiver = Fake.Bonfire.Me.Fake.fake_user!()
        #   attrs = %{
        #     to_circles: [receiver.id],
        #     post_content: %{name: "test DM", html_body: "content"}
        #   }
        #    {:ok, message} = Messages.send(user, attrs)
        #   {receiver, message}

        # TODO?
        {nil, nil}

      :discussions ->
        original_post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{name: "original post #{i}", html_body: "original post content #{i}"}
          })

        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            reply_to_id: original_post.id,
            post_content: %{html_body: "default post content (as reply of #{i})"}
          })

        {post, nil}

      :local ->
        create_test_content(:discussions, user, other_user, i)

      :explore ->
        {local_post, _} = create_test_content(:local, user, other_user, i)
        {remote_post, _} = create_test_content(:remote, user, other_user, i)

        {local_post, remote_post}

      :articles ->
        attrs = %{
          post_content: %{
            name: "article with title #{i}",
            html_body: String.duplicate("very long content ", 100)
          }
        }

        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", attrs)

        {post, nil}

      other
      when is_nil(other) or other in [:posts, :user_by_object_type, :user_activities] ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{html_body: "default post content #{i}"}
          })

        {post, nil}

      other ->
        raise "Missing create_test_content case for #{inspect(other)}"
    end
  end

  defp create_media_content(
         user,
         other_user,
         i,
         standalone_type \\ :image_standalone,
         post_type \\ :image_post
       ) do
    # first create a Media as object
    {media_standalone, activity} = create_test_content(standalone_type, user, other_user, i)

    # also create a media to attach to a post
    {media_attachment, post} = create_test_content(post_type, user, other_user, i)

    # {media_standalone, post} # FIXME: standalone media should also appear in feed
  end

  def post_with_media(user, media_or_type \\ :images, label) do
    media =
      case media_or_type do
        %{} -> media_or_type
        type -> upload_media(media_or_type, user, "Post Media #{label}")
      end

    Bonfire.Posts.Fake.fake_post!(user, "public", %{
      post_content: %{name: "Post with Media #{label}", html_body: "media content post"},
      uploaded_media: [media]
    })
  end

  def publish_media(user, media) do
    {:ok, activity} =
      Bonfire.Files.Media.publish(
        user,
        media,
        boundary: "public"
      )

    activity
  end

  def upload_media(type, user, label \\ nil)

  def upload_media(:images, user, label) do
    {:ok, media} =
      Bonfire.Files.upload(
        Bonfire.Files.ImageUploader,
        user,
        Bonfire.Files.Simulation.icon_file(),
        %{
          metadata: %{label: label || "Image Media"}
        }
      )

    media
  end

  def upload_media(:videos, user, label) do
    {:ok, media} =
      Bonfire.Files.upload(
        Bonfire.Files.VideoUploader,
        user,
        Bonfire.Files.Simulation.video_file(),
        %{
          metadata: %{label: label || "Video Media"}
        }
      )

    media
  end

  def upload_media(:audio, user, label) do
    {:ok, media} =
      Bonfire.Files.upload(
        Bonfire.Files.DocumentUploader,
        user,
        Bonfire.Files.Simulation.audio_file(),
        %{
          metadata: %{label: label || "Audio Media"}
        }
      )

    media
  end
end
