defmodule Bonfire.Social.Events.API.GraphQLMasto.EventsAdapter do
  @moduledoc """
  Mastodon-compatible Events API adapter using GraphQL.

  Transforms Bonfire event activities (APActivity with Event in json)
  into Mastodon Status format with Event attachments.

  Implements:
  - GET /api/v1-bonfire/timelines/events
  - GET /api/v1-bonfire/accounts/:id/events
  - GET /api/v1-bonfire/events/:id
  """

  use AbsintheClient,
    schema: Bonfire.API.GraphQL.Schema,
    action: [mode: :internal]

  use Bonfire.Common.E
  import Untangle
  import Bonfire.API.MastoCompat.Helpers

  alias Bonfire.API.MastoCompat.{
    Schemas,
    Mappers,
    InteractionHandler,
    Helpers,
    PaginationHelpers,
    Fragments
  }

  @user_profile Fragments.user_profile()

  @event_fields "
  id
  name
  content
  summary
  startTime
  endTime
  displayEndTime
  timezone
  joinMode
  json
  uri: canonicalUrl
  creator_id
  creator {
    ... on User {
          #{@user_profile}
        }
  }
  location {
    id
    uri: canonicalUrl
    name
    note
    address: mappableAddress
    lat
    long
    geom
  }
  "

  @doc """
  List events for Mastodon API events timeline.
  """
  def list_events(params, conn) do
    Bonfire.Social.Web.MastoTimelineController.feed_by_name(conn, "events", params)
  end

  def list_user_events(user_id, params, conn) do
    Bonfire.Social.Web.MastoTimelineController.feed_by_name(
      conn,
      "events",
      params |> Map.put("creators", [user_id])
    )
  end

  def show_event(id, conn) do
    case get_event(id, conn) do
      nil -> Bonfire.API.GraphQL.RestAdapter.error_fn({:error, :not_found}, conn)
      status -> Phoenix.Controller.json(conn, status)
    end
  end

  @doc """
  Get a single event by ID.
  """
  @graphql """
  query($id: ID!) {
    event(id: $id) {
      #{@event_fields}
    }
  }
  """
  def get_event(id, conn) do
    case graphql(conn, :get_event, %{"id" => id}) do
      %{data: %{event: event}} when is_map(event) ->
        event_to_masto_status(event)

      other ->
        error(other, "Unexpected response from event")
        nil
    end
  end

  # Private functions

  @doc """
  Transform a GraphQL Event object into Mastodon Status + Event format.
  The event parameter is already an Event object from GraphQL with extracted fields.

  Reuses the status building logic from Bonfire.API.MastoCompat.Mappers.Status
  and adds the event attachment.
  """
  def event_to_masto_status(event) when is_map(event) do
    build_status_from_event_data(event, %{}, [])
  end

  def event_to_masto_status(_), do: nil

  defp build_event_attachment(event_obj, event_data) do
    start_time = event_data["start_time"]
    end_time = event_data["end_time"]

    %{
      "id" => event_data["id"],
      "name" => event_obj["name"],
      "start_time" => start_time,
      "end_time" => end_time,
      "display_end_time" => event_data["display_end_time"],
      "timezone" => event_data["timezone"],
      "location" => event_data["location"],
      "virtual_locations" => event_obj["virtualLocations"] || [],
      "organizers" => build_organizers(event_obj),
      "status" => determine_event_status(start_time, end_time),
      "join_mode" => event_data["join_mode"] || "free"
    }
    |> debug("Built event attachment")
  end

  defp get_event_object_from_json(%{"object" => %{"type" => "Event"} = event}), do: event
  defp get_event_object_from_json(%{"type" => "Event"} = event), do: event
  defp get_event_object_from_json(_), do: %{}

  # Extract location from the nested_object injected by preload_nested_objects
  defp extract_preloaded_location(%{"location" => %{"nested_object" => %{} = geo}}) do
    # Virtual fields lat/long may not be populated from DB load; extract from geom
    {lat, long} =
      case geo do
        %{geom: %Geo.Point{coordinates: {lat, long}}} -> {lat, long}
        %{lat: lat, long: long} when not is_nil(lat) -> {lat, long}
        _ -> {nil, nil}
      end

    %{
      "id" => Map.get(geo, :id),
      "name" => Map.get(geo, :name),
      "address" => Map.get(geo, :mappable_address),
      "lat" => lat,
      "long" => long,
      "note" => Map.get(geo, :note)
    }
  end

  # Fallback: extract location from raw JSON (when pointer wasn't resolved)
  defp extract_preloaded_location(%{"location" => %{"name" => name} = loc})
       when is_binary(name) do
    %{
      "id" => loc["pointer_id"] || loc["id"],
      "name" => name,
      "address" => loc["address"] || loc["mappableAddress"],
      "lat" => loc["latitude"] || loc["lat"],
      "long" => loc["longitude"] || loc["long"] || loc["lng"],
      "note" => loc["note"]
    }
  end

  defp extract_preloaded_location(_), do: nil

  defp build_organizers(%{"organizer" => organizer}) when is_list(organizer) do
    Enum.map(organizer, &format_organizer/1)
  end

  defp build_organizers(%{"organizer" => organizer}) when is_map(organizer) do
    [format_organizer(organizer)]
  end

  defp build_organizers(_), do: []

  defp format_organizer(org) when is_map(org) do
    %{
      "id" => org["id"],
      "name" => org["name"],
      "url" => org["url"]
    }
  end

  defp format_organizer(uri) when is_binary(uri), do: %{"url" => uri}

  defp determine_event_status(start_time, end_time) do
    now = DateTime.utc_now()

    cond do
      is_nil(start_time) -> "scheduled"
      datetime_before?(now, start_time) -> "scheduled"
      !is_nil(end_time) && datetime_after?(now, end_time) -> "completed"
      true -> "active"
    end
  end

  defp datetime_before?(dt1, dt2_string) do
    case DateTime.from_iso8601(dt2_string) do
      {:ok, dt2, _} -> DateTime.compare(dt1, dt2) == :lt
      _ -> true
    end
  end

  defp datetime_after?(dt1, dt2_string) do
    case DateTime.from_iso8601(dt2_string) do
      {:ok, dt2, _} -> DateTime.compare(dt1, dt2) == :gt
      _ -> false
    end
  end

  defp parse_boolean("true"), do: true
  defp parse_boolean(true), do: true
  defp parse_boolean(_), do: false

  def build_event_status(activity, opts) do
    object = get_field(activity, :object)

    # Preload nested objects (resolves pointer_id references like location)
    object = Bonfire.Social.APActivities.preload_nested_objects(object, opts)

    json = get_field(object, :json)
    id = get_field(activity, :object_id) || get_field(activity, :id)

    event_obj = get_event_object_from_json(json)

    # Build context directly from event_obj and activity
    context = %{
      id: id,
      object_id: id,
      created_at: get_field(activity, :created_at),
      uri: get_field(activity, :uri),
      object_post_content: %{
        html_body: event_obj["content"] || "",
        name: event_obj["name"],
        summary: event_obj["summary"]
      },
      subject: get_fields(activity, [:account, :subject]),
      media: get_field(activity, :media) || [],
      tags: get_field(activity, :tags) || [],
      like_count: get_field(activity, :like_count) || 0,
      boost_count: get_field(activity, :boost_count) || 0,
      replies_count: get_field(activity, :replies_count) || 0,
      liked_by_me: get_field(activity, :liked_by_me) || false,
      boosted_by_me: get_field(activity, :boosted_by_me) || false,
      bookmarked_by_me: get_field(activity, :bookmarked_by_me) || false
    }

    base_status = Bonfire.API.MastoCompat.Mappers.Status.build_regular_status(context, opts)

    location = extract_preloaded_location(event_obj)

    event_attachment =
      build_event_attachment(event_obj, %{
        "id" => id,
        "start_time" => event_obj["startTime"],
        "end_time" => event_obj["endTime"],
        "display_end_time" => parse_boolean(event_obj["displayEndTime"]),
        "timezone" => event_obj["timezone"],
        "join_mode" => event_obj["joinMode"] || "free",
        "location" => location
      })

    base_status
    |> Map.put("name", event_obj["name"])
    |> Map.put("event", event_attachment)
    |> then(&Helpers.validate_and_return(&1, Schemas.Status))
  end

  defp build_status_from_event_data(event, activity_meta, opts) do
    id = get_field(event, "id")
    json = get_field(event, "json")

    # Extract created_at from activity meta or ActivityStreams json or ULID
    created_at =
      activity_meta["created_at"] ||
        case get_in(json, ["published"]) do
          nil ->
            nil

          dt_string ->
            case DateTime.from_iso8601(dt_string) do
              {:ok, dt, _} -> dt
              _ -> nil
            end
        end ||
        with {:ok, ts} <- Needle.ULID.timestamp(id) do
          DateTime.from_unix!(ts, :millisecond)
        else
          _ -> nil
        end

    context = %{
      id: id,
      object_id: id,
      created_at: created_at,
      uri: get_field(event, "uri"),
      object_post_content: %{
        html_body: get_field(event, "content") || "",
        name: get_field(event, "name"),
        summary: get_field(event, "summary")
      },
      subject: get_field(event, "creator") || get_field(event, "creator_id"),
      media: activity_meta["media"] || [],
      tags: activity_meta["tags"] || [],
      like_count: activity_meta["like_count"] || 0,
      boost_count: activity_meta["boost_count"] || 0,
      replies_count: activity_meta["replies_count"] || 0,
      liked_by_me: activity_meta["liked_by_me"] || false,
      boosted_by_me: activity_meta["boosted_by_me"] || false,
      bookmarked_by_me: activity_meta["bookmarked_by_me"] || false
    }

    base_status = Bonfire.API.MastoCompat.Mappers.Status.build_regular_status(context, opts)

    event_obj = get_event_object_from_json(json)

    event_attachment =
      build_event_attachment(event_obj, %{
        "id" => id,
        "start_time" => get_field(event, "startTime"),
        "end_time" => get_field(event, "endTime"),
        "display_end_time" => get_field(event, "displayEndTime"),
        "timezone" => get_field(event, "timezone"),
        "join_mode" => get_field(event, "joinMode"),
        "location" => get_field(event, :location)
      })

    base_status
    |> Map.put("name", get_field(event, "name"))
    |> Map.put("event", event_attachment)
    |> then(&Helpers.validate_and_return(&1, Schemas.Status))
  end
end
