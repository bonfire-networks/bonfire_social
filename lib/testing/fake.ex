defmodule Bonfire.Social.Fake do
  import Bonfire.Files.Simulation
  import Untangle
  # alias Bonfire.Common.Utils
  # alias Bonfire.Posts
  # alias Bonfire.Social.Graph.Follows
  alias Bonfire.Common
  # alias Common.Types

  def fake_remote_user!() do
    {:ok, user} =
      Common.Utils.maybe_apply(Bonfire.Federate.ActivityPub.Simulate, :fake_remote_user, [])

    user
  end

  # Helper to create appropriate test content based on feed type
  def create_test_content(preset, user, other_user) do
    case preset do
      :my ->
        other_user = Bonfire.Me.Fake.fake_user!("other_user")

        {:ok, %Bonfire.Data.Social.Follow{} = follow} =
          Bonfire.Social.Graph.Follows.follow(user, other_user)

        #  {:ok, %Bonfire.Data.Social.Follow{} = follow} =
        #          Bonfire.Social.Graph.Follows.follow(other_user, user)

        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{
              name: "followed user post",
              html_body: "content from someone I follow"
            }
          })

        # FIXME: why is post not appearing in my feed?
        {post, nil}

      :remote ->
        remote_user = Bonfire.Me.Fake.fake_user!("remote_user")

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

      :likes ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{name: "likeable post", html_body: "content"}
          })

        {:ok, like} = Bonfire.Social.Likes.like(user, post)
        {post, like}

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
          Bonfire.Posts.Fake.fake_post!(user, "public", %{
            post_content: %{name: "bookmarkable post", html_body: "content"}
          })

        {:ok, bookmark} = Bonfire.Social.Bookmarks.bookmark(user, post)

        {post, nil}

      :hashtag ->
        post =
          Bonfire.Posts.Fake.fake_post!(user, "public", %{
            post_content: %{name: "tagged post", html_body: "post with #test"}
          })

        {post, nil}

      :mentions ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{name: "mention me", html_body: "@#{user.character.username}"}
          })

        {post, nil}

      :flagged_by_me ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{name: "flagged post", html_body: "content"}
          })

        {:ok, post} = Bonfire.Posts.read(post.id, current_user: user)

        {:ok, flag} = Bonfire.Social.Flags.flag(user, post)
        {post, flag}

      :flagged_content ->
        post =
          Bonfire.Posts.Fake.fake_post!(Bonfire.Me.Fake.fake_user!(), "mentions", %{
            post_content: %{name: "flagged post", html_body: "content"}
          })

        {:ok, flag} = Bonfire.Social.Flags.flag(other_user, post)
        {post, flag}

      :local_images ->
        {:ok, media} = Bonfire.Files.upload(Bonfire.Files.ImageUploader, user, icon_file())

        post =
          Bonfire.Posts.Fake.fake_post!(user, "public", %{
            post_content: %{name: "media post", html_body: "content"},
            uploaded_media: [media]
          })

        {media, post}

      :research ->
        #    {:ok, media} = Bonfire.OpenScience.APIs.fetch_and_publish_work(user, "https://doi.org/10.1080/1047840X.2012.720832")
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
        #   receiver = Fake.Bonfire.Me.Fake.fake_user!()
        #   attrs = %{
        #     to_circles: [receiver.id],
        #     post_content: %{name: "test DM", html_body: "content"}
        #   }
        #    {:ok, message} = Messages.send(user, attrs)
        #   {receiver, message}

        # TODO?
        {nil, nil}

      other
      when is_nil(other) or other in [:local, :explore, :user_by_object_type, :user_activities] ->
        post =
          Bonfire.Posts.Fake.fake_post!(other_user, "public", %{
            post_content: %{name: "default post", html_body: "content"}
          })

        {post, nil}

      other ->
        raise "Missing create_test_content case for #{inspect(other)}"
    end
  end
end
