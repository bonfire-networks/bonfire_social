# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Application.compile_env(:bonfire_messages, :modularity) != :disabled do
  defmodule Bonfire.Social.MastoApi.ConversationShapeTest do
    @moduledoc """
    Characterization of the Mastodon `conversation` JSON, written before the conversation mapper
    reads GraphQL (team-docs/plans/masto-pure-mappers.md, "Conversation mapper", unit 0), as a
    record of what `/api/v1/conversations` answered then, quirks included. An assertion changes
    only by a decision, named at the assertion.

    Run with: just test extensions/bonfire_social/test/api/masto_api/conversation_shape_test.exs
    """

    use Bonfire.Social.MastoApiCase, async: false

    alias Bonfire.Me.Fake
    alias Bonfire.Messages

    @moduletag :masto_api

    setup %{conn: conn} do
      account = Fake.fake_account!()
      viewer = Fake.fake_user!(account)
      other = Fake.fake_user!()

      {:ok,
       viewer: viewer,
       other: other,
       api_conn: masto_api_conn(conn, user: viewer, account: account)}
    end

    describe "GET /api/v1/conversations" do
      test "one incoming message: the whole conversation", %{
        api_conn: api_conn,
        viewer: viewer,
        other: other
      } do
        message = send_dm(other, viewer, "<p>hello there</p>")

        assert [conversation] = list(api_conn)

        assert conversation == %{
                 "id" => message.id,
                 "unread" => true,
                 # the sender first, then the viewer
                 "accounts" => [account(api_conn, other), account(api_conn, viewer)],
                 "last_status" => %{
                   "id" => message.id,
                   "account" => account(api_conn, other),
                   "content" => "<p>hello there</p>",
                   "text" => "hello there",
                   "created_at" => created_at(message),
                   "visibility" => "direct",
                   # built by `from_post`, not the canonical URI
                   "uri" => "/post/#{message.id}",
                   "url" => "/post/#{message.id}",
                   # the viewer, the only one tagged, is left out
                   "mentions" => [],
                   "tags" => [],
                   "emojis" => [],
                   "media_attachments" => [],
                   "filtered" => [],
                   "sensitive" => false,
                   "spoiler_text" => "",
                   "favourited" => false,
                   "reblogged" => false,
                   "bookmarked" => false,
                   "muted" => false,
                   "pinned" => false,
                   "favourites_count" => 0,
                   "reblogs_count" => 0,
                   "replies_count" => 0
                   # nil keys (`in_reply_to_id`, `card`, `poll`, `language`...) are dropped
                 }
               }
      end

      test "a group message the viewer liked, mentioning a recipient", %{
        api_conn: api_conn,
        viewer: viewer,
        other: other
      } do
        third = Fake.fake_user!()

        message =
          send_dm(other, [viewer, third], "<p>hi @#{third.character.username} and all</p>")

        {:ok, _} = Bonfire.Social.Likes.like(viewer, message.id)

        assert [conversation] = list(api_conn)
        status = conversation["last_status"]

        assert status["favourited"] == true
        # today's quirk (review A1): the count stays 0 on a message the viewer liked
        assert status["favourites_count"] == 0

        assert status["mentions"] == [
                 %{
                   "id" => third.id,
                   "username" => third.character.username,
                   "acct" => third.character.username,
                   "url" => Bonfire.Common.URIs.base_url() <> "/@" <> third.character.username
                 }
               ]
      end

      test "a thread with a reply: the conversation id is the last message's, not the thread's",
           %{api_conn: api_conn, viewer: viewer} do
        sender = Fake.fake_user!()
        first = send_dm(sender, viewer, "<p>first</p>")
        reply = send_dm(viewer, sender, "<p>second</p>", %{reply_to_id: first.id})

        assert [conversation] = list(api_conn)

        # today's quirk (review B3)
        assert conversation["id"] == reply.id
        assert conversation["last_status"]["id"] == reply.id
        # today's quirk (review A2): `replied.reply_to` is not loaded
        refute Map.has_key?(conversation["last_status"], "in_reply_to_id")
        assert conversation["unread"] == true
        # the last message's sender first
        assert ids(conversation["accounts"]) == [viewer.id, sender.id]
      end

      test "a thread with three posters lists them all, the last sender first", %{
        api_conn: api_conn,
        viewer: viewer,
        other: other
      } do
        third = Fake.fake_user!()
        first = send_dm(other, [viewer, third], "<p>one</p>")
        _ = send_dm(third, [viewer, other], "<p>two</p>", %{reply_to_id: first.id})
        last = send_dm(viewer, [other, third], "<p>three</p>", %{reply_to_id: first.id})

        assert [conversation] = list(api_conn)
        assert conversation["last_status"]["id"] == last.id
        assert ids(conversation["accounts"]) == [viewer.id, other.id, third.id]

        for account <- conversation["accounts"],
            do: assert(account == account(api_conn, %{id: account["id"]}))
      end

      test "a participant who ghosted the viewer is left out", %{
        api_conn: api_conn,
        viewer: viewer,
        other: other
      } do
        third = Fake.fake_user!()
        _ = send_dm(other, [viewer, third], "<p>with a ghost</p>")
        {:ok, _} = Bonfire.Boundaries.Blocks.block(viewer, :ghost, current_user: third)

        assert [conversation] = list(api_conn)
        assert ids(conversation["accounts"]) == [other.id, viewer.id]
      end

      test "an attachment is not shown", %{api_conn: api_conn, viewer: viewer, other: other} do
        {:ok, upload} =
          Bonfire.Files.upload(
            Bonfire.Files.ImageUploader,
            other,
            Bonfire.Files.Simulation.icon_file()
          )

        {:ok, message} =
          Messages.send([current_user: other, uploaded_media: [upload]], %{
            to_circles: [viewer.id],
            post_content: %{html_body: "<p>pic</p>"}
          })

        assert [conversation] = list(api_conn)
        assert conversation["last_status"]["id"] == message.id
        # today's quirk (review A3): no media is loaded for a conversation
        assert conversation["last_status"]["media_attachments"] == []
        refute Map.has_key?(conversation["last_status"], "card")
      end

      test "pages follow `limit` and both Link headers", %{api_conn: api_conn, viewer: viewer} do
        [oldest, middle, newest] =
          for i <- 1..3, do: send_dm(Fake.fake_user!(), viewer, "<p>thread #{i}</p>")

        first = get(api_conn, "/api/v1/conversations", %{"limit" => "2"})
        assert page_ids(first) == [newest.id, middle.id]

        assert links(first) == [
                 "/api/v1/conversations?limit=2&max_id=#{middle.id}",
                 "/api/v1/conversations?limit=2&min_id=#{newest.id}"
               ]

        [next, prev] = links(first)
        second = get(api_conn, next)
        assert page_ids(second) == [oldest.id]

        # the last page still links to a next one
        assert links(second) == [
                 "/api/v1/conversations?limit=2&max_id=#{oldest.id}",
                 "/api/v1/conversations?limit=2&min_id=#{oldest.id}"
               ]

        assert page_ids(get(api_conn, prev)) == []
        assert api_conn |> get(List.last(links(second))) |> page_ids() == [newest.id, middle.id]
      end
    end

    describe "POST /api/v1/conversations/:id/read" do
      # today's behaviour (review E1): every DM thread answers 404, before any read-back
      test "answers 404 for a single message", %{
        api_conn: api_conn,
        viewer: viewer,
        other: other
      } do
        message = send_dm(other, viewer, "<p>alone</p>")

        assert api_conn
               |> post("/api/v1/conversations/#{message.id}/read")
               |> json_response(404) == %{"error" => "Not found"}
      end

      test "answers 404 for a thread with a reply, by its thread id or the listed id", %{
        api_conn: api_conn,
        viewer: viewer
      } do
        sender = Fake.fake_user!()
        first = send_dm(sender, viewer, "<p>first</p>")
        reply = send_dm(viewer, sender, "<p>second</p>", %{reply_to_id: first.id})

        for id <- [first.id, reply.id] do
          assert api_conn |> post("/api/v1/conversations/#{id}/read") |> json_response(404) ==
                   %{"error" => "Not found"}
        end

        assert [%{"unread" => true}] = list(api_conn)
      end
    end

    defp send_dm(from, to, html, extra \\ %{}) do
      {:ok, message} =
        Messages.send(
          from,
          Map.merge(
            %{
              to_circles: to |> List.wrap() |> Enum.map(& &1.id),
              post_content: %{html_body: html}
            },
            extra
          )
        )

      message
    end

    defp list(api_conn), do: api_conn |> get("/api/v1/conversations") |> json_response(200)

    # an account as `GET /api/v1/accounts/:id` answers it to the viewer
    defp account(api_conn, %{id: id}),
      do: api_conn |> get("/api/v1/accounts/#{id}") |> json_response(200)

    defp ids(accounts), do: Enum.map(accounts, & &1["id"])

    defp page_ids(conn), do: conn |> json_response(200) |> Enum.map(& &1["last_status"]["id"])

    defp created_at(%{id: id}) do
      {:ok, ms} = Needle.ULID.timestamp(id)
      ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    end

    defp links(conn) do
      conn
      |> get_resp_header("link")
      |> Enum.join(",")
      |> then(&Regex.scan(~r/<([^>]+)>; rel="(?:next|prev)"/, &1))
      |> Enum.map(fn [_, url] ->
        uri = URI.parse(url)
        uri.path <> "?" <> (uri.query || "")
      end)
    end
  end
end
