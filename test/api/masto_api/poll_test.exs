# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.PollTest do
  @moduledoc """
  Tests that a Bonfire poll (Question) renders as a Mastodon Status carrying a `poll`
  object — rather than collapsing into a plain note (the prior behaviour, since `:poll`
  was disabled in the GraphQL `:any_context` union and the mapper never built the poll).
  """
  use Bonfire.Social.MastoApiCase, async: true

  alias Bonfire.Me.Fake

  @moduletag :masto_api

  describe "polls in timelines" do
    test "a poll renders as a status with a poll object (not a plain note)", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, question} =
        Bonfire.Poll.Fake.fake_question_with_choices(
          %{post_content: %{html_body: "What is your favourite colour?"}},
          [%{name: "Red"}, %{name: "Blue"}],
          current_user: user
        )

      statuses =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/accounts/#{user.id}/statuses")
        |> json_response(200)

      poll_status = Enum.find(statuses, &(&1["id"] == question.id))

      assert poll_status, "the poll activity should appear in the user's statuses"

      assert poll = poll_status["poll"],
             "the status should carry a poll object instead of rendering as a plain note"

      assert poll["id"] == question.id

      # the poll's question text should populate the status body (not render as a blank note)
      assert poll_status["content"] =~ "favourite colour"

      titles = Enum.map(poll["options"] || [], & &1["title"])
      assert "Red" in titles
      assert "Blue" in titles
    end

    test "a cast vote is reflected in the poll option counts", %{conn: conn} do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      {:ok, question} =
        Bonfire.Poll.Fake.fake_question_with_choices(
          %{post_content: %{html_body: "Tea or coffee?"}},
          [%{name: "Tea"}, %{name: "Coffee"}],
          current_user: user
        )

      [first_choice | _] = question.choices

      assert {:ok, _} =
               Bonfire.Poll.Votes.vote(user, question, [%{choice_id: first_choice.id, weight: 1}])

      statuses =
        conn
        |> masto_api_conn(user: user, account: account)
        |> get("/api/v1/accounts/#{user.id}/statuses")
        |> json_response(200)

      poll = Enum.find(statuses, &(&1["id"] == question.id))["poll"]
      assert poll["votes_count"] == 1
      assert Enum.any?(poll["options"], &(&1["votes_count"] == 1))
    end
  end
end
