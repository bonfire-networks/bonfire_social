# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.StatusTest do
  @moduledoc """
  Tests for Mastodon-compatible Status API endpoints.

  Covers:
  - GET /api/v1/statuses/:id - Show status
  - DELETE /api/v1/statuses/:id - Delete status
  - GET /api/v1/statuses/:id/context - Thread context
  - GET /api/v1/statuses/:id/favourited_by - Who favourited
  - GET /api/v1/statuses/:id/reblogged_by - Who reblogged
  - POST /api/v1/statuses/:id/favourite - Favourite status
  - POST /api/v1/statuses/:id/unfavourite - Unfavourite status
  - POST /api/v1/statuses/:id/reblog - Reblog status
  - POST /api/v1/statuses/:id/unreblog - Unreblog status
  - POST /api/v1/statuses/:id/bookmark - Bookmark status
  - POST /api/v1/statuses/:id/unbookmark - Unbookmark status
  - POST /api/v1/statuses/:id/pin - Pin status to profile
  - POST /api/v1/statuses/:id/unpin - Unpin status from profile

  Run with: just test extensions/bonfire_social/test/rest/masto_api/status_test.exs
  """

  use Bonfire.Social.MastoApiCase, async: true

  import Bonfire.Files.Simulation

  alias Bonfire.Me.Fake
  alias Bonfire.Posts
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader
  alias Bonfire.Social.{Likes, Boosts, Bookmarks}

  @moduletag :masto_api

  describe "POST /api/v1/statuses" do
    test "creates a status with text", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses", %{"status" => "Hello from the API!"})
        |> json_response(200)

      assert is_binary(response["id"])
      assert response["content"] =~ "Hello from the API!"
    end

    test "returns 422 when status text and media are both empty", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses", %{"status" => ""})
        |> json_response(422)

      assert response["error"] =~ "Validation failed"
    end

    test "creates a status with media_ids as a list", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, media} = Files.upload(ImageUploader, user, image_file(), %{})

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses", %{
          "status" => "Post with media",
          "media_ids" => [media.id]
        })
        |> json_response(200)

      assert is_binary(response["id"])
      assert is_list(response["media_attachments"])
    end

    test "creates a status with media_ids as indexed map params", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, media} = Files.upload(ImageUploader, user, image_file(), %{})

      api_conn = masto_api_conn(conn, user: user, account: account)

      # Simulate indexed array params (media_ids[0]=id) which Phoenix parses as a map
      response =
        api_conn
        |> post("/api/v1/statuses", %{
          "status" => "Post with indexed media",
          "media_ids" => %{"0" => media.id}
        })
        |> json_response(200)

      assert is_binary(response["id"])
      assert is_list(response["media_attachments"])
    end

    test "cannot attach another user's media", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      owner = Fake.fake_user!()

      {:ok, media} = Files.upload(ImageUploader, owner, image_file(), %{})

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses", %{
          "status" => "Post with someone else's media",
          "media_ids" => [media.id]
        })
        |> json_response(404)

      assert response["error"]
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/statuses", Jason.encode!(%{"status" => "Just testing"}))
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end
  end

  describe "GET /api/v1/statuses/:id" do
    test "attributes a status to its author even when the viewer has liked it", %{conn: conn} do
      # Regression: the old activity(object_id:) GraphQL query matched the viewer's
      # like-activity and mis-attributed the status to the liker. The direct loader
      # reads the post's create-activity, so the account is always the author.
      account = Fake.fake_account!()
      viewer = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "by the author"}},
          boundary: "public"
        )

      {:ok, _} = Likes.like(viewer, post)

      response =
        conn
        |> masto_api_conn(user: viewer, account: account)
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["account"]["id"] == author.id
      refute response["account"]["id"] == viewer.id
    end

    test "a poll fetched by id carries a poll object (not a plain note)", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, question} =
        Bonfire.Poll.Fake.fake_question_with_choices(
          %{post_content: %{html_body: "tabs or spaces?"}},
          [%{name: "tabs"}, %{name: "spaces"}],
          current_user: user
        )

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/statuses/#{question.id}")
        |> json_response(200)

      assert response["id"] == question.id
      assert response["content"] =~ "tabs or spaces"

      assert poll = response["poll"],
             "a poll fetched by id should carry a poll object, not render as a note"

      titles = Enum.map(poll["options"] || [], & &1["title"])
      assert "tabs" in titles
      assert "spaces" in titles
    end

    test "marks sensitive for a content warning and exposes hashtags in tags", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{
            post_content: %{html_body: "learning #elixir today", summary: "spoiler ahead"}
          },
          boundary: "public"
        )

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      assert response["sensitive"] == true
      assert response["spoiler_text"] == "spoiler ahead"
      tag_names = Enum.map(response["tags"] || [], &String.downcase(&1["name"] || ""))
      assert Enum.any?(tag_names, &(&1 =~ "elixir")), "expected the #elixir hashtag in tags"
    end

    test "returns a status by ID", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Hello world!"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      assert response["id"] == post.id
      assert is_binary(response["content"])
      assert is_binary(response["created_at"])
      assert is_map(response["account"])
      assert response["account"]["id"] == user.id
    end

    test "returns 404 for non-existent status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      # Use a valid ULID format that doesn't exist
      nonexistent_id = Needle.ULID.generate()

      response =
        api_conn
        |> get("/api/v1/statuses/#{nonexistent_id}")
        |> json_response(404)

      assert response["error"]
    end

    test "works without authentication for public posts", %{conn: conn} do
      user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Public post"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      assert response["id"] == post.id
    end
  end

  describe "GET /api/v1/statuses/:id/source" do
    test "returns raw source text of a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "<p>Hello <strong>world</strong>!</p>"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/statuses/#{post.id}/source")
        |> json_response(200)

      assert response["id"] == post.id
      assert is_binary(response["text"])
      assert Map.has_key?(response, "spoiler_text")
    end

    test "returns spoiler_text when present", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{
            post_content: %{
              html_body: "Content behind warning",
              summary: "Content Warning"
            }
          },
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/statuses/#{post.id}/source")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["spoiler_text"] == "Content Warning"
    end

    test "returns 404 for non-existent status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      nonexistent_id = Needle.ULID.generate()

      response =
        api_conn
        |> get("/api/v1/statuses/#{nonexistent_id}/source")
        |> json_response(404)

      assert response["error"]
    end

    test "requires authentication for public source text", %{conn: conn} do
      user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Public source"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/statuses/#{post.id}/source")
        |> json_response(401)

      assert response["error"]
    end

    test "does not return another user's source text", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      owner = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: owner,
          post_attrs: %{post_content: %{html_body: "Public source"}},
          boundary: "public"
        )

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/statuses/#{post.id}/source")
        |> json_response(404)

      assert response["error"]
    end
  end

  describe "PUT /api/v1/statuses/:id" do
    test "edits own status content", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Original content"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> put("/api/v1/statuses/#{post.id}", %{"status" => "Updated content"})
        |> json_response(200)

      assert response["id"] == post.id
      assert response["content"] =~ "Updated"
    end

    test "edits status with spoiler text", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Content"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> put("/api/v1/statuses/#{post.id}", %{
          "status" => "Content",
          "spoiler_text" => "Content Warning"
        })
        |> json_response(200)

      assert response["id"] == post.id
      assert response["spoiler_text"] == "Content Warning"
    end

    test "returns 404 for non-existent status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      api_conn = masto_api_conn(conn, user: user, account: account)

      nonexistent_id = Needle.ULID.generate()

      response =
        api_conn
        |> put("/api/v1/statuses/#{nonexistent_id}", %{"status" => "Test"})
        |> json_response(404)

      assert response["error"]
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/statuses/#{post.id}", Jason.encode!(%{"status" => "Edited"}))
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end
  end

  describe "DELETE /api/v1/statuses/:id" do
    test "deletes own status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "To be deleted"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> delete("/api/v1/statuses/#{post.id}")
        |> json_response(200)

      # FIXME
      assert response["id"] == post.id

      # Verify it's deleted
      assert {:error, _} = Posts.read(post.id, skip_boundary_check: true)
    end

    # TODO: Fix Objects.delete boundary check - see https://github.com/bonfire-networks/bonfire-app/issues/XXX
    @tag :skip
    test "cannot delete another user's status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      other_user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: other_user,
          post_attrs: %{post_content: %{html_body: "Not yours"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> delete("/api/v1/statuses/#{post.id}")
        |> json_response(403)

      assert response["error"]
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> delete("/api/v1/statuses/#{post.id}")
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end
  end

  describe "GET /api/v1/statuses/:id/context" do
    test "returns ancestors and descendants", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      # Create a thread: parent -> target -> child
      {:ok, parent} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Parent post"}},
          boundary: "public"
        )

      {:ok, target} =
        Posts.publish(
          current_user: user,
          post_attrs: %{
            post_content: %{html_body: "Target post"},
            reply_to_id: parent.id
          },
          boundary: "public"
        )

      {:ok, child} =
        Posts.publish(
          current_user: user,
          post_attrs: %{
            post_content: %{html_body: "Child post"},
            reply_to_id: target.id
          },
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/statuses/#{target.id}/context")
        |> json_response(200)

      assert is_list(response["ancestors"])
      assert is_list(response["descendants"])

      ancestor_ids = Enum.map(response["ancestors"], & &1["id"])
      descendant_ids = Enum.map(response["descendants"], & &1["id"])

      assert parent.id in ancestor_ids
      assert child.id in descendant_ids
    end

    test "does not leak a reply the viewer is not allowed to see", %{conn: conn} do
      account = Fake.fake_account!()
      author = Fake.fake_user!(account)
      viewer = Fake.fake_user!()
      outsider = Fake.fake_user!()

      {:ok, root} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "public root"}},
          boundary: "public"
        )

      # a reply only the outsider (and author) can see
      {:ok, private_reply} =
        Posts.publish(
          current_user: outsider,
          post_attrs: %{post_content: %{html_body: "secret reply"}, reply_to_id: root.id},
          boundary: "mentions"
        )

      response =
        conn
        |> masto_api_conn(user: viewer)
        |> get("/api/v1/statuses/#{root.id}/context")
        |> json_response(200)

      descendant_ids = Enum.map(response["descendants"], & &1["id"])
      refute private_reply.id in descendant_ids
    end

    test "returns 404 for a non-existent root status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      conn
      |> masto_api_conn(user: user, account: account)
      |> get("/api/v1/statuses/01JABCDEF0000000000000000X/context")
      |> json_response(404)
    end

    test "returns empty lists for post without context", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Standalone post"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/statuses/#{post.id}/context")
        |> json_response(200)

      assert response["ancestors"] == []
      assert response["descendants"] == []
    end
  end

  describe "GET /api/v1/statuses/:id/favourited_by" do
    test "returns accounts who favourited the status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      liker = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Likeable post"}},
          boundary: "public"
        )

      {:ok, _} = Likes.like(liker, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/statuses/#{post.id}/favourited_by")
        |> json_response(200)

      assert is_list(response)
      account_ids = Enum.map(response, & &1["id"])
      assert liker.id in account_ids
    end

    test "returns empty list when no favourites", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Unliked post"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/statuses/#{post.id}/favourited_by")
        |> json_response(200)

      assert response == []
    end
  end

  describe "GET /api/v1/statuses/:id/reblogged_by" do
    test "returns accounts who reblogged the status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      booster = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Boostable post"}},
          boundary: "public"
        )

      {:ok, _} = Boosts.boost(booster, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/statuses/#{post.id}/reblogged_by")
        |> json_response(200)

      assert is_list(response)
      account_ids = Enum.map(response, & &1["id"])
      assert booster.id in account_ids
    end
  end

  describe "POST /api/v1/statuses/:id/favourite" do
    test "favourites a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Like me!"}},
          boundary: "public"
        )

      refute Likes.liked?(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/favourite")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["favourited"] == true
      assert Likes.liked?(user, post)
    end

    test "is idempotent - favouriting twice succeeds", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Like me!"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      # First favourite
      api_conn |> post("/api/v1/statuses/#{post.id}/favourite") |> json_response(200)

      # Second favourite - should still succeed
      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/favourite")
        |> json_response(200)

      assert response["favourited"] == true
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/statuses/#{post.id}/favourite")
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end
  end

  describe "POST /api/v1/statuses/:id/unfavourite" do
    test "unfavourites a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Unlike me!"}},
          boundary: "public"
        )

      {:ok, _} = Likes.like(user, post)
      assert Likes.liked?(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/unfavourite")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["favourited"] == false
      refute Likes.liked?(user, post)
    end

    test "is idempotent - unfavouriting when not favourited succeeds", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/unfavourite")
        |> json_response(200)

      assert response["favourited"] == false
    end
  end

  describe "POST /api/v1/statuses/:id/reblog" do
    test "reblogs a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Boost me!"}},
          boundary: "public"
        )

      refute Boosts.boosted?(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/reblog")
        |> json_response(200)

      # Response should be the reblog status wrapping the original
      assert is_map(response["reblog"]) or response["id"] == post.id
      assert Boosts.boosted?(user, post)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/statuses/#{post.id}/reblog")
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end
  end

  describe "POST /api/v1/statuses/:id/unreblog" do
    test "unreblogs a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Unboost me!"}},
          boundary: "public"
        )

      {:ok, _} = Boosts.boost(user, post)
      assert Boosts.boosted?(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/unreblog")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["reblogged"] == false
      refute Boosts.boosted?(user, post)
    end
  end

  describe "POST /api/v1/statuses/:id/bookmark" do
    test "bookmarks a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Bookmark me!"}},
          boundary: "public"
        )

      refute Bookmarks.bookmarked?(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/bookmark")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["bookmarked"] == true
      assert Bookmarks.bookmarked?(user, post)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/statuses/#{post.id}/bookmark")
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end
  end

  describe "POST /api/v1/statuses/:id/unbookmark" do
    test "unbookmarks a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Unbookmark me!"}},
          boundary: "public"
        )

      {:ok, _} = Bookmarks.bookmark(user, post)
      assert Bookmarks.bookmarked?(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/unbookmark")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["bookmarked"] == false
      refute Bookmarks.bookmarked?(user, post)
    end

    test "is idempotent - unbookmarking when not bookmarked succeeds", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/unbookmark")
        |> json_response(200)

      assert response["bookmarked"] == false
    end
  end

  describe "POST /api/v1/statuses/:id/pin" do
    test "pins a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Pin me!"}},
          boundary: "public"
        )

      refute Bonfire.Social.Pins.pinned?(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/pin")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["pinned"] == true
      assert Bonfire.Social.Pins.pinned?(user, post)
    end

    test "is idempotent - pinning twice succeeds", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Pin me!"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      # First pin
      api_conn |> post("/api/v1/statuses/#{post.id}/pin") |> json_response(200)

      # Second pin - should still succeed
      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/pin")
        |> json_response(200)

      assert response["pinned"] == true
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/statuses/#{post.id}/pin")
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end

    test "cannot pin another user's status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: "Pin someone else's post!"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/pin")
        |> json_response(422)

      assert response["error"] == "Status is not owned by you"
      refute Bonfire.Social.Pins.pinned?(user, post)
    end
  end

  describe "POST /api/v1/statuses/:id/unpin" do
    test "unpins a status", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Unpin me!"}},
          boundary: "public"
        )

      # Pin the post first (may raise federation error but pin should still be created)
      try do
        Bonfire.Social.Pins.pin(user, post)
      rescue
        _ -> :ok
      end

      assert Bonfire.Social.Pins.pinned?(user, post)

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/unpin")
        |> json_response(200)

      assert response["id"] == post.id
      assert response["pinned"] == false
      refute Bonfire.Social.Pins.pinned?(user, post)
    end

    test "is idempotent - unpinning when not pinned succeeds", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> post("/api/v1/statuses/#{post.id}/unpin")
        |> json_response(200)

      assert response["pinned"] == false
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      user = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "Test"}},
          boundary: "public"
        )

      response =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/statuses/#{post.id}/unpin")
        |> json_response(401)

      assert response["error"] == "You need to login first."
    end
  end
end
