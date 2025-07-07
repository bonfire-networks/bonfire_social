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
        Enum.into(%{"object" => object}, activity || %{})
      else
        activity || %{}
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
end
