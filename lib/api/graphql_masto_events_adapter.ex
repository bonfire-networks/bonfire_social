defmodule Bonfire.Social.Events.API.GraphQLMasto.EventsAdapter do
  @moduledoc """
  Mastodon-compatible Events API adapter using GraphQL.

  Transforms Bonfire event activities (APActivity with Event in json)
  into Mastodon Status format with Event attachments.

  Implements:
  - GET /api/bonfire-v1/timelines/events
  - GET /api/bonfire-v1/accounts/:id/events
  - GET /api/bonfire-v1/events/:id
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
  canonicalUri
  creator_id
  creator {
    ... on User {
          #{@user_profile}
        }
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
        err(other, "Unexpected response from event")
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

  defp build_event_attachment(
         id,
         start_time,
         end_time,
         display_end_time,
         timezone,
         join_mode,
         json
       ) do
    event_obj = get_event_object_from_json(json)

    %{
      "id" => id,
      "start_time" => start_time,
      "end_time" => end_time,
      "display_end_time" => display_end_time,
      "timezone" => timezone,

      # Location (if available)
      "location_id" => extract_location_id(event_obj),
      "location" => build_location(event_obj),

      # Virtual locations
      "virtual_locations" => event_obj["virtualLocations"] || [],

      # Organizers (if available)
      "organizers" => build_organizers(event_obj),

      # Status and join mode
      "status" => determine_event_status(start_time, end_time),
      "join_mode" => join_mode || "free"
    }
  end

  defp get_event_object_from_json(%{"object" => %{"type" => "Event"} = event}), do: event
  defp get_event_object_from_json(%{"type" => "Event"} = event), do: event
  defp get_event_object_from_json(_), do: %{}

  defp extract_location_id(event_obj) do
    event_obj["location"]["id"] || event_obj["location_id"] || event_obj["location"]
  end

  defp build_location(%{"location" => location}) when is_map(location) do
    %{
      "id" => location["id"],
      "name" => location["name"],
      "address" => location["address"] || location["mappableAddress"],
      "uri" => location["url"] || location["uri"]
    }
  end

  defp build_location(_), do: nil

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

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(string) when is_binary(string), do: string

  defp format_datetime(_), do: nil

  def build_event_status(activity, opts) do
    object = get_field(activity, :object)
    json = get_field(object, :json)
    id = get_field(activity, :object_id) || get_field(activity, :id)

    event_obj = get_event_object_from_json(json)

    # Build minimal event data map with just event-specific fields
    event_data = %{
      "id" => id,
      "name" => get_in(event_obj, ["name"]),
      "content" => get_in(event_obj, ["content"]),
      "summary" => get_in(event_obj, ["summary"]),
      "startTime" => get_in(event_obj, ["startTime"]),
      "endTime" => get_in(event_obj, ["endTime"]),
      "displayEndTime" => parse_boolean(get_in(event_obj, ["displayEndTime"])),
      "timezone" => get_in(event_obj, ["timezone"]),
      "joinMode" => get_in(event_obj, ["joinMode"]) || "free",
      "json" => json,
      "canonicalUri" => get_field(activity, :uri),
      "creator" => get_fields(activity, [:account, :subject])
    }

    # Build context by merging event-specific data with activity metadata
    # The activity already has all the metadata we need
    context = %{
      id: id,
      object_id: id,
      created_at: get_field(activity, :created_at),
      uri: get_field(activity, :uri),
      object_post_content: %{
        html_body: get_field(event_data, "content") || "",
        name: get_field(event_data, "name"),
        summary: get_field(event_data, "summary")
      },
      subject: get_fields(activity, [:account, :subject]),
      # Reuse existing activity fields instead of re-extracting
      media: get_field(activity, :media) || [],
      tags: get_field(activity, :tags) || [],
      like_count: get_field(activity, :like_count) || 0,
      boost_count: get_field(activity, :boost_count) || 0,
      replies_count: get_field(activity, :replies_count) || 0,
      liked_by_me: get_field(activity, :liked_by_me) || false,
      boosted_by_me: get_field(activity, :boosted_by_me) || false,
      bookmarked_by_me: get_field(activity, :bookmarked_by_me) || false
    }

    # Build base status
    base_status = Bonfire.API.MastoCompat.Mappers.Status.build_regular_status(context, opts)

    # Build and attach event data
    event_attachment =
      build_event_attachment(
        id,
        get_field(event_data, "startTime"),
        get_field(event_data, "endTime"),
        get_field(event_data, "displayEndTime"),
        get_field(event_data, "timezone"),
        get_field(event_data, "joinMode"),
        json
      )

    base_status
    |> Map.put("event", event_attachment)
    |> then(&Helpers.validate_and_return(&1, Schemas.Status))
  end

  # Single source of truth for building status from event data
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

    # Build context map for status mapper
    context = %{
      id: id,
      object_id: id,
      created_at: created_at,
      uri: get_field(event, "canonicalUri"),
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

    # Build base status using existing status mapper
    base_status = Bonfire.API.MastoCompat.Mappers.Status.build_regular_status(context, opts)

    # Build and attach event data
    event_attachment =
      build_event_attachment(
        id,
        get_field(event, "startTime"),
        get_field(event, "endTime"),
        get_field(event, "displayEndTime"),
        get_field(event, "timezone"),
        get_field(event, "joinMode"),
        json
      )

    base_status
    |> Map.put("event", event_attachment)
  end
end
