defmodule Bonfire.Social.APActivities do
  @moduledoc """
  A special type of activity object that stores federated JSON data as-is.

  This module is used for any object type that isn't recognized or isn't implemented by an extension.
  It provides functionality to handle ActivityPub activities, particularly for receiving and creating activities.
  """

  alias ActivityPub.Federator.NestedObjects.Terms
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
  @doc """
  Object types we keep whole as an `APActivity` rather than mapping onto a native type, so a custom preview can render the parts a native type would drop.

  Claiming a type here beats any other module that handles one of the same document's OTHER types: a `["Note", "Preparation"]` recipe is a `Preparation` we keep whole, not a `Note` with the recipe discarded.

  This is also the fallback for any activity type nobody else handles.
  """
  def federation_module,
    do: Bonfire.Common.Config.get([__MODULE__, :handle_object_types], [])

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
  def ap_receive_activity(creator, activity, object, extra_opts \\ []) do
    is_public? = Bonfire.Federate.ActivityPub.AdapterUtils.is_public?(activity, object)

    with {:ok, apactivity} = result <-
           ap_receive(
             creator,
             e(activity, :data, nil) || activity,
             e(object, :data, nil) || object,
             is_public?
           )
           |> maybe_publish_in(creator, object, extra_opts[:publish_in]) do
      # boosts it into the feeds of the categories it was tagged with (see `maybe_cast_tags/3`), as far as the creator may `:tag` them
      Utils.maybe_apply(
        Bonfire.Tag,
        :maybe_boost_tagged,
        [creator, apactivity, [ap_object: object]],
        fallback_return: nil
      )

      result
    end
  end

  # An APActivity is the fallback for object types nothing here models, and it runs no epic, so `Bonfire.Tag.Acts.Tag` never sees it and nothing would file it into the group the activity was addressed to. `maybe_tag/3` is the outside-an-epic equivalent: it tags the object and auto-boosts whichever tags are categories, under the same `:tag` permission check, so an unrecognised object still reaches the group's feed rather than being kept and hidden.
  defp maybe_publish_in(result, creator, ap_object, publish_in) do
    case {result, List.wrap(publish_in)} do
      {{:ok, apactivity}, [_ | _] = groups} ->
        # links the incoming AP object BEFORE tagging, because tagging auto-boosts the group and that boost federates an `Announce` resolved through the AP object — see `Incoming.link_and_tag/5`
        Utils.maybe_apply(
          Bonfire.Federate.ActivityPub.Incoming,
          :link_and_tag,
          [ap_object, Enums.id(apactivity), creator, groups],
          fallback_return: nil
        )

        {:ok, apactivity}

      _ ->
        result
    end
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

  def ap_receive(character, activity, object, public) when is_map(activity) or is_map(object) do
    case existing_apactivity(activity, object) do
      %APActivity{} = existing -> do_update(existing, character, activity, object)
      _ -> ap_receive_new(character, activity, object, public)
    end
  end

  defp ap_receive_new(character, activity, object, public) do
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

    json = json_to_store(activity, object)

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

  # store what wasn't consumed: a verb we model is already spent by here (its addressing became boundary/to_circles, its verb becomes the Activity's verb), so keeping the wrapper would duplicate what Bonfire models natively. A verb we don't model is itself the content, so it is kept whole with the object nested.
  defp json_to_store(activity, object) do
    modelled_verb? =
      Enum.any?(
        List.wrap(e(activity, "type", nil)),
        &(&1 in ActivityPub.Config.supported_activity_types())
      )

    cond do
      is_map(object) and modelled_verb? ->
        reference_nested_objects(object)

      is_map(object) ->
        Enum.into(%{"object" => reference_nested_objects(object)}, activity || %{})

      true ->
        reference_nested_objects(activity || %{})
    end
    |> debug("json to store")
  end

  # An `Update` is about an object we may already hold, found through the pointer of its AP object (the same AP id is what `ActivityPub.update` just rewrote). Without one it is received as a new object, as before.
  defp existing_apactivity(activity, object) do
    with true <- e(activity, "type", nil) == "Update",
         ap_id when is_binary(ap_id) <- e(object, "id", nil),
         {:ok, %{pointer_id: pointer_id}} when is_binary(pointer_id) <-
           ActivityPub.Object.get_cached(ap_id: ap_id),
         %APActivity{} = existing <- repo().get(APActivity, pointer_id) do
      existing
    else
      _ -> nil
    end
  end

  # An Update replaces the tags and the media too, with the same functions that edit a Post: both compare what is there with what the object now carries, and change only the difference. Without a character there is no one to tag or attach as, so only the JSON is rewritten.
  # TODO: store version history
  defp do_update(%APActivity{} = existing, character, activity, object) do
    json = json_to_store(activity, object)

    if uid(character) do
      existing = repo().maybe_preload(existing, [:tags, :media, :files])
      attrs = update_attrs(character, object_json(json))

      Bonfire.Tag.maybe_update_tags(character, existing, attrs)

      changeset = APActivity.changeset(existing, %{json: json})

      Bonfire.Files.maybe_update_media_assoc(character, existing, changeset, attrs) ||
        repo().update(changeset)
    else
      existing
      |> APActivity.changeset(%{json: json})
      |> repo().update()
    end
  end

  # what `maybe_cast_tags/3` and `maybe_attach_media/3` read from the object on a create, in the shape the Post update functions take: a missing `tag`, `image` or `attachment` means none, so tags and media that are no longer there are removed
  defp update_attrs(character, object) do
    tags = e(object, "tag", nil)

    %{
      hashtags: Bonfire.Tag.ap_receive_hashtags(tags),
      tags: maybe_category_tags(tags, character),
      primary_image: e(object, "image", nil) || e(object, "icon", nil),
      attachments: List.wrap(e(object, "attachment", nil))
    }
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
      |> maybe_attach_media(object_json(json), character)
      |> maybe_cast_tags(object_json(json), character)

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

  # A federated object carries its images and files as attachments, which become Media here, the
  # same as a local post's uploads. Without this each card would have to find and render its own
  # images, and every type without a card would show none at all.
  # TODO clean up: we shouldn't be reaching into the Acts outside of Epics
  defp maybe_attach_media(changeset, object, current_user) do
    case Bonfire.Files.ap_receive_media(current_user, object) do
      [] -> changeset
      media -> Bonfire.Files.Acts.AttachMedia.cast(changeset, media)
    end
  end

  # A `Hashtag` in the object's `tag` becomes a real tag, so a federated recipe's #salade is
  # searchable and shows in the hashtag feed like a local post's, instead of being text that each
  # card has to render as badges of its own.
  #
  # A `Category` in it (FEP-9b2b) becomes a tag of the local category it names, but only when a local user posted it for now: what a remote actor may tag here is not settled yet.
  defp maybe_cast_tags(changeset, object, character) do
    tags = e(object, "tag", nil)

    case (Bonfire.Tag.ap_receive_hashtags(tags) |> Map.values()) ++
           maybe_category_tags(tags, character) do
      [] -> changeset
      tags -> Bonfire.Social.Tags.maybe_cast(changeset, %{tags: tags}, character, [])
    end
  end

  defp maybe_category_tags(tags, character) do
    if Bonfire.Social.is_local?(character),
      do:
        Utils.maybe_apply(
          Bonfire.Classify.Categories,
          :ap_receive_category_tags,
          [tags, character],
          fallback_return: []
        ),
      else: []
  end

  # `json` is the object itself for a verb we model, and the whole activity for one we don't
  defp object_json(json) do
    case e(json, "object", nil) do
      %{} = object -> object
      _ -> json
    end
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

  # an ActivityPub document without a `@context` of its own is read with the ActivityStreams one
  @as2_context "https://www.w3.org/ns/activitystreams"

  @doc """
  Turns the AP ids that the fields of an object hold into the references the JSON of an APActivity keeps.

  The objects nested in an object's fields were stored on their own when it was ingested (`ActivityPub.Federator.NestedObjects`), which left their AP ids in the fields. A reference is what `preload_nested_objects/2` and the cards load the object by: the pointer of the object when it has one, else its ActivityPub id. Which fields hold objects is the document's `@context`'s to say (`ActivityPub.Federator.NestedObjects.Terms`). An id that is not a stored object stays as it is.
  """
  def reference_nested_objects(object) when is_map(object) do
    fields = Terms.fields(object, @as2_context)

    Enum.reduce(object, object, fn
      {key, value}, acc ->
        if key in fields, do: Map.put(acc, key, reference(value)), else: acc
    end)
  end

  def reference_nested_objects(other), do: other

  defp reference(ids) when is_list(ids), do: Enum.map(ids, &reference/1)

  defp reference(id) when is_binary(id) do
    with true <- String.starts_with?(id, ["http://", "https://"]),
         {:ok, %ActivityPub.Object{} = stored} <- ActivityPub.Object.get_cached(ap_id: id) do
      if actor_object?(stored), do: actor_reference(id), else: build_pointer_map(id, stored, nil)
    else
      _ -> id
    end
  end

  defp reference(other), do: other

  defp actor_reference(id) do
    case ActivityPub.Actor.get_cached(ap_id: id) do
      {:ok, %ActivityPub.Actor{} = actor} -> build_pointer_map(id, actor, nil, "ap_actor_id")
      _ -> id
    end
  end

  defp actor_object?(%{data: %{"type" => type}}),
    do: ActivityPub.Config.type_in?(type, ActivityPub.Config.supported_actor_types())

  defp actor_object?(_), do: false

  # Helper to build consistent pointer map structure
  defp build_pointer_map(id, object_with_pointer, fallback_type, ap_field \\ "ap_id") do
    type = e(object_with_pointer, :data, "type", nil) || fallback_type

    pointer = e(object_with_pointer, :pointer, nil)

    if pointer_id = e(object_with_pointer, :pointer_id, nil) || Enums.id(pointer) do
      %{
        "id" => id,
        "pointer_id" => pointer_id,
        # the schema, since it's read back to load the object by type (`Needles.list_by_type!/2`), where a group's `:group` names no table
        "pointer_type" => Types.object_type_schema(pointer || pointer_id),
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

    # Load AP objects (one batched query, drops unresolved)
    ap_objs =
      ap_ids
      |> Enum.map(fn {id, _, _, _} -> id end)
      |> ActivityPub.Object.list_cached()

    # Load AP actors (one batched query, drops unresolved)
    ap_actor_objs =
      ap_actor_ids
      |> Enum.map(fn {id, _, _, _} -> id end)
      |> ActivityPub.Actor.list_cached()

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
