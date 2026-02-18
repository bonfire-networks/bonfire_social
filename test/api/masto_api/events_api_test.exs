# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Social.EventsApiTest do
  # TODO: move this to an events extension, and use custom schema and context for events

  @moduledoc """
  Tests for Mastodon-compatible Events API endpoints.

  Covers:
  - GET /api/v1-bonfire/timelines/events - Event feed with optional filters
  - GET /api/v1-bonfire/accounts/:id/events - List a user's events
  - GET /api/v1-bonfire/events/:id - Get event details

  All endpoints return Mastodon Status objects with Event attachments.
  """

  use Bonfire.Social.MastoApiCase, async: System.get_env("TEST_UI_ASYNC") != "no"

  import Bonfire.Me.Fake
  import Untangle

  alias Bonfire.Me.Fake
  alias Bonfire.Social.Activities

  @moduletag :masto_api

  setup do
    user = Fake.fake_user!()
    other_user = Fake.fake_user!()
    {:ok, user: user, other_user: other_user}
  end

  # Helper to create a fake event activity
  defp fake_event!(user, attrs \\ %{}) do
    defaults = %{
      name: "Test Event",
      content: "An awesome test event",
      # summary: "",
      start_time: DateTime.add(DateTime.utc_now(), 30, :day),
      end_time: DateTime.add(DateTime.utc_now(), 31, :day),
      display_end_time: true,
      location: nil
    }

    event_attrs = Map.merge(defaults, attrs)

    event_object =
      %{
        "type" => "Event",
        "name" => event_attrs.name,
        "content" => event_attrs.content,
        # "summary" => event_attrs.summary,
        "startTime" => DateTime.to_iso8601(event_attrs.start_time),
        "endTime" => DateTime.to_iso8601(event_attrs.end_time),
        "displayEndTime" => to_string(event_attrs.display_end_time)
      }
      |> maybe_add_location(event_attrs.location)

    # Create activity with event object
    activity_json = %{
      "type" => "Create",
      "actor" => Bonfire.Common.URIs.canonical_url(user),
      "published" => DateTime.to_iso8601(DateTime.utc_now()),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    # Use ap_receive to properly process JSON (including geolocation, etc.)
    {:ok, activity} =
      Bonfire.Social.APActivities.ap_receive(user, activity_json, event_object, true)

    activity
  end

  defp maybe_add_location(event_object, nil), do: event_object

  defp maybe_add_location(event_object, geolocation) do
    Map.put(event_object, "location", %{
      "type" => "Place",
      "id" => Bonfire.Common.URIs.canonical_url(geolocation),
      "name" => geolocation.name,
      "address" => Map.get(geolocation, :mappable_address, nil),
      "latitude" => geolocation.lat,
      "longitude" => geolocation.long
    })
  end

  describe "Event response format" do
    test "matches Mastodon Status + Event specification", %{user: user} do
      event =
        fake_event!(user, %{
          name: "Format Test Event",
          content: "Testing response format"
        })

      conn = masto_api_conn(user: user)

      response =
        conn
        |> get("/api/v1-bonfire/events/#{event.id}")
        |> json_response(200)
        |> debug("Event format test response")

      # Mastodon Status fields
      assert is_binary(response["id"])
      # event name/summary
      assert is_binary(response["spoiler_text"])
      # event description
      assert is_binary(response["content"])

      assert is_binary(response["uri"])
      assert is_binary(response["created_at"])
      assert is_map(response["account"])

      # Event attachment
      assert is_map(response["event"])
      event_data = response["event"]

      assert is_binary(event_data["id"])
      assert is_binary(event_data["start_time"])
      assert is_binary(event_data["end_time"])
      assert is_boolean(event_data["display_end_time"])
      assert event_data["status"] in ["scheduled", "active", "completed", "cancelled"]
      assert event_data["join_mode"] in ["free", "restricted", "invite"]
    end
  end

  describe "GET timelines/events" do
    test "returns event feed as Mastodon statuses with event attachments", %{
      user: user,
      other_user: other_user
    } do
      # Create some events
      event1 = fake_event!(user, %{name: "Music Festival", content: "Great music event"})
      event2 = fake_event!(other_user, %{name: "Tech Conference", content: "Learn about tech"})

      conn = masto_api_conn(user: user)

      response =
        conn
        |> get("/api/v1-bonfire/timelines/events")
        |> json_response(200)

      debug(response, "Events timeline response")

      assert is_list(response)
      assert length(response) >= 2

      # Check that responses follow Mastodon Status structure with Event attachment
      status = List.first(response)
      assert_status_with_event_fields(status)
    end

    test "supports limit parameter", %{user: user} do
      # Create multiple events
      for i <- 1..5 do
        fake_event!(user, %{name: "Event #{i}"})
      end

      conn = masto_api_conn(user: user)

      response =
        conn
        |> get("/api/v1-bonfire/timelines/events?limit=3")
        |> json_response(200)

      assert length(response) <= 3
    end

    test "filters events by location when location_id provided", %{user: user} do
      # This test will need location implementation
      # For now, just test the endpoint accepts the parameter
      conn = masto_api_conn(user: user)

      response =
        conn
        |> get("/api/v1-bonfire/timelines/events?location_id=test_location_id")
        |> json_response(200)

      assert is_list(response)
    end
  end

  describe "GET accounts/:id/events" do
    test "returns events created by a specific user", %{user: user, other_user: other_user} do
      # Create events for both users
      user_event = fake_event!(user, %{name: "User's Event"})
      _other_event = fake_event!(other_user, %{name: "Other User's Event"})

      conn = masto_api_conn(user: user)

      response =
        conn
        |> get("/api/v1-bonfire/accounts/#{user.id}/events")
        |> json_response(200)

      debug(response, "User events response")

      assert is_list(response)

      # All events should be from the specified user
      for status <- response do
        assert status["account"]["id"] == user.id
        assert_status_with_event_fields(status)
      end
    end

    test "returns empty list for user with no events", %{user: user} do
      new_user = Fake.fake_user!()
      conn = masto_api_conn(user: user)

      response =
        conn
        |> get("/api/v1-bonfire/accounts/#{new_user.id}/events")
        |> json_response(200)

      assert response == []
    end
  end

  describe "GET events/:id" do
    test "returns event details as Mastodon status with event attachment", %{user: user} do
      event =
        fake_event!(user, %{
          name: "Detailed Event",
          content: "Event with full details",
          summary: "A summary",
          start_time: ~U[2026-05-22 21:14:00Z],
          end_time: ~U[2026-06-22 22:14:00Z],
          display_end_time: true
        })

      conn = masto_api_conn(user: user)

      response =
        conn
        |> get("/api/v1-bonfire/events/#{event.id}")
        |> json_response(200)

      debug(response, "Event details response")

      assert_status_with_event_fields(response)
      assert response["id"] == event.id

      # Check event-specific fields
      event_data = response["event"]
      assert event_data["id"] == event.id
      assert event_data["start_time"] == "2026-05-22T21:14:00Z"
      assert event_data["end_time"] == "2026-06-22T22:14:00Z"
      assert event_data["display_end_time"] == true
    end

    # @tag :fixme
    # test "returns 404 for non-existent event", %{user: user} do
    #   conn = masto_api_conn(user: user)

    #   conn
    #   |> get("/api/v1-bonfire/events/#{Needle.UID.generate()}")
    #   |> json_response(404)
    # end

    test "includes location when event has location_id", %{user: user} do
      # Create a geolocation first
      location = Bonfire.Geolocate.Simulate.fake_geolocation!(user)

      # Create event with that location
      event = fake_event!(user, %{name: "Event with Location", location: location})

      conn = masto_api_conn(user: user)

      response =
        conn
        |> get("/api/v1-bonfire/events/#{event.id}")
        |> json_response(200)

      # Location should be included
      # assert is_binary(response["event"]["location_id"])
      assert is_map(response["event"]["location"])
      assert response["event"]["location"]["name"] == location.name

      response =
        conn
        |> get("/api/v1-bonfire/timelines/events")
        |> json_response(200)

      result = List.first(response)

      assert is_map(result["event"]["location"])
      assert result["event"]["location"]["name"] == location.name
    end
  end

  # Helper function to assert common status + event fields
  defp assert_status_with_event_fields(status) do
    # Mastodon Status fields
    assert is_binary(status["id"])
    assert is_map(status["account"])
    assert is_binary(status["content"])
    assert is_binary(status["uri"])
    assert is_binary(status["created_at"])

    # Event attachment must be present
    assert is_map(status["event"])

    event = status["event"]
    assert is_binary(event["id"])
    assert is_binary(event["start_time"])

    # Optional but expected fields
    if event["end_time"], do: assert(is_binary(event["end_time"]))
    if event["location_id"], do: assert(is_binary(event["location_id"]))
  end
end
