defmodule Bonfire.Social.APActivities do
  alias Bonfire.Data.Social.APActivity
  alias Bonfire.Social.FeedActivities

  require Logger

  import Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]

  def create(activity, object, nil) do
    case Bonfire.Me.Users.ActivityPub.get_actor_by_ap_id(activity.data["actor"]) do
      {:ok, actor} ->
        create(activity, object, actor)
      _ ->
        error = "cannot create fallback activity with nil actor"
        Logger.error(error)
        {:error, error}
    end
  end

  def create(activity, object, actor) when is_map(object) do
    json =
      activity.data
      |> Map.put("object", object.data)

    with {:ok, apactivity} <- insert(json),
         {:ok, _} <- FeedActivities.save_fediverse_incoming_activity(actor, :create, apactivity) do
      {:ok, apactivity}
    end
  end

  def create(activity, object, actor) do
    object = ActivityPub.Object.normalize(object, true)

    json =
      if is_map(object) do
        activity.data
        |> Map.put("object", object.data)
      else
        activity.data
      end

    with {:ok, apactivity} <- insert(json),
         {:ok, _} <- FeedActivities.save_fediverse_incoming_activity(actor, :create, apactivity) do
      {:ok, apactivity}
    end
  end

  def insert(json) do
    %APActivity{}
    |> APActivity.changeset(%{json: json})
    |> repo().insert()
  end
end
