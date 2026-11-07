defmodule Bonfire.Social.DeleteTest do
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

  test "post deletion works" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "summary",
          html_body: "epic html"
        }
      })

    {:ok, _} =
      Objects.delete(post, current_user: user)
      |> debug()

    assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)
  end

  test "when post is deleted, also delete attached media" do
    user = Fake.fake_user!()
    assert {:ok, upload} = Files.upload(ImageUploader, user, icon_file())

    if path = Files.local_path(ImageUploader, upload) do
      assert File.exists?(path)
    end || assert Bonfire.Common.Media.image_url(upload)

    post =
      fake_post!(
        user,
        "public",
        %{
          post_content: %{
            summary: "summary",
            name: "name",
            html_body: "epic html"
          }
        },
        uploaded_media: [upload]
      )
      |> repo().maybe_preload([:media])

    assert path == e(post, :media, []) |> List.first() |> Files.local_path(ImageUploader, ...)
    assert File.exists?(path)

    assert {:ok, _} = Bonfire.Me.DeleteWorker.delete_structs_now(post)
    refute File.exists?(path)
  end

  test "deletion of a user deletes its posts" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          summary: "summary",
          html_body: "epic html"
        }
      })

    # Oban.Testing.with_testing_mode(:inline, fn ->
    #   {:ok, _} =
    #     Users.enqueue_delete(user)
    #     |> debug("del?")
    # end)
    assert {:ok, _} = Bonfire.Me.DeleteWorker.delete_structs_now(user)

    refute Users.get_current(user.id)
    assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)

    # TODO: check if we also delete likes/boosts/etc
  end

  test "deletion of a user deletes its posts (and media attached to those)" do
    user = Fake.fake_user!()

    assert {:ok, upload} = Files.upload(ImageUploader, user, icon_file())

    if path = Files.local_path(ImageUploader, upload) do
      assert File.exists?(path)
    end || assert Bonfire.Common.Media.image_url(upload)

    post =
      fake_post!(
        user,
        "public",
        %{
          post_content: %{
            summary: "summary",
            name: "name",
            html_body: "epic html"
          }
        },
        uploaded_media: [upload]
      )
      |> repo().maybe_preload([:media])

    # assert path == e(post, :media, []) |> List.first() |> Files.local_path(ImageUploader, ...)
    # assert File.exists?(path)

    assert {:ok, _} = Bonfire.Me.DeleteWorker.delete_structs_now(user)

    refute Users.get_current(user.id)
    assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)
    refute path && File.exists?(path)

    # TODO: check if we also delete likes/boosts/etc
  end

  # A link is stored once as a Media and shared by everything that links it (`Media.maybe_fetch_and_save/3` reuses the existing row by URL), so deleting one post must only detach it from that post.
  describe "a link shared with other objects" do
    setup do
      user = Fake.fake_user!()
      url = "https://example.com/shared/#{Needle.UID.generate()}"
      assert {:ok, media} = Files.save_url_as_media(user, url, %{media_type: "link"})
      {:ok, user: user, url: url, media: media}
    end

    test "deleting one post that links it keeps it on another post", %{
      user: user,
      url: url,
      media: media
    } do
      deleted = fake_post!(user, "public", %{post_content: %{html_body: "see #{url}"}})
      kept = fake_post!(user, "public", %{post_content: %{html_body: "also #{url}"}})

      # the positive first: both posts hold the one shared row
      for post <- [deleted, kept] do
        assert media.id in Enum.map(repo().preload(post, :media).media, & &1.id),
               "the link wasn't attached as the shared Media"
      end

      assert {:ok, _} = Objects.delete(deleted, current_user: user)

      assert {:ok, _} = Bonfire.Files.Media.one(id: media.id),
             "deleting one post deleted a link that another post still has"

      assert media.id in Enum.map(repo().preload(kept, :media, force: true).media, & &1.id)
    end

    test "deleting a post that links it keeps it on a moderator's label", %{
      user: user,
      url: url,
      media: media
    } do
      moderator = Fake.fake_user!()
      {:ok, moderator} = Users.make_admin(moderator)
      labelled = fake_post!(user, "public", %{post_content: %{html_body: "a claim"}})
      deleted = fake_post!(user, "public", %{post_content: %{html_body: "see #{url}"}})
      {label_id, label_name, _} = List.first(Bonfire.Label.ContentLabels.built_ins())
      {:ok, _} = Bonfire.Label.Labels.get_or_create(label_id, label_name)

      assert {:ok, _} =
               Bonfire.Label.LiveHandler.maybe_tag(moderator, labelled, label_id, %{
                 "html_body" => "context",
                 "links" => [url]
               })

      assert media.id in Enum.map(repo().preload(deleted, :media).media, & &1.id)

      assert {:ok, _} = Objects.delete(deleted, current_user: user)

      assert {:ok, _} = Bonfire.Files.Media.one(id: media.id),
             "deleting a post deleted a link that a label still has"
    end
  end
end
