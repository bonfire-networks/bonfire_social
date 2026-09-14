defmodule Bonfire.Poll.API.MastoPollTest do
  use Bonfire.Social.MastoApiCase, async: false

  alias Bonfire.Me.Fake
  alias Bonfire.Poll.Questions

  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)
    reader_account = Fake.fake_account!()
    reader = Fake.fake_user!(reader_account)

    {:ok,
     author: author,
     reader: reader,
     author_conn: masto_api_conn(conn, user: author, account: account),
     reader_conn: masto_api_conn(conn, user: reader, account: reader_account)}
  end

  for multiple <- [false, true] do
    test "creates and reads a poll with multiple=#{multiple}", context do
      status =
        create_poll(context.author_conn, %{"multiple" => unquote(multiple)}) |> json_response(200)

      assert %{"id" => id, "multiple" => unquote(multiple)} = status["poll"]
      assert Enum.map(status["poll"]["options"], & &1["title"]) == ["Tea", "Coffee"]
      assert {:ok, _date, 0} = DateTime.from_iso8601(status["poll"]["expires_at"])
      read = context.reader_conn |> get("/api/v1/statuses/#{status["id"]}") |> json_response(200)
      assert read["poll"]["id"] == id
    end
  end

  test "vote totals and own choices persist in poll and status reads", context do
    question = native_poll(context.author)

    voted =
      context.reader_conn
      |> post("/api/v1/polls/#{question.id}/votes", %{"choices" => [0]})
      |> json_response(200)

    read = context.reader_conn |> get("/api/v1/polls/#{question.id}") |> json_response(200)
    status = context.reader_conn |> get("/api/v1/statuses/#{question.id}") |> json_response(200)

    for poll <- [voted, read, status["poll"]] do
      assert poll["votes_count"] == 1
      assert poll["voters_count"] == 1
      assert poll["voted"] == true
      assert poll["own_votes"] == [0]
      assert Enum.map(poll["options"], & &1["votes_count"]) == [1, 0]
    end
  end

  for choices <- [[-1], ["0junk"], [0, "0junk"], [0, 99], [], [0, 1]] do
    test "rejects invalid single-choice ballot #{inspect(choices)} without saving votes",
         context do
      question = native_poll(context.author)

      context.reader_conn
      |> post("/api/v1/polls/#{question.id}/votes", %{"choices" => unquote(choices)})
      |> response(422)

      assert Bonfire.Poll.Votes.preview_vote_state_for_question(question).voter_count == 0
    end
  end

  test "rejects a second ballot", context do
    question = native_poll(context.author)

    context.reader_conn
    |> post("/api/v1/polls/#{question.id}/votes", %{"choices" => [0]})
    |> json_response(200)

    context.reader_conn
    |> post("/api/v1/polls/#{question.id}/votes", %{"choices" => [1]})
    |> response(422)
  end

  test "rejects expired polls", context do
    question = native_poll(context.author, -60)

    context.reader_conn
    |> post("/api/v1/polls/#{question.id}/votes", %{"choices" => [0]})
    |> response(422)
  end

  test "an expired poll keeps its totals and rejects new votes", context do
    question = native_poll(context.author)

    context.reader_conn
    |> post("/api/v1/polls/#{question.id}/votes", %{"choices" => [0]})
    |> json_response(200)

    expire(question)
    expired = context.reader_conn |> get("/api/v1/polls/#{question.id}") |> json_response(200)
    assert expired["expired"]
    assert expired["votes_count"] == 1
    assert Enum.map(expired["options"], & &1["votes_count"]) == [1, 0]

    context.author_conn
    |> post("/api/v1/polls/#{question.id}/votes", %{"choices" => [1]})
    |> response(422)
  end

  for params <- [
        %{"options" => ["Only"]},
        %{"expires_in" => 0},
        %{"options" => ["", "Coffee"]},
        %{"options" => [nil, "Coffee"]}
      ] do
    test "rejects invalid poll creation #{inspect(params)}", context do
      create_poll(context.author_conn, unquote(Macro.escape(params))) |> response(422)
    end
  end

  test "multiple choice counts choices and unique voters separately", context do
    status = create_poll(context.author_conn, %{"multiple" => true}) |> json_response(200)

    poll =
      context.reader_conn
      |> post("/api/v1/polls/#{status["poll"]["id"]}/votes", %{"choices" => [0, 1]})
      |> json_response(200)

    assert poll["votes_count"] == 2
    assert poll["voters_count"] == 1
    assert poll["own_votes"] == [0, 1]
  end

  test "per-poll hidden totals are explicitly unsupported", context do
    for hide <- [true, "true", "1"] do
      error = create_poll(context.author_conn, %{"hide_totals" => hide}) |> json_response(422)
      assert error["error"] == "Validation failed: Per-poll hidden totals are not supported"
    end

    assert (create_poll(context.author_conn, %{"hide_totals" => false})
            |> json_response(200))["poll"]["id"]
  end

  test "poll-only status is accepted", context do
    status =
      context.author_conn
      |> post("/api/v1/statuses", %{
        "visibility" => "public",
        "poll" => %{"options" => ["Tea", "Coffee"], "expires_in" => 60}
      })
      |> json_response(200)

    assert status["poll"]["id"] == status["id"]
  end

  test "poll content warnings and reply relationships survive reads", context do
    parent =
      context.author_conn
      |> post("/api/v1/statuses", %{"status" => "Parent", "visibility" => "public"})
      |> json_response(200)

    status =
      context.author_conn
      |> post("/api/v1/statuses", %{
        "status" => "Poll reply",
        "spoiler_text" => "Poll warning",
        "visibility" => "public",
        "in_reply_to_id" => parent["id"],
        "poll" => %{"options" => ["Tea", "Coffee"], "expires_in" => 3600}
      })
      |> json_response(200)

    read = context.reader_conn |> get("/api/v1/statuses/#{status["id"]}") |> json_response(200)
    assert read["spoiler_text"] == "Poll warning"
    assert read["in_reply_to_id"] == parent["id"]
    assert read["poll"]["id"] == status["id"]
  end

  test "private poll is inaccessible to a non-follower", context do
    status =
      context.author_conn
      |> post("/api/v1/statuses", %{
        "status" => "Private poll",
        "visibility" => "private",
        "poll" => %{"options" => ["Tea", "Coffee"], "expires_in" => 3600}
      })
      |> json_response(200)

    owner_read = context.author_conn |> get("/api/v1/polls/#{status["id"]}") |> json_response(200)
    assert owner_read["id"] == status["id"]
    reader = context.reader_conn |> get("/api/v1/polls/#{status["id"]}")
    assert reader.status in [403, 404]
    assert context.reader_conn |> get("/api/v1/statuses/#{status["id"]}") |> response(404)
  end

  test "plain reply includes its parent in the create response and subsequent read", context do
    parent =
      context.author_conn
      |> post("/api/v1/statuses", %{"status" => "Parent", "visibility" => "public"})
      |> json_response(200)

    reply =
      context.reader_conn
      |> post("/api/v1/statuses", %{
        "status" => "Reply",
        "visibility" => "public",
        "in_reply_to_id" => parent["id"]
      })
      |> json_response(200)

    read = context.reader_conn |> get("/api/v1/statuses/#{reply["id"]}") |> json_response(200)
    assert reply["in_reply_to_id"] == parent["id"]
    assert read["in_reply_to_id"] == parent["id"]
    assert read["in_reply_to_account_id"] == context.author.id
  end

  test "like and boost counts reflect both directions through GraphQL reads", context do
    status = create_poll(context.author_conn, %{}) |> json_response(200)

    for {action, field, count_field, expected, count} <- [
          {"favourite", "favourited", "favourites_count", true, 1},
          {"unfavourite", "favourited", "favourites_count", false, 0},
          {"reblog", "reblogged", "reblogs_count", true, 1},
          {"unreblog", "reblogged", "reblogs_count", false, 0}
        ] do
      response =
        context.reader_conn
        |> post("/api/v1/statuses/#{status["id"]}/#{action}", %{})
        |> json_response(200)

      response = response["reblog"] || response
      assert response[field] == expected
      assert response[count_field] == count
      read = context.reader_conn |> get("/api/v1/statuses/#{status["id"]}") |> json_response(200)
      assert read[field] == expected
      assert read[count_field] == count
    end
  end

  test "bookmark response preserves existing likes on a poll", context do
    status = create_poll(context.author_conn, %{}) |> json_response(200)

    context.reader_conn
    |> post("/api/v1/statuses/#{status["id"]}/favourite", %{})
    |> json_response(200)

    response =
      context.reader_conn
      |> post("/api/v1/statuses/#{status["id"]}/bookmark", %{})
      |> json_response(200)

    assert response["favourited"] == true
    assert response["bookmarked"] == true
    assert response["favourites_count"] == 1
    assert response["poll"]["id"] == status["id"]
  end

  defp create_poll(conn, overrides) do
    post(conn, "/api/v1/statuses", %{
      "status" => "Poll regression",
      "visibility" => "public",
      "poll" => Map.merge(%{"options" => ["Tea", "Coffee"], "expires_in" => 3600}, overrides)
    })
  end

  defp expire(question) do
    now = DateTime.utc_now()

    question
    |> Ecto.Changeset.change(voting_dates: [DateTime.add(now, -3600), DateTime.add(now, -1)])
    |> Bonfire.Common.Repo.update!()
  end

  defp native_poll(author, seconds \\ 3600) do
    now = DateTime.utc_now()

    {:ok, question} =
      Questions.create(
        current_user: author,
        boundary: "public",
        question_attrs: %{
          post_content: %{html_body: "Native poll regression"},
          voting_format: "single",
          voting_dates: [DateTime.add(now, -120), DateTime.add(now, seconds)],
          choices: [%{name: "Tea"}, %{name: "Coffee"}]
        }
      )

    question
  end
end
