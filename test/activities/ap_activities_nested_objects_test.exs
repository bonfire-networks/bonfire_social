defmodule Bonfire.Social.APActivitiesNestedObjectsTest do
  @moduledoc """
  The objects nested in the fields of a federated object (an event's `location`, a service's `generator`) are stored as objects of their own when it is ingested (`ActivityPub.Federator.NestedObjects`), which leaves their AP ids in its fields. `APActivities` keeps a reference to each in the `json` it stores, and `preload_nested_objects/2` turns the references back into the loaded objects when the activity is shown.

  These hold the Bonfire half of that, as the cards and the APIs see it: which reference is kept for what, and what the preload gives back. The library half is tested in `ActivityPub.Federator.NestedObjectsTest`.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Tesla.Mock

  alias ActivityPub.Federator.NestedObjects
  alias Bonfire.Social.APActivities

  # a Place is stored as a Geolocate object, which needs PostGIS (it is disabled on YugabyteDB)
  if not Bonfire.Common.Extend.extension_enabled?(:bonfire_geolocate),
    do: @moduletag(skip: "bonfire_geolocate is disabled")

  setup do
    n = System.unique_integer([:positive])
    host = "nested-#{n}.example"

    place = fn label ->
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://#{host}/places/#{label}",
        "type" => "Place",
        "name" => "Place #{label}"
      }
    end

    app = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://#{host}/actors/app",
      "type" => "Application",
      "preferredUsername" => "app-#{n}",
      "inbox" => "https://#{host}/actors/app/inbox"
    }

    served = [place.("a"), place.("b"), app]

    mock_global(fn
      %{method: :get, url: url} ->
        case Enum.find(served, &(&1["id"] == url)) do
          nil -> %Tesla.Env{status: 404, body: ""}
          document -> json(document)
        end
    end)

    %{host: host, place: place, app: app}
  end

  defp event(host, fields) do
    Map.merge(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://#{host}/events/#{System.unique_integer([:positive])}",
        "type" => "Event",
        "name" => "an event",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      },
      fields
    )
  end

  # what `APActivities` stores of an event: the library ingests it, leaving the ids of its nested objects, and the ids become references
  defp stored_json(host, fields) do
    host
    |> event(fields)
    |> NestedObjects.ingest()
    |> APActivities.reference_nested_objects()
  end

  # `preload_nested_objects/2` takes the stored activities, which hold the json
  defp preloaded(json), do: hd(APActivities.preload_nested_objects([%{json: json}])).json

  describe "an object nested in a field" do
    test "is kept as a reference that names it and says how to load it", %{
      host: host,
      place: place
    } do
      json = stored_json(host, %{"location" => place.("a")})

      assert %{"id" => id, "type" => type} = reference = json["location"]
      assert id == place.("a")["id"]
      assert "Place" in List.wrap(type)

      assert is_binary(reference["pointer_id"] || reference["ap_id"]),
             "a reference with nothing to load it by is not one"
    end

    test "that is an actor is kept as a reference to the actor", %{host: host, app: app} do
      json = stored_json(host, %{"generator" => app})

      assert %{"id" => id} = reference = json["generator"]
      assert id == app["id"]
      assert is_binary(reference["ap_actor_id"] || reference["pointer_id"])
    end

    test "in a list is kept as a list of references", %{host: host, place: place} do
      json = stored_json(host, %{"location" => [place.("a"), place.("b")]})

      assert [%{"id" => id_a}, %{"id" => id_b}] = json["location"]
      assert {id_a, id_b} == {place.("a")["id"], place.("b")["id"]}
    end

    test "with no id stays embedded, and an id nothing stored stays an id", %{host: host} do
      anonymous = %{"type" => "Place", "name" => "somewhere"}

      json =
        event(host, %{
          "location" => anonymous,
          "instrument" => "https://#{host}/never-stored"
        })

      assert APActivities.reference_nested_objects(json) == json
    end

    test "in a field that names somebody else is left alone", %{host: host, place: place} do
      NestedObjects.ingest(event(host, %{"location" => place.("a")}))
      stored_id = place.("a")["id"]

      json = event(host, %{"inReplyTo" => stored_id, "url" => stored_id})

      assert APActivities.reference_nested_objects(json) == json
    end
  end

  describe "preload_nested_objects/2" do
    test "loads a nested object from its reference", %{host: host, place: place} do
      json = stored_json(host, %{"location" => place.("a")})

      assert loaded = preloaded(json)["location"]["nested_object"]

      # the Bonfire object when the Place has one, else the ActivityPub object
      assert (Map.get(loaded, :name) || (Map.get(loaded, :data) || %{})["name"]) == "Place a"
    end

    test "gives the reference back with the object added", %{host: host, place: place} do
      json = stored_json(host, %{"location" => place.("a")})

      result = preloaded(json)["location"]

      assert result["id"] == json["location"]["id"]
      assert result["pointer_id"] == json["location"]["pointer_id"]
      assert result["type"] == json["location"]["type"]
      assert result["nested_object"]
    end

    test "loads every object of a list", %{host: host, place: place} do
      json = stored_json(host, %{"location" => [place.("a"), place.("b")]})

      assert [%{"nested_object" => first}, %{"nested_object" => second}] =
               preloaded(json)["location"]

      assert first && second
    end

    test "loads a nested actor", %{host: host, app: app} do
      json = stored_json(host, %{"generator" => app})

      assert preloaded(json)["generator"]["nested_object"]
    end

    test "leaves URLs and maps that are no reference as they are", %{host: host} do
      json =
        event(host, %{
          "url" => "https://#{host}/events/1",
          "icon" => %{"type" => "Image", "url" => "https://#{host}/i.png"},
          "tag" => [%{"type" => "Hashtag", "name" => "#salad"}]
        })

      loaded = preloaded(json)

      assert loaded["url"] == json["url"]
      assert loaded["icon"] == json["icon"]
      assert loaded["tag"] == json["tag"]
    end
  end
end
