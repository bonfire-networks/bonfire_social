defmodule Bonfire.Social.APActivities do
  alias Bonfire.Data.Social.APActivity
  alias Bonfire.Social.Activities
  # alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Objects

  alias Ecto.Changeset
  # alias Needle.Changesets

  import Untangle

  use Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]

  def ap_receive_activity(creator, activity, object) do
    create(creator, activity, object)
  end

  def create(character, activity, object, public \\ nil)

  def create(character, %{data: %{} = activity, public: public}, object, public_initial),
    do: create(character, activity, object, public_initial || public)

  def create(character, activity, %{data: %{} = object, public: public}, public_initial),
    do: create(character, activity, object, public_initial || public)

  # def create(character, %{verb: verb} = activity, object) when verb in ["update", "Update", :update, :edit, "edit"] is_map(activity) or is_map(object) do
  #   # TODO: store version history
  # end

  def create(character, activity, object, public) when is_map(activity) or is_map(object) do
    if ulid(character) do
      do_create(character, activity, object, public)
    else
      with actor_id when is_binary(actor_id) <-
             e(activity, :data, "actor", "id", nil) ||
               e(activity, :data, "actor", nil) ||
               e(object, :data, "attributedTo", "id", nil) ||
               e(object, :data, "attributedTo", nil) ||
               e(object, :data, "actor", "id", nil) ||
               e(object, :data, "actor", nil),
           {:ok, character} <-
             Utils.maybe_apply(
               Bonfire.Federate.ActivityPub.AdapterUtils,
               :get_or_fetch_character_by_ap_id,
               [actor_id]
             ),
           cid when is_binary(cid) <- ulid(character) do
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

    json =
      if is_map(object) do
        Enum.into(%{"object" => the_object(object) || object}, activity || %{})
      else
        activity || %{}
      end
      |> debug("json to store")

    boundary =
      if(public, do: "public_remote", else: "mentions")
      |> debug("set boundary")

    # TODO: reuse logic from Posts for targeting the audience
    opts =
      [boundary: boundary, id: ulid(object), verb: e(activity, :verb, :create)]
      |> debug("ap_opts")

    with {:ok, apactivity} <- insert(character, json, opts) do
      # TODO: set pointer_id on AP Object
      #  {:ok, _} <- FeedActivities.save_fediverse_incoming_activity(character, :create, apactivity) do # Note: using `Activities.put_assoc/` instead
      {:ok, apactivity}
    end
  end

  defp do_create(character, activity, object) do
    do_create(character, activity, Enum.into(object, %{public: false}))
  end

  defp the_object(object) do
    ActivityPub.Object.normalize(object, true)
    |> ret_object()
  end

  defp ret_object(%{data: data}) do
    data
  end

  defp ret_object(data) do
    data
  end

  def insert(character, json, opts) do
    # TODO: add type field(s) to the table to be able to quickly filter without JSONB?
    # TODO: add creator (to be used when showing in reply_to)
    activity =
      %APActivity{}
      |> APActivity.changeset(%{json: json})
      |> Objects.cast_caretaker(character)
      |> Objects.cast_acl(character, opts)
      |> maybe_attach_video_oembed(json, character)

    # TODO: process and save mentions & hashtags

    id = opts[:id] || Changeset.get_change(activity, :id)

    activity
    |> Activities.put_assoc(opts[:verb], character, id)
    |> repo().insert()
    |> debug()
  end

  def maybe_attach_video_oembed(
        changeset,
        %{"object" => %{"type" => "Video", "id" => url}},
        current_user
      ) do
    # because Peertube doesn't give us details to play/embed the video in the AS JSON
    Bonfire.Files.Acts.URLPreviews.maybe_fetch_and_save(current_user, url)
    |> Bonfire.Files.Acts.AttachMedia.cast(changeset, ... || [])

    # TODO clean up: we shouldn't be reaching into the Acts outside of Epics
  end

  def maybe_attach_video_oembed(
        changeset,
        _json,
        _current_user
      ) do
    changeset
  end
end
