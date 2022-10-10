defmodule Bonfire.Social.APActivities do
  alias Bonfire.Data.Social.APActivity
  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.Objects

  alias Ecto.Changeset
  alias Pointers.Changesets

  import Untangle

  use Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]

  def create(nil, activity, object) when is_map(activity) or is_map(object) do
    with actor_id when is_binary(actor_id) <-
           e(activity, :data, "actor", "id", nil) ||
             e(activity, :data, "actor", nil) ||
             e(object, :data, "attributedTo", "id", nil) ||
             e(object, :data, "attributedTo", nil) ||
             e(object, :data, "actor", "id", nil) ||
             e(object, :data, "actor", nil),
         {:ok, character} <-
           Bonfire.Federate.ActivityPub.Utils.get_character_by_ap_id(actor_id) do
      create(character, activity, object)
    else
      other ->
        error(
          other,
          "AP - cannot create a fallback activity with no valid character"
        )
    end
  end

  def create(character, %{data: %{} = activity}, object), do: create(character, activity, object)
  def create(character, activity, %{data: %{} = object}), do: create(character, activity, object)

  def create(character, activity, object) do
    json =
      if is_map(object) do
        Enum.into(%{"object" => ActivityPub.Object.normalize(object, true)}, activity || %{})
      else
        activity || %{}
      end

    # TODO: reuse logic from Posts for targeting the audience, and handling public/private
    opts =
      [boundary: "federated", id: ulid(object), verb: e(activity, :verb, :create)]
      |> debug("ap_opts")

    with {:ok, apactivity} <- insert(character, json, opts) do
      #  {:ok, _} <- FeedActivities.save_fediverse_incoming_activity(character, :create, apactivity) do # Note: using `Activities.put_assoc/` instead
      {:ok, apactivity}
    end
  end

  def insert(character, json, opts) do
    activity =
      %APActivity{}
      |> APActivity.changeset(%{json: json})
      |> Objects.cast_caretaker(character)
      |> Objects.cast_acl(character, opts)

    id = opts[:id] || Changeset.get_change(activity, :id)

    activity
    |> Activities.put_assoc(opts[:verb], character, id)
    |> repo().insert()
    |> debug()
  end
end