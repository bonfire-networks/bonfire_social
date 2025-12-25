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

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: APActivity
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      # fallback for any unhandled activity types
    ]

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

  def ap_publish_activity(subject, _, %{json: data} = ap_activity) do
    debug(ap_activity, "AP - publishing APActivity")

    subject =
      subject || e(ap_activity, :created, :creator, nil) ||
        e(ap_activity, :created, :creator_id, nil)

    with {:ok, subject_actor} <-
           ActivityPub.Actor.get_cached(pointer: subject) do
      # TODO: special handling if ap_activity is already a Create Activity
      ActivityPub.create(%{to: data["to"], actor: subject_actor, object: data})
    else
      {:error, :not_found} ->
        debug(subject, "Could not find actor to publish activity")
        :ignore

      e ->
        error(e)
    end
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
    Bonfire.Files.Media.maybe_fetch_and_save(current_user, url)
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
    options =
      Keyword.put_new(options, :to, object["to"] || object["cc"] || object["audience"] || [])

    if Keyword.get(options, :fetch_remote?, true) do
      object
      |> Enum.reduce(object, fn
        {key, _value}, acc
        when key in [
               # common fields we know shouldn't include nested objects we want to process separately
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
    case ActivityPub.Federator.Fetcher.fetch_object_from_id(
           id,
           options
           |> Keyword.put_new(:triggered_by, "APActivities.fetch_and_normalize_nested_object")
         ) do
      {:ok, %ActivityPub.Object{} = fetched_object} ->
        debug(fetched_object, "Fetched Object from ActivityPub")
        {:ok, build_pointer_map(id, fetched_object, embedded_object["type"])}

      {:ok, %ActivityPub.Actor{} = fetched_object} ->
        debug(fetched_object, "Fetched Actor from ActivityPub")
        {:ok, build_pointer_map(id, fetched_object, embedded_object["type"], "ap_actor_id")}

      e ->
        debug(
          e,
          "Could not fetch and/or save embedded object, falling back to using embedded data"
        )

        # Fallback: create object from embedded data if available
        create_object_from_embedded_data(embedded_object, options)
    end
  end

  defp create_object_from_embedded_data(%{"id" => id} = embedded_object, options) do
    # Create object using the embedded data
    case embedded_object
         |> Map.put_new("to", options[:to] || [])
         # |> ActivityPub.Object.insert(false) 
         |> debug("WIP: call incoming adapter on this?")
         |> ActivityPub.Federator.Fetcher.cached_or_handle_incoming(
           options
           |> Keyword.put_new(:triggered_by, "APActivities.create_object_from_embedded_data")
         )
         |> debug("Handled incoming for created embedded object") do
      {:ok, %{} = created_object} ->
        {:ok, build_pointer_map(id, created_object, embedded_object["type"])}

      e ->
        error(e, "Could not insert embedded data as Object, falling back to using as-is")
        :skip
    end
  end

  # Helper to build consistent pointer map structure
  defp build_pointer_map(id, object_with_pointer, fallback_type, ap_field \\ "ap_id") do
    type = e(object_with_pointer, :data, "type", nil) || fallback_type

    pointer = e(object_with_pointer, :pointer, nil)

    if pointer_id = e(object_with_pointer, :pointer_id, nil) || Enums.id(pointer) do
      %{
        "id" => id,
        "pointer_id" => pointer_id,
        "pointer_type" => Types.object_type(pointer || pointer_id),
        "type" => type
      }
    else
      %{
        "id" => id,
        "type" => type
      }
      |> Map.put(ap_field, Enums.id(object_with_pointer))
    end
  end

  @doc """
  Preloads nested objects referenced by pointer_id, ap_id, or ap_actor_id in APActivity JSON fields.
  This function automatically detects ALL fields containing such IDs and bulk loads them to avoid n+1 queries.
  """
  def preload_nested_objects(activities, opts \\ []) do
    # Extract all nested object IDs and their types from ANY JSON field
    {nested_object_data, fields_with_nested_objects} =
      extract_all_nested_object_ids_from_json(activities)

    if nested_object_data != [] do
      # Group by type and bulk load efficiently
      nested_objects = load_nested_objects_by_type(nested_object_data, opts)
      # Inject the loaded objects back into the JSON and store the fields info
      inject_nested_objects_into_json(activities, fields_with_nested_objects, nested_objects)
    else
      activities
    end
  end

  # Extract nested object IDs and types from ALL JSON fields in APActivity objects
  defp extract_all_nested_object_ids_from_json(activities) do
    activities
    |> List.wrap()
    |> Enum.reduce({[], MapSet.new()}, fn activity, acc ->
      case activity do
        %{json: json} when is_map(json) ->
          extract_all_nested_object_ids_from_map(json)

        %{object: %{json: json}} when is_map(json) ->
          extract_all_nested_object_ids_from_map(json)

        %{activity: %{object: %{json: json}}} when is_map(json) ->
          extract_all_nested_object_ids_from_map(json)

        _ ->
          {[], MapSet.new()}
      end
    end)
    |> then(fn {data, fields} -> {Enum.uniq(data), MapSet.to_list(fields)} end)
  end

  defp extract_all_nested_object_ids_from_map(json, path \\ []) do
    Enum.reduce(json, {[], MapSet.new()}, fn {key, value}, {data_acc, fields_acc} ->
      current_path = path ++ [key]

      case value do
        %{"pointer_id" => id, "pointer_type" => type} when is_binary(id) ->
          {[{id, :pointer_id, type, current_path} | data_acc],
           MapSet.put(fields_acc, current_path)}

        %{"ap_id" => id, "type" => type} when is_binary(id) ->
          {[{id, :ap_id, type, current_path} | data_acc], MapSet.put(fields_acc, current_path)}

        %{"ap_actor_id" => id, "type" => type} when is_binary(id) ->
          {[{id, :ap_actor_id, type, current_path} | data_acc],
           MapSet.put(fields_acc, current_path)}

        list when is_list(list) ->
          Enum.reduce(list, {data_acc, fields_acc}, fn item, {d_acc, f_acc} ->
            case item do
              %{"pointer_id" => id, "pointer_type" => type} when is_binary(id) ->
                {[{id, :pointer_id, type, current_path} | d_acc], MapSet.put(f_acc, current_path)}

              %{"ap_id" => id, "type" => type} when is_binary(id) ->
                {[{id, :ap_id, type, current_path} | d_acc], MapSet.put(f_acc, current_path)}

              %{"ap_actor_id" => id, "type" => type} when is_binary(id) ->
                {[{id, :ap_actor_id, type, current_path} | d_acc],
                 MapSet.put(f_acc, current_path)}

              nested_map when is_map(nested_map) ->
                {nested_data, nested_fields} =
                  extract_all_nested_object_ids_from_map(nested_map, current_path)

                {nested_data ++ d_acc, MapSet.union(f_acc, nested_fields)}

              _ ->
                {d_acc, f_acc}
            end
          end)

        nested_map when is_map(nested_map) ->
          {nested_data, nested_fields} =
            extract_all_nested_object_ids_from_map(nested_map, current_path)

          {nested_data ++ data_acc, MapSet.union(fields_acc, nested_fields)}

        _ ->
          {data_acc, fields_acc}
      end
    end)
  end

  defp load_nested_objects_by_type(nested_object_data, opts) do
    # Group by field type (:pointer_id, :ap_id, :ap_actor_id)
    grouped =
      Enum.group_by(nested_object_data, fn {_id, field, _type, _path} -> field end)

    pointer_ids =
      grouped[:pointer_id] || []

    ap_ids =
      grouped[:ap_id] || []

    ap_actor_ids =
      grouped[:ap_actor_id] || []

    # Load pointer objects by type
    pointer_objs =
      pointer_ids
      |> Enum.group_by(fn {_id, _field, type, _path} -> type end)
      |> Enum.flat_map(fn {type, list} ->
        ids = Enum.map(list, fn {id, _, _, _} -> id end)
        # debug({type, ids}, "info: loading pointer objects")
        if type && type != nil do
          Bonfire.Common.Needles.list_by_type!(type, [id: ids], opts)
        else
          Bonfire.Common.Needles.list!(ids, opts)
        end
      end)
      |> debug("loaded pointer objects")

    # Load AP objects
    ap_objs =
      Enum.map(ap_ids, fn {id, _, _, _} ->
        debug(id, "info: loading ap_id")

        case ActivityPub.Object.get_cached(id) do
          {:ok, obj} ->
            debug(obj, "info: loaded ap_id object")

          other ->
            warn(other, "info: failed to load ap_id")
            nil
        end
      end)
      |> Enum.filter(& &1)

    # Load AP actors
    ap_actor_objs =
      Enum.map(ap_actor_ids, fn {id, _, _, _} ->
        debug(id, "info: loading ap_actor_id")

        case ActivityPub.Actor.get_cached(id) do
          {:ok, obj} ->
            debug(obj, "info: loaded ap_actor_id object")

          other ->
            warn(other, "info: failed to load ap_actor_id")
            nil
        end
      end)
      |> Enum.filter(& &1)

    # Merge all loaded objects into a map by id
    (pointer_objs ++ ap_objs ++ ap_actor_objs)
    |> Map.new(fn obj -> {obj.id, obj} end)
    |> debug("loaded objects")
  end

  # Inject loaded objects back into JSON fields
  defp inject_nested_objects_into_json(activities, json_fields, nested_objects)
       when is_list(activities) do
    Enum.map(activities, &inject_nested_objects_into_json(&1, json_fields, nested_objects))
  end

  defp inject_nested_objects_into_json(%{edges: edges} = page, json_fields, nested_objects) do
    %{page | edges: inject_nested_objects_into_json(edges, json_fields, nested_objects)}
  end

  defp inject_nested_objects_into_json(%{json: json} = struct, json_fields, nested_objects)
       when is_map(json) do
    updated_json = inject_nested_objects_into_json_map(json, json_fields, nested_objects)

    Map.put(struct, :json, Map.put(updated_json, "__bonfire_preloaded_fields__", json_fields))
  end

  defp inject_nested_objects_into_json(
         %{object: %{json: _} = object} = struct,
         json_fields,
         nested_objects
       )
       when is_map(object) do
    updated_object = inject_nested_objects_into_json(object, json_fields, nested_objects)
    Map.put(struct, :object, updated_object)
  end

  defp inject_nested_objects_into_json(
         %{activity: %{} = activity} = struct,
         json_fields,
         nested_objects
       )
       when is_map(activity) do
    updated_activity = inject_nested_objects_into_json(activity, json_fields, nested_objects)
    Map.put(struct, :activity, updated_activity)
  end

  defp inject_nested_objects_into_json(list, json_fields, nested_objects) when is_list(list) do
    Enum.map(list, &inject_nested_objects_into_json(&1, json_fields, nested_objects))
  end

  defp inject_nested_objects_into_json(other, _json_fields, _nested_objects), do: other

  @doc """
  Injects loaded objects into a JSON map by matching pointer_id, ap_id, or ap_actor_id.

  This function iterates through the specified json_fields and:
  1. For fields containing a map with one of those IDs, adds a "nested_object" key with the loaded object
  2. For fields containing a list, processes each item in the list that has one of those IDs
  3. Leaves other fields unchanged
  """
  defp inject_nested_objects_into_json_map(json, json_fields, nested_objects) do
    debug({json, json_fields}, "info: inject_nested_objects_into_json_map input")

    Enum.reduce(json_fields, json, fn path, acc_json ->
      case ed(acc_json, path, nil) do
        %{"pointer_id" => id} = field_data when is_binary(id) ->
          obj = Map.get(nested_objects, id)

          if obj do
            # debug({path, id, obj}, "info: injecting pointer_id - success")
            put_in(acc_json, path, Map.put(field_data, "nested_object", obj))
          else
            # debug({path, id}, "info: injecting pointer_id - skipped (not found)")
            acc_json
          end

        %{"ap_id" => id} = field_data when is_binary(id) ->
          obj = Map.get(nested_objects, id)

          if obj do
            # debug({path, id, obj}, "info: injecting ap_id - success")
            put_in(acc_json, path, Map.put(field_data, "nested_object", obj))
          else
            # debug({path, id}, "info: injecting ap_id - skipped (not found)")
            acc_json
          end

        %{"ap_actor_id" => id} = field_data when is_binary(id) ->
          obj = Map.get(nested_objects, id)

          if obj do
            # debug({path, id, obj}, "info: injecting ap_actor_id - success")
            put_in(acc_json, path, Map.put(field_data, "nested_object", obj))
          else
            # debug({path, id}, "info: injecting ap_actor_id - skipped (not found)")
            acc_json
          end

        list when is_list(list) ->
          updated_list =
            Enum.map(list, fn
              %{"pointer_id" => id} = item when is_binary(id) ->
                obj = Map.get(nested_objects, id)

                if obj do
                  # debug({path, id, obj}, "info: injecting pointer_id in list - success")
                  Map.put(item, "nested_object", obj)
                else
                  # debug({path, id}, "info: injecting pointer_id in list - skipped (not found)")
                  item
                end

              %{"ap_id" => id} = item when is_binary(id) ->
                obj = Map.get(nested_objects, id)

                if obj do
                  # debug({path, id, obj}, "info: injecting ap_id in list - success")
                  Map.put(item, "nested_object", obj)
                else
                  # debug({path, id}, "info: injecting ap_id in list - skipped (not found)")
                  item
                end

              %{"ap_actor_id" => id} = item when is_binary(id) ->
                obj = Map.get(nested_objects, id)

                if obj do
                  # debug({path, id, obj}, "info: injecting ap_actor_id in list - success")
                  Map.put(item, "nested_object", obj)
                else
                  # debug({path, id}, "info: injecting ap_actor_id in list - skipped (not found)")
                  item
                end

              item ->
                item
            end)

          put_in(acc_json, path, updated_list)

        nil ->
          # debug({path}, "info: injecting - skipped (nil field)")
          acc_json

        other ->
          debug({path, other}, "inject_nested_objects_into_json_map - unmatched case")
          acc_json
      end
    end)
  end
end
