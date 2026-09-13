defmodule Bonfire.Poll.API.CompletionTest do
  use Bonfire.Social.MastoApiCase, async: false
  import Ecto.Query

  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    account = Bonfire.Me.Fake.fake_account!()
    author = Bonfire.Me.Fake.fake_user!(account)
    voter_account = Bonfire.Me.Fake.fake_account!()
    voter = Bonfire.Me.Fake.fake_user!(voter_account)
    {:ok, author: author, voter: voter,
      conn: masto_api_conn(conn, user: author, account: account),
      voter_conn: masto_api_conn(conn, user: voter, account: voter_account)}
  end

  test "completion is scheduled, never early, and delivered once to author and voter", context do
    poll = context.conn |> post("/api/v1/statuses", %{"status" => Faker.Lorem.sentence(),
      "visibility" => "public", "poll" => %{"options" => ["Tea", "Coffee"], "expires_in" => 3600}}) |> json_response(200)
    context.voter_conn |> post("/api/v1/polls/#{poll["id"]}/votes", %{"choices" => [0]}) |> json_response(200)
    jobs = Oban.Job |> where([j], j.worker == "Bonfire.Poll.CompletionWorker") |> Bonfire.Common.Repo.all()
    job = Enum.find(jobs, &(&1.args["question_id"] == poll["id"]))
    assert job
    {:ok, deadline, _} = DateTime.from_iso8601(poll["poll"]["expires_at"])
    assert DateTime.compare(job.scheduled_at, deadline) == :eq
    assert {:snooze, seconds} = Bonfire.Poll.CompletionWorker.perform(job)
    assert seconds > 0
    for conn <- [context.conn, context.voter_conn], do: assert(completions(conn, poll["id"]) == [])

    {:ok, question} = Bonfire.Poll.Questions.read(poll["id"], current_user: context.author)
    question |> Ecto.Changeset.change(voting_dates: [DateTime.add(DateTime.utc_now(), -3600), DateTime.add(DateTime.utc_now(), -1)]) |> Bonfire.Common.Repo.update!()
    assert :ok = Bonfire.Poll.CompletionWorker.perform(job)
    assert :ok = Bonfire.Poll.CompletionWorker.perform(job)
    for conn <- [context.conn, context.voter_conn] do
      [notification] = completions(conn, poll["id"])
      assert notification["status"]["poll"]["expired"]
      detail = conn |> get("/api/v1/notifications/#{notification["id"]}") |> json_response(200)
      assert detail["type"] == "poll"
      timeline = conn |> get("/api/v1/timelines/home") |> json_response(200)
      entry = Enum.find(timeline, &(&1["id"] == poll["id"]))
      assert entry
      canonical = conn |> get("/api/v1/statuses/#{poll["id"]}") |> json_response(200)
      assert Map.take(entry, ["created_at", "content", "account"]) == Map.take(canonical, ["created_at", "content", "account"])
    end
  end

  test "completion without votes still reaches the author", context do
    {:ok, question} = Bonfire.Poll.Questions.create(current_user: context.author, boundary: "public",
      question_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, voting_format: "single",
        voting_dates: [DateTime.add(DateTime.utc_now(), -60), DateTime.add(DateTime.utc_now(), -1)],
        choices: [%{name: "Tea"}, %{name: "Coffee"}]})
    assert :ok = Bonfire.Poll.Completions.complete(question.id, context.author)
    assert [_] = completions(context.conn, question.id)
    assert [] = completions(context.voter_conn, question.id)
  end

  test "a voter who loses private-poll access is not notified at completion", context do
    assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(context.voter, context.author)
    poll = context.conn |> post("/api/v1/statuses", %{"status" => Faker.Lorem.sentence(),
      "visibility" => "private", "poll" => %{"options" => ["Tea", "Coffee"], "expires_in" => 3600}}) |> json_response(200)
    context.voter_conn |> post("/api/v1/polls/#{poll["id"]}/votes", %{"choices" => [0]}) |> json_response(200)
    Bonfire.Social.Graph.Follows.unfollow(context.voter, context.author)
    context.voter_conn |> get("/api/v1/statuses/#{poll["id"]}") |> response(404)
    {:ok, question} = Bonfire.Poll.Questions.read(poll["id"], current_user: context.author)
    question |> Ecto.Changeset.change(voting_dates: [DateTime.add(DateTime.utc_now(), -60), DateTime.add(DateTime.utc_now(), -1)]) |> Bonfire.Common.Repo.update!()
    assert :ok = Bonfire.Poll.Completions.complete(question.id, context.author)
    assert [_] = completions(context.conn, question.id)
    assert [] = completions(context.voter_conn, question.id)
    {:ok, completed} = Bonfire.Poll.Questions.read(question.id, current_user: context.author)
    notifications_feed = Bonfire.Social.Feeds.feed_id(:notifications, context.voter)
    refute Bonfire.Common.Repo.exists?(from p in Bonfire.Data.Social.FeedPublish,
      where: p.id == ^completed.completion_activity_id and p.feed_id == ^notifications_feed)
  end

  defp completions(conn, id) do
    conn |> get("/api/v1/notifications?types[]=poll") |> json_response(200)
    |> Enum.filter(&(get_in(&1, ["status", "id"]) == id))
  end
end
