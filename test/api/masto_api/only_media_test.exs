# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.OnlyMediaTest do
  @moduledoc """
  `only_media=true` on Mastodon timelines: "Filter out statuses without attachments."
  https://docs.joinmastodon.org/methods/accounts/#statuses

  Run with: just test extensions/bonfire_social/test/api/masto_api/only_media_test.exs
  """

  use Bonfire.Social.MastoApiCase, async: true

  alias Bonfire.Me.Fake
  alias Bonfire.Posts
  alias Bonfire.Social.Fake, as: SocialFake

  @moduletag :masto_api

  setup %{conn: conn} do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)

    media_post = SocialFake.post_with_media(user, :images, "only_media one")

    two_media_post =
      Bonfire.Posts.Fake.fake_post!(user, "public", %{
        post_content: %{name: "Post with two images", html_body: "two images"},
        uploaded_media: [
          SocialFake.upload_media(:images, user, "first of two"),
          SocialFake.upload_media(:images, user, "second of two")
        ]
      })

    {:ok, plain_post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "a post without media"}},
        boundary: "public"
      )

    # link previews are media too, but clients get them as `card`; the second has a non-link type and is a preview by its `text/html`
    link_post = publish_with(user, "a post with only a link preview", [link_media(user, "website")])

    html_typed_link_post =
      publish_with(user, "a link preview with an unusual type", [link_media(user, "video.other")])

    link_and_image_post =
      publish_with(user, "a link preview and an image", [
        link_media(user, "website"),
        SocialFake.upload_media(:images, user, "beside a link")
      ])

    {:ok,
     api_conn: masto_api_conn(conn, user: user, account: account),
     user: user,
     media_post: media_post,
     two_media_post: two_media_post,
     plain_post: plain_post,
     link_post: link_post,
     html_typed_link_post: html_typed_link_post,
     link_and_image_post: link_and_image_post}
  end

  defp link_media(user, media_type) do
    url = "https://example.org/#{Faker.UUID.v4()}"

    {:ok, media} =
      Bonfire.Files.Media.insert(user, url, %{media_type: media_type, size: 0}, %{
        url: url,
        metadata: %{"content_type" => "text/html", "facebook" => %{"title" => "Preview title"}}
      })

    media
  end

  defp publish_with(user, body, media) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: body}, uploaded_media: media},
        boundary: "public"
      )

    post
  end

  describe "GET /api/v1/accounts/:id/statuses?only_media=true" do
    test "lists only statuses with attachments", %{
      api_conn: api_conn,
      user: user,
      media_post: media_post,
      two_media_post: two_media_post,
      link_and_image_post: link_and_image_post
    } do
      response =
        api_conn
        |> get("/api/v1/accounts/#{user.id}/statuses?only_media=true")
        |> json_response(200)

      assert response |> Enum.map(& &1["id"]) |> Enum.sort() ==
               Enum.sort([media_post.id, two_media_post.id, link_and_image_post.id])

      assert Enum.all?(response, &(&1["media_attachments"] != []))
    end

    test "a status with two attachments is listed once", %{
      api_conn: api_conn,
      user: user,
      two_media_post: two_media_post
    } do
      response =
        api_conn
        |> get("/api/v1/accounts/#{user.id}/statuses?only_media=true")
        |> json_response(200)

      assert [listed] = Enum.filter(response, &(&1["id"] == two_media_post.id))
      assert length(listed["media_attachments"]) == 2
    end

    test "a status whose only media is a link preview is left out", %{
      api_conn: api_conn,
      user: user,
      link_post: link_post,
      html_typed_link_post: html_typed_link_post
    } do
      ids =
        api_conn
        |> get("/api/v1/accounts/#{user.id}/statuses?only_media=true")
        |> json_response(200)
        |> Enum.map(& &1["id"])

      refute link_post.id in ids
      refute html_typed_link_post.id in ids
    end

    test "a status with a link preview and an image is listed with the image and the card", %{
      api_conn: api_conn,
      user: user,
      link_and_image_post: link_and_image_post
    } do
      response =
        api_conn
        |> get("/api/v1/accounts/#{user.id}/statuses?only_media=true")
        |> json_response(200)

      assert [listed] = Enum.filter(response, &(&1["id"] == link_and_image_post.id))
      assert [%{"type" => "image"}] = listed["media_attachments"]
      assert listed["card"]
    end
  end

  describe "GET /api/v1/accounts/:id/statuses without only_media" do
    test "lists statuses with and without attachments", %{
      api_conn: api_conn,
      user: user,
      media_post: media_post,
      two_media_post: two_media_post,
      plain_post: plain_post,
      link_post: link_post
    } do
      ids =
        api_conn
        |> get("/api/v1/accounts/#{user.id}/statuses")
        |> json_response(200)
        |> Enum.map(& &1["id"])

      assert media_post.id in ids
      assert two_media_post.id in ids
      assert plain_post.id in ids
      assert link_post.id in ids
    end
  end
end
