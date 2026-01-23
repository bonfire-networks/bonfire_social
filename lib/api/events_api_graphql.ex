# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Social.Events.API.GraphQL do
    @moduledoc "Events API fields/endpoints for GraphQL"

    use Absinthe.Schema.Notation
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo
    import Untangle

    alias Bonfire.API.GraphQL
    alias Bonfire.Social.FeedLoader
    alias Bonfire.Social.Activities
    alias Bonfire.Social.Objects
    # Event object type - extracts Event data from APActivity json field
    object :event do
      field :id, non_null(:id) do
        resolve(fn ap_activity, _, _ ->
          {:ok, ap_activity.id}
        end)
      end

      field :name, :string do
        resolve(fn ap_activity, _, _ ->
          {:ok, get_in(get_event_object(ap_activity), ["name"])}
        end)
      end

      field :content, :string do
        resolve(fn ap_activity, _, _ ->
          {:ok, get_in(get_event_object(ap_activity), ["content"])}
        end)
      end

      field :summary, :string do
        resolve(fn ap_activity, _, _ ->
          {:ok, get_in(get_event_object(ap_activity), ["summary"])}
        end)
      end

      field :start_time, :string do
        resolve(fn ap_activity, _, _ ->
          {:ok, get_in(get_event_object(ap_activity), ["startTime"])}
        end)
      end

      field :end_time, :string do
        resolve(fn ap_activity, _, _ ->
          {:ok, get_in(get_event_object(ap_activity), ["endTime"])}
        end)
      end

      field :display_end_time, :boolean do
        resolve(fn ap_activity, _, _ ->
          value = get_in(get_event_object(ap_activity), ["displayEndTime"])
          {:ok, parse_boolean(value)}
        end)
      end

      field :timezone, :string do
        resolve(fn ap_activity, _, _ ->
          {:ok, get_in(get_event_object(ap_activity), ["timezone"])}
        end)
      end

      field :join_mode, :string do
        resolve(fn ap_activity, _, _ ->
          {:ok, get_in(get_event_object(ap_activity), ["joinMode"]) || "free"}
        end)
      end

      # The underlying APActivity for full data access
      field :json, :json do
        resolve(fn ap_activity, _, _ ->
          {:ok, ap_activity.json}
        end)
      end

      field :canonical_url, :string do
        resolve(fn ap_activity, _, _ ->
          {:ok, Bonfire.Common.URIs.canonical_url(e(ap_activity, :object, nil) || ap_activity)}
        end)
      end

      field :creator_id, :id do
        resolve(fn ap_activity, _, _ ->
          {:ok,
           e(ap_activity, :created, :creator_id, nil) ||
             e(ap_activity, :activity, :subject_id, nil)}
        end)
      end

      field :creator, :any_character do
        resolve(fn ap_activity, _, _ ->
          {:ok,
           e(ap_activity, :created, :creator, nil) || e(ap_activity, :activity, :subject, nil)}
        end)
      end

      field :location, :spatial_thing do
        resolve(fn ap_activity, _, _ ->
          # Location is stored in json.object.location with nested_object after preload_nested_objects
          location =
            get_in(get_event_object(ap_activity) |> flood("json_find_location"), ["location"])

          case location do
            # preload_nested_objects injects the loaded struct under "nested_object"
            %{"nested_object" => %{__struct__: _} = geo} ->
              {:ok, geo}

            %{__struct__: _} = geo ->
              # Already a loaded struct (shouldn't happen but handle it)
              {:ok, geo}

            _ ->
              {:ok, nil}
          end
        end)
      end
    end

    # Queries
    object :events_queries do
      @desc "Get a single event by ID"
      field :event, :event do
        arg(:id, non_null(:id))
        resolve(&get_event/3)
      end
    end

    # Resolver functions

    def get_event(_parent, %{id: id}, info) do
      current_user = GraphQL.current_user(info)

      with {:ok, ap_activity} <- Objects.read(id, current_user: current_user),
           true <- is_event_activity?(ap_activity) do
        {:ok,
         ap_activity
         |> repo().maybe_preload([:activity])
         |> Bonfire.Social.APActivities.preload_nested_objects(current_user: current_user)}
      else
        _ -> {:error, "Event not found"}
      end
    end

    # Helper functions

    defp is_event_activity?(%{json: json}) when is_map(json) do
      case json do
        %{"object" => %{"type" => "Event"}} -> true
        %{"type" => "Event"} -> true
        _ -> false
      end
    end

    defp is_event_activity?(_), do: false

    # defp filter_by_location(activities, location_id) do
    #   Enum.filter(activities, fn ap_activity ->
    #     event_obj = get_event_object(ap_activity)

    #     event_obj["location"] == location_id ||
    #       event_obj["location_id"] == location_id ||
    #       get_in(event_obj, ["location", "id"]) == location_id
    #   end)
    # end

    defp get_event_object(%{json: %{"object" => %{"type" => "Event"} = event}}), do: event
    defp get_event_object(%{json: %{"type" => "Event"} = event}), do: event
    defp get_event_object(_), do: %{}

    defp parse_boolean("true"), do: true
    defp parse_boolean(true), do: true
    defp parse_boolean(_), do: false
  end
else
  IO.warn("Skip Events GraphQL API")
end
