# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.MastoApi.PublishPrivacyTest do
  @moduledoc """
  POST /api/v1/statuses keeps a requested schedule and never widens a post's audience by default (B49 in `team-docs/plans/mastodon-api.md`, companion `masto-publish-privacy.md`).

  Run with: just test extensions/bonfire_social/test/api/masto_api/publish_privacy_test.exs
  """

  use Bonfire.Social.MastoApiCase, async: true

  import Ecto.Query
  import Bonfire.Files.Simulation
  alias Bonfire.Common.Settings
  alias Bonfire.Me.Fake

  @moduletag :masto_api

  setup %{conn: conn} do
    Process.put([:bonfire, :feed_live_update_many_preload_mode], :inline)
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    {:ok, conn: conn, account: account, user: user}
  end

  defp api_conn(conn, user, account), do: masto_api_conn(conn, user: user, account: account)

  defp with_default_preset(user, preset) do
    Bonfire.Common.Utils.current_user(
      Settings.put([:bonfire_boundaries, :default_boundary_preset], preset, current_user: user)
    )
  end

  defp created_count(user) do
    Bonfire.Common.Repo.aggregate(
      from(c in Bonfire.Data.Social.Created, where: c.creator_id == ^user.id),
      :count
    )
  end

  defp in_minutes(minutes) do
    DateTime.utc_now() |> DateTime.add(minutes * 60, :second) |> DateTime.to_iso8601()
  end

  describe "scheduled_at" do
    test "a day ahead answers a ScheduledStatus and the post is not public yet", %{
      conn: conn,
      account: account,
      user: user
    } do
      at = in_minutes(24 * 60)

      response =
        api_conn(conn, user, account)
        |> post("/api/v1/statuses", %{"status" => "Later, please", "scheduled_at" => at})
        |> json_response(200)

      assert is_binary(response["id"])
      assert {:ok, scheduled, _} = DateTime.from_iso8601(response["scheduled_at"])
      {:ok, wanted, _} = DateTime.from_iso8601(at)
      assert abs(DateTime.diff(scheduled, wanted, :second)) <= 1
      assert response["params"]["text"] == "Later, please"
      assert is_list(response["media_attachments"])
      refute Map.has_key?(response, "content")

      timeline = build_conn() |> masto_api_conn([]) |> get("/api/v1/timelines/public") |> json_response(200)
      refute Enum.any?(timeline, &(&1["id"] == response["id"]))
    end

    test "without visibility, the ScheduledStatus names the default it was posted with", %{
      conn: conn,
      account: account,
      user: user
    } do
      user = with_default_preset(user, "local")

      response =
        api_conn(conn, user, account)
        |> post("/api/v1/statuses", %{"status" => "Later, locally", "scheduled_at" => in_minutes(24 * 60)})
        |> json_response(200)

      assert response["params"]["visibility"] == "direct"
    end

    test "without a UTC offset is read as UTC, as Posts.publish does", %{
      conn: conn,
      account: account,
      user: user
    } do
      naive =
        DateTime.utc_now()
        |> DateTime.add(24 * 60 * 60, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)
        |> NaiveDateTime.to_iso8601()

      response =
        api_conn(conn, user, account)
        |> post("/api/v1/statuses", %{"status" => "Later, no offset", "scheduled_at" => naive})
        |> json_response(200)

      assert response["scheduled_at"] =~ String.slice(naive, 0, 16)
    end

    test "a value that is not a date string answers 422 and posts nothing", %{
      conn: conn,
      account: account,
      user: user
    } do
      before = created_count(user)

      api_conn(conn, user, account)
      |> post("/api/v1/statuses", %{"status" => "Epoch", "scheduled_at" => 1_900_000_000})
      |> json_response(422)

      assert created_count(user) == before
    end

    test "media_ids sent as an indexed map come back as a list of ids", %{
      conn: conn,
      account: account,
      user: user
    } do
      {:ok, media} = Bonfire.Files.upload(Bonfire.Files.ImageUploader, user, image_file(), %{})

      response =
        api_conn(conn, user, account)
        |> post("/api/v1/statuses", %{
          "status" => "Later, with a picture",
          "scheduled_at" => in_minutes(24 * 60),
          "media_ids" => %{"0" => media.id}
        })
        |> json_response(200)

      assert response["params"]["media_ids"] == [media.id]
    end

    test "under 5 minutes ahead answers 422 and posts nothing", %{
      conn: conn,
      account: account,
      user: user
    } do
      before = created_count(user)

      api_conn(conn, user, account)
      |> post("/api/v1/statuses", %{"status" => "Too soon", "scheduled_at" => in_minutes(1)})
      |> json_response(422)

      assert created_count(user) == before
    end

    test "in the past answers 422 and posts nothing", %{conn: conn, account: account, user: user} do
      before = created_count(user)

      api_conn(conn, user, account)
      |> post("/api/v1/statuses", %{"status" => "Yesterday", "scheduled_at" => in_minutes(-60)})
      |> json_response(422)

      assert created_count(user) == before
    end
  end

  describe "visibility" do
    test "omitted uses the user's default preset, not public", %{
      conn: conn,
      account: account,
      user: user
    } do
      user = with_default_preset(user, "local")

      response =
        api_conn(conn, user, account)
        |> post("/api/v1/statuses", %{"status" => "Only for the instance"})
        |> json_response(200)

      assert response["visibility"] == "unlisted"
    end

    test "an unknown value answers 422 and posts nothing", %{
      conn: conn,
      account: account,
      user: user
    } do
      before = created_count(user)

      api_conn(conn, user, account)
      |> post("/api/v1/statuses", %{"status" => "Who sees this?", "visibility" => "secret"})
      |> json_response(422)

      assert created_count(user) == before
    end

    test "a group context that cannot be loaded answers 422 even with a visibility", %{
      conn: conn,
      account: account,
      user: user
    } do
      before = created_count(user)

      api_conn(conn, user, account)
      |> post("/api/v1/statuses", %{
        "status" => "To a group that is not there, publicly",
        "context_id" => Needle.ULID.generate(),
        "visibility" => "public"
      })
      |> json_response(422)

      assert created_count(user) == before
    end

    test "a group context that cannot be loaded answers 422 and posts nothing", %{
      conn: conn,
      account: account,
      user: user
    } do
      before = created_count(user)

      api_conn(conn, user, account)
      |> post("/api/v1/statuses", %{
        "status" => "To a group that is not there",
        "context_id" => Needle.ULID.generate()
      })
      |> json_response(422)

      assert created_count(user) == before
    end
  end

  describe "the default visibility apps read" do
    test "a local default reads as direct in preferences and source.privacy", %{
      conn: conn,
      account: account,
      user: user
    } do
      user = with_default_preset(user, "local")
      api_conn = api_conn(conn, user, account)

      prefs = api_conn |> get("/api/v1/preferences") |> json_response(200)
      # Mastodon's `unlisted` reaches remote people, `local` does not (review R1)
      assert prefs["posting:default:visibility"] == "direct"

      me = api_conn |> get("/api/v1/accounts/verify_credentials") |> json_response(200)
      assert me["source"]["privacy"] == "direct"
    end

    test "a custom preset default reads as direct", %{conn: conn, account: account, user: user} do
      user = with_default_preset(user, Needle.ULID.generate())
      api_conn = api_conn(conn, user, account)

      prefs = api_conn |> get("/api/v1/preferences") |> json_response(200)
      assert prefs["posting:default:visibility"] == "direct"

      me = api_conn |> get("/api/v1/accounts/verify_credentials") |> json_response(200)
      assert me["source"]["privacy"] == "direct"
    end
  end
end
