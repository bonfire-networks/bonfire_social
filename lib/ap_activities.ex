defmodule Bonfire.Social.APActivities do
  @moduledoc """
  A special type of activity object that stores federated JSON data as-is.

  This module is used for any object type that isn't recognized or isn't implemented by an extension.
  It provides functionality to handle ActivityPub activities, particularly for receiving and creating activities.
  """

  alias Bonfire.Data.Social.APActivity
  alias Bonfire.Social.Activities
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Objects

  alias Ecto.Changeset
  # alias Needle.Changesets

  import Untangle

  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  import Bonfire.Common.Config, only: [repo: 0]

  @doc """
  Receives and processes an ActivityPub activity.

  This function is used to handle incoming federated activities.

  ## Parameters

    - creator: The character (user) associated with the activity.
    - activity: The ActivityPub activity.
    - object: The object associated with the activity.

  ## Examples

      iex> creator = %Character{id: "user123"}
      iex> activity = %{data: %{"type" => "Create"}}
      iex> object = %{data: %{"type" => "Note", "content" => "Hello, fediverse!"}}
      iex> Bonfire.Social.APActivities.ap_receive_activity(creator, activity, object)
      {:ok, %APActivity{}}

  """
  def ap_receive_activity(creator, activity, object) do
    is_public? = Bonfire.Federate.ActivityPub.AdapterUtils.is_public?(activity, object)

    ap_receive(
      creator,
      e(activity, :data, nil) || activity,
      e(object, :data, nil) || object,
      is_public?
    )
  end

  @doc """
  Creates an `APActivity` from the given character, activity, and object.

  This function handles various patterns of input data to create an APActivity.

  ## Parameters

    - character: The character (user) creating the activity.
    - activity: The activity data.
    - object: The object data.
    - public: A boolean indicating whether the activity is public (optional).

  ## Examples

      iex> character = %Character{id: "user123"}
      iex> activity = %{"type" => "Create", "object" => %{"content" => "Hello, world!"}}
      iex> object = %{"type" => "Note"}
      iex> ap_receive(character, activity, object)
      {:ok, %APActivity{}}

      iex> ap_receive(character, activity, object, true)
      {:ok, %APActivity{}}

  """
  def ap_receive(character, activity, object, public \\ nil)

  # def ap_receive(character, %{verb: verb} = activity, object) when verb in ["update", "Update", :update, :edit, "edit"] is_map(activity) or is_map(object) do
  #   # TODO: store version history
  # end

  def ap_receive(character, activity, object, public) when is_map(activity) or is_map(object) do
    if uid(character) do
      do_create(character, activity, object, public)
    else
      #  TODO: use a utility function to extract actor ID
      with actor_id when is_binary(actor_id) <-
             e(activity, "actor", "id", nil) ||
               e(activity, "actor", nil) ||
               e(object, "attributedTo", "id", nil) ||
               e(object, "attributedTo", nil) ||
               e(object, "actor", "id", nil) ||
               e(object, "actor", nil),
           {:ok, character} <-
             Utils.maybe_apply(
               Bonfire.Federate.ActivityPub.AdapterUtils,
               :get_or_fetch_character_by_ap_id,
               [actor_id]
             ),
           cid when is_binary(cid) <- uid(character) do
        do_create(character, activity, object, public)
      else
        other ->
          error(
            other,
            "AP - cannot create a fallback activity with no valid character"
          )
      end
    end
  end

  defp do_create(character, activity, object, public) do
    debug(activity, "activity")
    debug(object, "object")

    {boundary, to_circles} =
      Bonfire.Federate.ActivityPub.AdapterUtils.incoming_boundary_circles(
        activity,
        object,
        public
      )
      |> debug("incoming_boundary_circles")

    json =
      if is_map(object) do
        Enum.into(%{"object" => fetch_and_create_nested_ap_objects(object)}, activity || %{})
      else
        fetch_and_create_nested_ap_objects(activity) || %{}
      end
      |> debug("json to store")

    # TODO: reuse logic from Posts for targeting the audience
    opts =
      [
        boundary: boundary,
        to_circles: to_circles,
        id: uid(object),
        verb: e(activity, :verb, :create)
      ]
      |> debug("ap_opts")

    with {:ok, apactivity} <- insert(character, json, opts) do
      # TODO: set pointer_id on AP Object
      #  {:ok, _} <- FeedActivities.save_fediverse_incoming_activity(character, :create, apactivity) do # Note: using `Activities.put_assoc/` instead
      {:ok, apactivity}
    end
  end

  # defp the_object(object) do
  #   # NOTE: not using as it should come to us already normalised 
  #   ActivityPub.Object.normalize(object, false)
  #   |> ret_object()
  # end

  # defp ret_object(%{data: data}) do
  #   data
  # end

  # defp ret_object(data) do
  #   data
  # end

  defp insert(character, json, opts) do
    # TODO: add type field(s) to the table to be able to quickly filter without JSONB?
    activity =
      %APActivity{}
      |> APActivity.changeset(%{json: json})
      # TODO: process and save thread, reply_to, mentions & hashtags
      |> Objects.cast_creator_caretaker(character)
      # TODO: set boundary and to_circles
      |> Objects.cast_acl(character, opts)
      |> maybe_attach_video_oembed(json, character)

    activity
    |> Activities.cast(
      opts[:verb] || :create,
      character,
      Keyword.put(opts, :object_id, opts[:id] || Changeset.get_change(activity, :id))
    )
    |> debug()
    |> repo().insert()
    |> debug()
  end

  defp maybe_attach_video_oembed(
         changeset,
         %{"object" => %{"type" => "Video", "id" => url}},
         current_user
       ) do
    # because Peertube doesn't give us details to play/embed the video in the AS JSON
    Bonfire.Files.Acts.URLPreviews.maybe_fetch_and_save(current_user, url)
    |> Bonfire.Files.Acts.AttachMedia.cast(changeset, ... || [])

    # TODO clean up: we shouldn't be reaching into the Acts outside of Epics
  end

  defp maybe_attach_video_oembed(
         changeset,
         _json,
         _current_user
       ) do
    changeset
  end

  def filter_by_type(query \\ Object, activity_type)

  def filter_by_type(query, types) when is_list(types) do
    where(
      query,
      [a],
      fragment("(?)->>'type' = ?", a.json, ^types)
    )
  end

  def filter_by_type(query, type) do
    where(
      query,
      [a],
      fragment("(?)->>'type' = ?", a.json, ^type)
    )
  end

  def filter_exclude_type(query \\ Object, type) do
    where(
      query,
      [a],
      fragment("(?)->>'type' != ?", a.json, ^type)
    )
  end

  # detect and fetch nested AP objects
  def fetch_and_create_nested_ap_objects(object, options \\ []) do
    if Keyword.get(options, :fetch_remote?, true) do
      object
      |> Enum.reduce(object, fn
        {key, _value}, acc
        when key in [
               "@context",
               "id",
               "actor",
               "object",
               "type",
               "attributedTo",
               "audience",
               "contentMap",
               "name",
               "nameMap",
               "startTime",
               "endTime",
               "context",
               "inReplyTo",
               "published",
               "replies",
               "summaryMap",
               "updated",
               "url",
               "to",
               "bto",
               "cc",
               "bcc",
               "duration"
             ] ->
          acc

        {key, value}, acc ->
          case detect_and_fetch_nested_objects(value, options) do
            {:ok, fetched_object} ->
              # Replace with pointer ID or keep original based on your needs
              Map.put(acc, key, fetched_object)

            _ ->
              acc
          end
      end)
    else
      object
    end
  end

  defp detect_and_fetch_nested_objects(value, _options) when is_list(value) do
    # Handle arrays of potential AP objects
    {:ok,
     Enum.map(value, fn item ->
       case detect_and_fetch_nested_objects(item, []) do
         {:ok, fetched} ->
           fetched

         _ ->
           # fallback to preserving existing data
           item
       end
     end)}
  end

  defp detect_and_fetch_nested_objects(%{"id" => id, "type" => type} = value, options)
       when is_binary(id) and (is_binary(type) or is_list(type)) do
    # Check if this looks like an AP object with an ID and type
    if ActivityPub.Config.known_fetchable_type?(type) do
      fetch_and_normalize_nested_object(id, value, options)
    else
      # debug(type, "Skip fetching nested type")
      :skip
    end
  end

  defp detect_and_fetch_nested_objects(value, _options) do
    #  debug(value, "Skip fetching nested value")
    :skip
  end

  defp fetch_and_normalize_nested_object(id, embedded_object, options) do
    # Try to fetch and create the object
    case ActivityPub.Federator.Fetcher.fetch_object_from_id(id) do
      {:ok, %ActivityPub.Object{} = fetched_object} ->
        # debug(fetched_object, "Fetched Object from ActivityPub")
        {:ok, build_pointer_map(id, fetched_object, embedded_object["type"])}

      {:ok, %ActivityPub.Actor{} = fetched_object} ->
        #  debug(fetched_object, "Fetched Actor from ActivityPub")
        {:ok, build_pointer_map(id, fetched_object, embedded_object["type"])}

      e ->
        warn(
          e,
          "Could not fetch and/or save embedded object, falling back to using embedded data"
        )

        # Fallback: create object from embedded data if available
        create_object_from_embedded_data(embedded_object, options)
    end
  end

  defp create_object_from_embedded_data(%{"id" => id} = embedded_object, _options) do
    # Create object using the embedded data - TODO: call incoming adapter on this?
    case ActivityPub.Object.insert(embedded_object, false) do
      {:ok, %ActivityPub.Object{} = created_object} ->
        # debug(created_object, "Created Object from embedded data")
        {:ok, build_pointer_map(id, created_object, embedded_object["type"])}

      e ->
        error(e, "Could not insert embedded data as Object, falling back to using as-is")
        :skip
    end
  end

  # Helper to build consistent pointer map structure
  defp build_pointer_map(id, object_with_pointer, fallback_type) do
    pointer = e(object_with_pointer, :pointer, nil)
    pointer_id = e(object_with_pointer, :pointer_id, nil) || Enums.id(pointer)

    %{
      "id" => id,
      "pointer_id" => pointer_id,
      "pointer_type" => Types.object_type(pointer || pointer_id),
      "type" => e(object_with_pointer, :data, "type", nil) || fallback_type
    }
  end

  @doc """
  Preloads nested objects referenced by pointer_id in APActivity JSON fields.
  This function automatically detects ALL fields containing pointer_ids and bulk loads them to avoid n+1 queries.
  """
  def preload_ap_activity_pointers(activities, opts \\ []) do
    # debug(activities, "preload_ap_activity_pointers: input activities")

    # Extract all pointer IDs and their types from ANY JSON field
    {pointer_data, fields_with_pointers} = extract_all_pointer_ids_from_json(activities)

    # debug(pointer_data, "preload_ap_activity_pointers: extracted pointer_data")
    # debug(fields_with_pointers, "preload_ap_activity_pointers: fields_with_pointers")

    if pointer_data != [] do
      # Group by type and bulk load efficiently
      pointer_objects = load_pointers_by_type(pointer_data, opts)
      # |> debug("preload_ap_activity_pointers: pointer_objects map")

      # Inject the loaded objects back into the JSON and store the fields info
      inject_objects_into_json(activities, fields_with_pointers, pointer_objects)
      # |> debug("preload_ap_activity_pointers: final result")
    else
      # debug("preload_ap_activity_pointers: no pointer_ids found, returning original activities")
      activities
    end
  end

  # Extract pointer IDs and types from ALL JSON fields in APActivity objects
  defp extract_all_pointer_ids_from_json(activities) do
    # debug(activities, "extract_all_pointer_ids_from_json: input activities")

    activities
    |> List.wrap()
    |> Enum.reduce({[], MapSet.new()}, fn activity, acc ->
      debug(activity, "extract_all_pointer_ids_from_json: processing activity")

      case activity do
        %{json: json} when is_map(json) ->
          debug(json, "extract_all_pointer_ids_from_json: found json field")
          extract_all_pointer_ids_from_map(json)

        %{object: %{json: json}} when is_map(json) ->
          debug(json, "extract_all_pointer_ids_from_json: found json field")
          extract_all_pointer_ids_from_map(json)

        %{activity: %{object: %{json: json}}} when is_map(json) ->
          debug(json, "extract_all_pointer_ids_from_json: found nested json field")
          extract_all_pointer_ids_from_map(json)

        _ ->
          debug(activity, "extract_all_pointer_ids_from_json: no json field found")
          {[], MapSet.new()}
      end
    end)
    |> then(fn {pointer_data, fields} -> {Enum.uniq(pointer_data), MapSet.to_list(fields)} end)

    # |> debug("extract_all_pointer_ids_from_json: final result")
  end

  defp extract_all_pointer_ids_from_map(json, path \\ []) do
    debug(json, "extract_all_pointer_ids_from_map: processing json")
    debug(path, "extract_all_pointer_ids_from_map: current path")

    Enum.reduce(json, {[], MapSet.new()}, fn {key, value}, {pointer_data_acc, fields_acc} ->
      current_path = path ++ [key]
      debug({key, value}, "extract_all_pointer_ids_from_map: processing key-value pair")

      case value do
        %{"pointer_id" => pointer_id, "pointer_type" => pointer_type}
        when is_binary(pointer_id) and is_binary(pointer_type) ->
          debug(
            {key, pointer_id, pointer_type},
            "extract_all_pointer_ids_from_map: found pointer_id with type"
          )

          {[{pointer_id, pointer_type} | pointer_data_acc], MapSet.put(fields_acc, key)}

        %{"pointer_id" => pointer_id} when is_binary(pointer_id) ->
          debug(
            {key, pointer_id},
            "extract_all_pointer_ids_from_map: found pointer_id without type"
          )

          {[{pointer_id, nil} | pointer_data_acc], MapSet.put(fields_acc, key)}

        list when is_list(list) ->
          debug({key, list}, "extract_all_pointer_ids_from_map: processing list")
          # Check each item in the list
          Enum.reduce(list, {pointer_data_acc, fields_acc}, fn item, {data_acc, fields_acc2} ->
            case item do
              %{"pointer_id" => pointer_id, "pointer_type" => pointer_type}
              when is_binary(pointer_id) and is_binary(pointer_type) ->
                debug(
                  {key, pointer_id, pointer_type},
                  "extract_all_pointer_ids_from_map: found pointer_id with type in list item"
                )

                {[{pointer_id, pointer_type} | data_acc], MapSet.put(fields_acc2, key)}

              %{"pointer_id" => pointer_id} when is_binary(pointer_id) ->
                debug(
                  {key, pointer_id},
                  "extract_all_pointer_ids_from_map: found pointer_id without type in list item"
                )

                {[{pointer_id, nil} | data_acc], MapSet.put(fields_acc2, key)}

              nested_map when is_map(nested_map) ->
                debug(
                  {key, nested_map},
                  "extract_all_pointer_ids_from_map: recursing into nested map in list"
                )

                {nested_data, nested_fields} =
                  extract_all_pointer_ids_from_map(nested_map, current_path)

                {nested_data ++ data_acc, MapSet.union(fields_acc2, nested_fields)}

              _ ->
                {data_acc, fields_acc2}
            end
          end)

        nested_map when is_map(nested_map) ->
          # debug({key, nested_map}, "extract_all_pointer_ids_from_map: recursing into nested map")
          # Recursively check nested maps
          {nested_data, nested_fields} =
            extract_all_pointer_ids_from_map(nested_map, current_path)

          {nested_data ++ pointer_data_acc, MapSet.union(fields_acc, nested_fields)}

        _ ->
          # debug({key, value}, "extract_all_pointer_ids_from_map: skipping non-matching value")
          {pointer_data_acc, fields_acc}
      end
    end)
    |> debug("extract_all_pointer_ids_from_map: returning result")
  end

  # Load pointers efficiently by grouping by type and using list_by_type
  defp load_pointers_by_type(pointer_data, opts) do
    # Group pointer IDs by their types
    grouped_by_type = Enum.group_by(pointer_data, fn {_id, type} -> type end)

    debug(grouped_by_type, "load_pointers_by_type: grouped by type")

    # Load each type efficiently
    Enum.flat_map(grouped_by_type, fn {pointer_type, pointer_list} ->
      ids = Enum.map(pointer_list, fn {id, _type} -> id end)

      if pointer_type && pointer_type != "" do
        debug({pointer_type, ids}, "load_pointers_by_type: loading by type")
        # Use list_by_type for efficient loading when we have type info
        Bonfire.Common.Needles.list_by_type!(pointer_type, [id: ids], opts)
      else
        debug(ids, "load_pointers_by_type: loading without type (fallback)")
        # Fallback to regular list when no type available
        Bonfire.Common.Needles.list!(ids, opts)
      end
    end)
    |> Map.new(fn obj -> {obj.id, obj} end)
  end

  # Inject loaded objects back into JSON fields
  defp inject_objects_into_json(activities, json_fields, pointer_objects)
       when is_list(activities) do
    Enum.map(activities, &inject_objects_into_json(&1, json_fields, pointer_objects))
  end

  defp inject_objects_into_json(%{edges: edges} = page, json_fields, pointer_objects) do
    %{page | edges: inject_objects_into_json(edges, json_fields, pointer_objects)}
  end

  defp inject_objects_into_json(%{json: json} = struct, json_fields, pointer_objects)
       when is_map(json) do
    updated_json = inject_objects_into_json_map(json, json_fields, pointer_objects)
    # Store metadata about which fields have preloaded pointers for rendering
    updated_struct =
      Map.put(struct, :json, Map.put(updated_json, "_bonfire_preloaded_fields", json_fields))

    updated_struct
  end

  defp inject_objects_into_json(
         %{object: %{json: _} = object} = struct,
         json_fields,
         pointer_objects
       )
       when is_map(object) do
    updated_object = inject_objects_into_json(object, json_fields, pointer_objects)
    Map.put(struct, :object, updated_object)
  end

  defp inject_objects_into_json(
         %{activity: %{} = activity} = struct,
         json_fields,
         pointer_objects
       )
       when is_map(activity) do
    updated_activity = inject_objects_into_json(activity, json_fields, pointer_objects)
    Map.put(struct, :activity, updated_activity)
  end

  defp inject_objects_into_json(list, json_fields, pointer_objects) when is_list(list) do
    Enum.map(list, &inject_objects_into_json(&1, json_fields, pointer_objects))
  end

  defp inject_objects_into_json(other, _json_fields, _pointer_objects), do: other

  @doc """
  Injects loaded objects into a JSON map by matching pointer_ids.

  This function iterates through the specified json_fields and:
  1. For fields containing a map with "pointer_id", adds a "pointer" key with the loaded object
  2. For fields containing a list, processes each item in the list that has a "pointer_id"
  3. Leaves other fields unchanged

  ## Parameters

    - json: The original JSON map to modify
    - json_fields: List of field names (strings) that were found to contain pointer_ids
    - pointer_objects: Map of pointer_id -> loaded_object for quick lookup
    
  ## Returns

  The modified JSON map with "pointer" keys added alongside existing data where pointer_ids were found.

  ## Example

  Given json: %{"location" => %{"id" => "123", "pointer_id" => "abc123", "name" => "Place"}}
  And pointer_objects: %{"abc123" => %{id: "abc123", name: "Loaded Place"}}

  Returns: %{"location" => %{"id" => "123", "pointer_id" => "abc123", "name" => "Place", "pointer" => %{id: "abc123", name: "Loaded Place"}}}
  """
  defp inject_objects_into_json_map(json, json_fields, pointer_objects) do
    debug(json, "inject_objects_into_json_map: input json")
    debug(json_fields, "inject_objects_into_json_map: json_fields")
    debug(pointer_objects, "inject_objects_into_json_map: pointer_objects")

    result =
      Enum.reduce(json_fields, json, fn field, acc_json ->
        field_str = to_string(field)
        debug({field, field_str}, "inject_objects_into_json_map: processing field")

        case Map.get(acc_json, field_str) do
          %{"pointer_id" => pointer_id} = field_data when is_binary(pointer_id) ->
            debug(
              {field_str, pointer_id, field_data},
              "inject_objects_into_json_map: found field with pointer_id"
            )

            case Map.get(pointer_objects, pointer_id) do
              nil ->
                debug(
                  {field_str, pointer_id},
                  "inject_objects_into_json_map: no object found for pointer_id"
                )

                acc_json

              object ->
                debug(
                  {field_str, pointer_id, object},
                  "inject_objects_into_json_map: injecting object"
                )

                Map.put(acc_json, field_str, Map.put(field_data, "pointer", object))
            end

          list when is_list(list) ->
            debug({field_str, list}, "inject_objects_into_json_map: processing list field")

            updated_list =
              Enum.map(list, fn
                %{"pointer_id" => pointer_id} = item when is_binary(pointer_id) ->
                  case Map.get(pointer_objects, pointer_id) do
                    nil -> item
                    object -> Map.put(item, "pointer", object)
                  end

                item ->
                  item
              end)

            Map.put(acc_json, field_str, updated_list)

          other ->
            debug(
              {field_str, other},
              "inject_objects_into_json_map: field not matching expected pattern"
            )

            acc_json
        end
      end)

    debug(result, "inject_objects_into_json_map: final result")
    result
  end
end
