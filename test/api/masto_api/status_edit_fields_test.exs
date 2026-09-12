defmodule Bonfire.Social.MastoApi.StatusEditFieldsTest do
  use Bonfire.Social.MastoApiCase, async: true
  use Bonfire.Common.Repo

  alias Bonfire.Me.Fake
  alias Bonfire.Posts
  alias Bonfire.Social.Objects

  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    Process.put([:bonfire, :skip_all_boundary_checks], false)
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)

    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{
          post_content: %{html_body: "Original body", summary: "Original warning"}
        },
        boundary: "public"
      )

    {:ok, conn: masto_api_conn(conn, user: user, account: account), user: user, post: post}
  end

  test "text-only editing clears the omitted warning", context do
    assert_edit(context, %{"status" => "Updated body"}, "Updated body", nil)
  end

  test "warning-only editing uses the warning as body and retains the old warning", context do
    assert_edit(context, %{"spoiler_text" => "Replacement body"}, "Replacement body", "Original warning")
  end

  for status <- [nil, "", " \t\n"] do
    test "a #{inspect(status)} body uses the warning fallback", context do
      assert_edit(
        context,
        %{"status" => unquote(status), "spoiler_text" => "Replacement body"},
        "Replacement body",
        "Original warning"
      )
    end
  end

  test "an explicit empty warning clears it when text is supplied", context do
    assert_edit(context, %{"status" => "Updated body", "spoiler_text" => ""}, "Updated body", nil)
  end

  test "supplying both fields replaces both", context do
    assert_edit(
      context,
      %{"status" => "Updated body", "spoiler_text" => "Updated warning"},
      "Updated body",
      "Updated warning"
    )
  end

  for {label, params} <- [
        {"omitted text and warning", %{}},
        {"empty text and warning", %{"status" => "", "spoiler_text" => ""}},
        {"whitespace-only text", %{"status" => " \t\n"}}
      ] do
    test "rejects #{label} without changing the saved post", context do
      {:ok, before} =
        Objects.read(context.post.id, current_user: context.user, preload: [:with_post_content])

      conn =
        put(context.conn, "/api/v1/statuses/#{context.post.id}", Jason.encode!(unquote(Macro.escape(params))))

      {:ok, after_edit} =
        Objects.read(context.post.id, current_user: context.user, preload: [:with_post_content])

      assert {conn.status, after_edit.post_content.html_body, after_edit.post_content.summary} ==
               {422, before.post_content.html_body, before.post_content.summary}

      assert json_response(conn, 422)["error"]
    end
  end

  test "an existing media attachment permits removing the text", context do
    {:ok, media} =
      Bonfire.Files.upload(
        Bonfire.Files.ImageUploader,
        context.user,
        Bonfire.Files.Simulation.image_file(),
        %{}
      )

    created =
      context.conn
      |> post("/api/v1/statuses", Jason.encode!(%{"status" => "Body with media", "media_ids" => [media.id]}))
      |> json_response(200)

    response =
      context.conn
      |> put("/api/v1/statuses/#{created["id"]}", Jason.encode!(%{"status" => "", "spoiler_text" => "", "media_ids" => [media.id]}))
      |> json_response(200)

    {:ok, saved} = Objects.read(created["id"], current_user: context.user, preload: [:with_post_content, :with_media])
    saved = repo().preload(saved, :media)
    assert is_nil(saved.post_content.html_body)
    assert Enum.map(saved.media, & &1.id) == [media.id]
    assert response["content"] == ""
    assert Enum.map(response["media_attachments"], & &1["id"]) == [media.id]
  end

  test "a supplied media ID does not bypass validation on a text-only post", context do
    conn = put(context.conn, "/api/v1/statuses/#{context.post.id}", Jason.encode!(%{"media_ids" => [Needle.ULID.generate()]}))

    assert json_response(conn, 422)["error"]
    {:ok, saved} = Objects.read(context.post.id, current_user: context.user, preload: [:with_post_content])
    assert saved.post_content.html_body == "Original body"
    assert saved.post_content.summary == "Original warning"
  end

  test "empty edits to another user's post return 404 before content validation", context do
    account = Fake.fake_account!()
    other = Fake.fake_user!(account)
    refute Bonfire.Me.Accounts.is_admin?(other)

    conn =
      build_conn()
      |> masto_api_conn(user: other, account: account)
      |> put("/api/v1/statuses/#{context.post.id}", Jason.encode!(%{}))

    assert json_response(conn, 404)["error"]
    {:ok, saved} = Objects.read(context.post.id, current_user: context.user, preload: [:with_post_content])
    assert saved.post_content.html_body == "Original body"
    assert saved.post_content.summary == "Original warning"
  end

  test "empty edits to a missing post return 404 before content validation", context do
    conn = put(context.conn, "/api/v1/statuses/#{Needle.ULID.generate()}", Jason.encode!(%{}))

    assert json_response(conn, 404)["error"]
  end

  defp assert_edit(context, params, expected_body, expected_summary) do
    response =
      context.conn
      |> put("/api/v1/statuses/#{context.post.id}", Jason.encode!(params))
      |> json_response(200)

    {:ok, saved_post} =
      Objects.read(context.post.id, current_user: context.user, preload: [:with_post_content])

    assert {saved_post.post_content.html_body, saved_post.post_content.summary} ==
             {expected_body, expected_summary}

    assert response["id"] == context.post.id
    assert response["content"] =~ expected_body
    assert response["spoiler_text"] == (expected_summary || "")
  end
end
