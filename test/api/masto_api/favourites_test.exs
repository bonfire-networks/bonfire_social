# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.FavouritesTest do
  @moduledoc """
  Characterization tests for `GET /api/v1/favourites` (Mastodon-compatible).

  Pins the current response shape, ordering, `favourited` flag, and Link-header
  pagination so the Phase 5 conversion of this endpoint onto GraphQL
  (GRAPHQL_FIRST_MASTO_PLAN.md) can be proven behaviour-preserving.

  Docs: https://docs.joinmastodon.org/methods/favourites/

  Run: just test extensions/bonfire_social/test/api/masto_api/favourites_test.exs
  """

  use Bonfire.Social.MastoApiCase, async: true

  import Bonfire.Files.Simulation

  alias Bonfire.Me.Fake
  alias Bonfire.Posts
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader
  alias Bonfire.Social.Likes

  @moduletag :masto_api

  defp publish_post!(author, body) do
    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: body}},
        boundary: "public"
      )

    post
  end

  describe "GET /api/v1/favourites" do
    test "requires authentication", %{conn: conn} do
      conn
      |> get("/api/v1/favourites")
      |> json_response(401)
    end

    test "returns the current user's liked posts as Status objects", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      post = publish_post!(author, "a post worth liking about #elixir")
      {:ok, _} = Likes.like(user, post)

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/favourites")
        |> json_response(200)

      assert is_list(response)
      assert length(response) == 1

      [status] = response
      assert status["id"] == post.id
      assert status["content"] =~ "worth liking"
      # Every item in /favourites is, by definition, favourited by the viewer.
      assert status["favourited"] == true
      # Mastodon Status required fields are present.
      assert is_map(status["account"])
      assert is_binary(status["created_at"])
    end

    test "does not include posts the user has not liked", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      liked = publish_post!(author, "liked one")
      _unliked = publish_post!(author, "ignored one")
      {:ok, _} = Likes.like(user, liked)

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/favourites")
        |> json_response(200)

      assert [%{"id" => id}] = response
      assert id == liked.id
    end

    test "returns most-recently-liked first", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      first = publish_post!(author, "liked first")
      second = publish_post!(author, "liked second")
      {:ok, _} = Likes.like(user, first)
      {:ok, _} = Likes.like(user, second)

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/favourites")
        |> json_response(200)

      ids = Enum.map(response, & &1["id"])
      # newest like first
      assert ids == [second.id, first.id]
    end

    test "exposes hashtags in tags and public visibility (supplementary batch-loaded data)",
         %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      post = publish_post!(author, "favouriting something about #elixir today")
      {:ok, _} = Likes.like(user, post)

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/favourites")
        |> json_response(200)

      assert [status] = response
      assert status["visibility"] == "public"
      tag_names = Enum.map(status["tags"] || [], &String.downcase(&1["name"] || ""))
      assert Enum.any?(tag_names, &(&1 =~ "elixir")), "expected the #elixir hashtag in tags"
    end

    test "includes media_attachments for liked posts with media", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author_account = Fake.fake_account!()
      author = Fake.fake_user!(author_account)

      {:ok, media} = Files.upload(ImageUploader, author, image_file(), %{})

      post_id =
        conn
        |> masto_api_conn(user: author, account: author_account)
        |> post("/api/v1/statuses", %{
          "status" => "a post with an image",
          "media_ids" => [media.id]
        })
        |> json_response(200)
        |> Map.fetch!("id")

      conn
      |> masto_api_conn(user: user, account: account)
      |> post("/api/v1/statuses/#{post_id}/favourite")
      |> json_response(200)

      response =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/favourites")
        |> json_response(200)

      assert [status] = response
      assert status["id"] == post_id
      assert [attachment | _] = status["media_attachments"]
      assert is_binary(attachment["url"])
    end

    test "paginates with a Link header carrying max_id", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()

      for i <- 1..3 do
        post = publish_post!(author, "likeable #{i}")
        {:ok, _} = Likes.like(user, post)
      end

      conn = masto_api_conn(conn, user: user, account: account)
      resp = get(conn, "/api/v1/favourites", %{"limit" => "2"})
      body = json_response(resp, 200)

      assert length(body) == 2
      link = get_resp_header(resp, "link") |> List.first()
      # Mastodon clients page favourites via the Link header (max_id => older).
      assert is_binary(link)
      assert link =~ "max_id="
    end

    # it answered 20 whatever the limit: the resolver passed `first:`, the paginator reads `:limit` (masto-live-fixes, pagination plan bug 4)
    test "honours limit", %{conn: conn} do
      {conn, _posts} = liked_posts(conn, 5)

      assert conn |> get("/api/v1/favourites", %{"limit" => "3"}) |> json_response(200) |> length() == 3
    end

    test "the next link reaches older favourites without repeats", %{conn: conn} do
      {conn, posts} = liked_posts(conn, 5)

      page1 = get(conn, "/api/v1/favourites", %{"limit" => "3"})
      page2 = get(conn, "/api/v1/favourites", next_params(page1))

      ids = ids(page1) ++ ids(page2)
      assert length(ids(page1)) == 3
      assert length(ids(page2)) == 2
      assert Enum.sort(ids) == posts |> Enum.map(& &1.id) |> Enum.sort()
      assert next_params(page2) == nil, "the last page has no next link"
    end

    # the prev link fell back to a post id, so a pull-to-refresh from page 1 asked for likes newer than that post was written and got the newest favourites again (fresh review, finding 4)
    test "the prev link from the first page brings nothing new", %{conn: conn} do
      {conn, _posts} = liked_posts(conn, 5)

      page1 = get(conn, "/api/v1/favourites", %{"limit" => "3"})

      case prev_params(page1) do
        nil -> :ok
        prev -> assert ids(get(conn, "/api/v1/favourites", prev)) == []
      end
    end

    # Mastodon pages favourites by when they were liked; the next link carried the post's id, so page 2 asked for likes older than that post
    test "pages by when the post was liked, not when it was written", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      author = Fake.fake_user!()
      [oldest, middle, newest] = for i <- 1..3, do: publish_post!(author, "written #{i}")

      # the oldest post is liked last
      for post <- [newest, middle, oldest], do: {:ok, _} = Likes.like(user, post)

      conn = masto_api_conn(conn, user: user, account: account)
      page1 = get(conn, "/api/v1/favourites", %{"limit" => "2"})
      assert ids(page1) == [oldest.id, middle.id]

      page2 = get(conn, "/api/v1/favourites", next_params(page1))
      assert ids(page2) == [newest.id]
    end
  end

  # a user who liked `n` posts, oldest liked first; the conn is theirs
  defp liked_posts(conn, n) do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    author = Fake.fake_user!()

    posts =
      for i <- 1..n do
        post = publish_post!(author, "likeable #{i}")
        {:ok, _} = Likes.like(user, post)
        post
      end

    {masto_api_conn(conn, user: user, account: account), posts}
  end

  defp ids(resp), do: resp |> json_response(200) |> Enum.map(& &1["id"])

  defp prev_params(resp) do
    with [link | _] <- get_resp_header(resp, "link"),
         [_, query] <- Regex.run(~r/<[^>]*\?([^>]*)>; rel="prev"/, link) do
      URI.decode_query(query)
    else
      _ -> nil
    end
  end

  # the query of the response's `rel="next"` Link, as a client follows it; nil without one
  defp next_params(resp) do
    with [link | _] <- get_resp_header(resp, "link"),
         [_, query] <- Regex.run(~r/<[^>]*\?([^>]*)>; rel="next"/, link) do
      URI.decode_query(query)
    else
      _ -> nil
    end
  end
end
