defmodule Bonfire.Social.APActivities do
  alias Bonfire.Data.Social.APActivity
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Ecto.Changeset
  alias Pointers.Changesets

  import Where

  use Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]

  def create(activity, object, nil) do
    with actor_id when is_binary(actor_id) <- e(activity, :data, "actor", nil),
         {:ok, actor} <- Bonfire.Federate.ActivityPub.Adapter.get_actor_by_ap_id(actor_id) do

        create(activity, object, actor)

      else _ ->
        error = "AP - cannot create a fallback activity with no actor"
        error(error)
        {:error, error}
    end
  end

  def create(activity, object, actor) when is_map(object) do
    json =
      e(activity, :data, %{})
      |> Map.put("object", object.data)

    with {:ok, apactivity} <- insert(actor, json) do
         # {:ok, _} <- FeedActivities.save_fediverse_incoming_activity(actor, :create, apactivity) do
      {:ok, apactivity}
    end
  end

  def create(activity, object, actor) do
    object = ActivityPub.Object.normalize(object, true)

    json =
      if is_map(object) do
        e(activity, :data, %{})
        |> Map.put("object", object.data)
      else
        e(activity, :data, %{})
      end

    with {:ok, apactivity} <- insert(actor, json),
         {:ok, _} <- FeedActivities.save_fediverse_incoming_activity(actor, :create, apactivity) do
      {:ok, apactivity}
    end
  end

  def insert(actor, json) do
    activity =
      %APActivity{}
      |> APActivity.changeset(%{json: json})
    id = Changeset.get_change(activity, :id)
    activity
    |> Activities.put_assoc(:create, actor, id)
    |> repo().insert()
  end
end
