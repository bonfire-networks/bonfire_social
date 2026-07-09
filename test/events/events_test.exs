defmodule Bonfire.Social.EventsTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.Events

  doctest Bonfire.Social.Events, import: true

  # Insert an APActivity-backed AS2 Event into the user's :events feed.
  defp fake_event!(user, attrs \\ %{}) do
    start_time = attrs[:start] || DateTime.add(DateTime.utc_now(), 7, :day)

    event_object =
      %{
        "type" => "Event",
        "name" => attrs[:name] || "Test Event",
        "content" => "Come along!",
        "startTime" => DateTime.to_iso8601(start_time)
      }
      |> put_if("category", attrs[:category])

    activity_json = %{
      "type" => "Create",
      "actor" => Bonfire.Common.URIs.canonical_url(user),
      "published" => DateTime.to_iso8601(DateTime.utc_now()),
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    {:ok, activity} =
      Bonfire.Social.APActivities.ap_receive(user, activity_json, event_object, true)

    activity
  end

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  defp titles(%{edges: edges}), do: Enum.map(edges, &Events.title(e(&1, :activity, :object, :json, %{})))

  describe "feed/1" do
    test "attaches the APActivity json onto each feed edge's activity.object" do
      user = fake_user!()
      fake_event!(user, name: "Regression Event")

      assert %{edges: edges} = Events.feed(current_user: user)
      assert [edge | _] = edges

      # the context must surface the AS2 json so the UI needs no query of its own
      json = e(edge, :activity, :object, :json, nil)
      assert is_map(json)
      assert Events.title(json) == "Regression Event"
    end

    test "preloads the subject so the event host can be displayed" do
      user = fake_user!()
      fake_event!(user, name: "Hosted Event")

      assert %{edges: [edge | _]} = Events.feed(current_user: user)
      # :with_subject comes from the default preload rule — dropping it would break the host line
      assert e(edge, :activity, :subject, nil)
    end

    test "does not drop events from the feed (guards the old ':with_object_more made events vanish' regression)" do
      user = fake_user!()
      fake_event!(user, name: "Present Event")

      assert "Present Event" in titles(Events.feed(current_user: user))
    end
  end

  describe "feed/1 category filtering (FEP-8a8e)" do
    test "filters events to the requested category" do
      user = fake_user!()
      fake_event!(user, name: "Jazz Night", category: "MUSIC")
      fake_event!(user, name: "Gallery Opening", category: "ARTS")

      found = titles(Events.feed(current_user: user, categories: ["MUSIC"]))
      assert "Jazz Night" in found
      refute "Gallery Opening" in found
    end

    test "normalises category casing so a lowercase source category still matches" do
      user = fake_user!()
      fake_event!(user, name: "Lowercase Music", category: "music")

      assert "Lowercase Music" in titles(Events.feed(current_user: user, categories: ["MUSIC"]))
    end

    test "no category filter returns events of all categories" do
      user = fake_user!()
      fake_event!(user, name: "Music Event", category: "MUSIC")
      fake_event!(user, name: "Arts Event", category: "ARTS")

      found = titles(Events.feed(current_user: user))
      assert "Music Event" in found
      assert "Arts Event" in found
    end
  end
end
